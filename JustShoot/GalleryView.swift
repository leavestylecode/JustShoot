import SwiftUI
import SwiftData
import UIKit
import os

// MARK: - 相册视图（grid + drag-to-select 多选）
//
// 详情页（PhotoDetailView + PagerImage + ZoomingScrollView + PhotoScrubber + PhotoInfoPanel）
// 与 ImageLoader 已拆到独立文件。本文件只保留 grid 主视图、grid cell（PhotoThumbnailView）和
// 跳转 payload（DetailPayload）。
struct GalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.timestamp, order: .reverse) private var photos: [Photo]
    @State private var selectedDetail: DetailPayload?
    @State private var isSelecting = false
    @State private var selectedPhotos: Set<UUID> = []
    @State private var showDeleteConfirm = false

    // Drag-to-select 状态。Photos.app 同款：选择模式下从某 cell 起拖，根据该 cell 当前选中态
    // 锚定 mode（adding / removing），手指划过的每个 cell 应用该 mode 一次。
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var dragMode: DragMode? = nil
    @State private var dragLastPoint: CGPoint? = nil
    @State private var dragVisited: Set<UUID> = []

    private enum DragMode { case adding, removing }
    /// `nonisolated` 让 `.onGeometryChange` 的 @Sendable closure 也能读这个常量。
    /// SwiftUI View 默认 MainActor-isolated，连带它的 static 属性也是；不加 nonisolated
    /// 在 Swift 6 完整并发模式下会报 "Main actor-isolated static property ... can not be
    /// referenced from a Sendable closure"。值是 `String` 常量、天然线程安全。
    nonisolated private static let gridCoordSpace = "gallery.grid"

    private let gridColumns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if photos.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: gridColumns, spacing: 6) {
                    ForEach(photos) { photo in
                        photoCell(photo)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .coordinateSpace(.named(Self.gridCoordSpace))
                // including: .none 时 SwiftUI 完全不安装这条 gesture，ScrollView 的 pan 不受影响；
                // .all 时拦截 grid 区域的 drag，独占用作多选，scroll 可由 flick / status bar tap 触发。
                .gesture(dragSelectGesture, including: isSelecting ? .all : .none)
            }
        }
        .background(Color.black)
        .navigationTitle(isSelecting ? Text("\(selectedPhotos.count) selected") : Text("Gallery"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !photos.isEmpty {
                    Button(isSelecting ? "Select All" : "Select") {
                        if isSelecting {
                            let allPhotoIds = Set(photos.map { $0.id })
                            if selectedPhotos.count == allPhotoIds.count {
                                selectedPhotos.removeAll()
                            } else {
                                selectedPhotos = allPhotoIds
                            }
                        } else {
                            isSelecting = true
                        }
                    }
                }
            }
        }
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    Button("Cancel") {
                        isSelecting = false
                        selectedPhotos.removeAll()
                        resetDragState()
                    }

                    Spacer()

                    Button(action: { showDeleteConfirm = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                            Text("Delete")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(selectedPhotos.isEmpty ? .gray : .red)
                    }
                    .disabled(selectedPhotos.isEmpty)
                }
            }
        }
        .alert("Confirm delete", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSelectedPhotos()
            }
        } message: {
            Text("Delete \(selectedPhotos.count) selected photos? This cannot be undone.")
        }
        .navigationDestination(item: $selectedDetail) { payload in
            PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyState: some View {
        VStack {
            Image(systemName: "photo")
                .font(.system(size: 80))
                .foregroundColor(.gray.opacity(0.5))
            Text("No photos yet")
                .font(.title3)
                .foregroundColor(.gray)
                .padding(.top, 16)
            Text("Head to the camera to start shooting")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.6))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    @ViewBuilder
    private func photoCell(_ photo: Photo) -> some View {
        PhotoThumbnailView(
            photo: photo,
            isSelecting: isSelecting,
            isSelected: selectedPhotos.contains(photo.id)
        )
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipped()
        .contentShape(Rectangle())
        // 把 cell 在 grid 命名空间里的 frame 注册到字典，drag 时用于命中测试。
        // onDisappear 在 LazyVGrid 卸载该 cell 时清理，避免滚出视野的过期 frame 误命中。
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.gridCoordSpace))
        } action: { frame in
            cellFrames[photo.id] = frame
        }
        .onDisappear { cellFrames.removeValue(forKey: photo.id) }
        .onTapGesture { handleTap(photo) }
    }

    private func handleTap(_ photo: Photo) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if isSelecting {
            if selectedPhotos.contains(photo.id) {
                selectedPhotos.remove(photo.id)
            } else {
                selectedPhotos.insert(photo.id)
            }
        } else {
            let screen = currentScreen()
            let bounds = screen?.bounds ?? .zero
            let scale = screen?.scale ?? 2.0
            let maxPixel = Int(max(bounds.width, bounds.height) * scale)
            Task { @MainActor in
                _ = await ImageLoader.shared.loadPreview(for: photo, maxPixel: maxPixel)
            }
            selectedDetail = DetailPayload(startPhoto: photo, photos: Array(photos))
        }
    }

    // MARK: - Drag-to-select

    private var dragSelectGesture: some Gesture {
        // minimumDistance: 10 让短 tap 不触发 drag（onTapGesture 仍接管单击切选）；
        // 越过阈值后，drag 接管：onChanged 沿 last → current 走样本点找命中 cell。
        DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.gridCoordSpace))
            .onChanged { value in
                handleDragChange(at: value.location)
            }
            .onEnded { _ in
                resetDragState()
            }
    }

    private func handleDragChange(at point: CGPoint) {
        // 沿 lastPoint → currentPoint 等距取样，避免快速对角拖动跳过中间 cell（漏选）。
        // 步长 20pt 远小于 cell 宽（~93pt @ 4 cols），保证连续行/列都能命中至少一次。
        let from = dragLastPoint ?? point
        let dx = point.x - from.x
        let dy = point.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let stepCount = max(1, Int(ceil(distance / 20)))
        for i in 1...stepCount {
            let t = CGFloat(i) / CGFloat(stepCount)
            let p = CGPoint(x: from.x + dx * t, y: from.y + dy * t)
            if let id = cellFrames.first(where: { $0.value.contains(p) })?.key {
                visit(id)
            }
        }
        dragLastPoint = point
    }

    private func visit(_ id: UUID) {
        // 第一次触达：根据起手 cell 当前的选中态锚定 mode——已选则本次 drag 全部"取消选中"，
        // 未选则全部"选中"。和 Photos.app 一致。
        if dragMode == nil {
            dragMode = selectedPhotos.contains(id) ? .removing : .adding
        }
        // 一次手势内每个 cell 只生效一次，反向滑回不会反转——避免抖动 / 来回擦造成状态翻飞。
        guard !dragVisited.contains(id) else { return }
        dragVisited.insert(id)
        switch dragMode {
        case .adding: selectedPhotos.insert(id)
        case .removing: selectedPhotos.remove(id)
        case nil: break
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func resetDragState() {
        dragMode = nil
        dragLastPoint = nil
        dragVisited.removeAll()
    }

    // MARK: - Actions

    private func deleteSelectedPhotos() {
        let photosToDelete = photos.filter { selectedPhotos.contains($0.id) }
        let deletedIds = photosToDelete.map { $0.id }

        for photo in photosToDelete {
            modelContext.delete(photo)
        }

        do {
            try modelContext.save()
            // 清理已删除照片的磁盘缓存
            for id in deletedIds {
                ImageLoader.shared.removeDiskCache(for: id)
            }
            Log.save.info("photos_deleted count=\(deletedIds.count)")
        } catch {
            Log.save.error("photo_delete_failed count=\(deletedIds.count) error=\(error.localizedDescription, privacy: .public)")
        }

        selectedPhotos.removeAll()
        isSelecting = false
        resetDragState()
    }
}

// MARK: - Detail navigation payload
private struct DetailPayload: Identifiable, Equatable, Hashable {
    var id: UUID { startPhoto.id }
    let startPhoto: Photo
    let photos: [Photo]
    static func == (lhs: DetailPayload, rhs: DetailPayload) -> Bool { lhs.startPhoto.id == rhs.startPhoto.id }
    func hash(into hasher: inout Hasher) { hasher.combine(startPhoto.id) }
}

// MARK: - 缩略图视图（grid cell）
struct PhotoThumbnailView: View {
    let photo: Photo
    var isSelecting: Bool = false
    var isSelected: Bool = false
    @State private var thumb: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumb {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .overlay(
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                                    .scaleEffect(0.8)
                            )
                    }
                }

                if isSelecting {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.blue : Color.black.opacity(0.5))
                            .frame(width: 22, height: 22)

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Circle()
                                .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                        }
                    }
                    .padding(5)
                }

                if isSelecting && isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: geometry.size.width, height: geometry.size.width)
                }
            }
            .task {
                if thumb == nil {
                    // Cell width is the exact tile size from GeometryReader;
                    // multiply by display scale to get pixels.
                    let maxPixel = Int(geometry.size.width * displayScale)
                    thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: maxPixel)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isSelecting ? "Toggle selection" : "View photo")
        .accessibilityAddTraits(isSelected ? [.isImage, .isSelected] : .isImage)
    }

    private var accessibilityLabel: String {
        let dateStr = photo.timestamp.formatted(.dateTime.year().month().day().hour().minute())
        return "\(photo.filmDisplayName) · \(dateStr)"
    }
}
