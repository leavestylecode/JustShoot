import SwiftUI
import SwiftData
import UIKit
import os
import Photos
import CoreLocation
import ImageIO

// MARK: - 相册视图（SwiftUI 外壳 + UIKit 网格）
//
// 网格本体（滚动 / cell / 预取 / 原生两指拖动多选）在 PhotoGridView.swift（UICollectionView）——
// SwiftUI LazyVGrid + 自定义手势在大网格下既卡顿、又无法与滚动共存（详见 PhotoGridView 顶部注释）。
// 本文件保留 SwiftUI 外壳：导航标题、选择模式工具栏（Select / Select All / xmark / Download /
// Delete）、tab 栏隐藏、批量保存/删除、详情 push。选择状态通过 @Binding 与 PhotoGridView 双向同步。
struct GalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.timestamp, order: .reverse) private var photos: [Photo]

    @State private var selectedDetail: DetailPayload?
    @State private var isSelecting = false
    @State private var selectedPhotos: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var isSavingBatch = false
    @State private var saveError: String?

    // 网格布局（左上角菜单切换，持久化）
    @AppStorage("gallery.density") private var density: GalleryDensity = .standard
    @AppStorage("gallery.shape") private var shape: GalleryShape = .rounded

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if photos.isEmpty {
                emptyState
            } else {
                PhotoGridView(
                    photos: photos,
                    columns: density.columns,
                    cornerRadius: shape.cornerRadius,
                    isSelecting: $isSelecting,
                    selectedPhotos: $selectedPhotos,
                    onOpen: { photo in
                        selectedDetail = DetailPayload(startPhoto: photo, photos: Array(photos))
                    }
                )
                // 忽略上下安全区：collection view 延伸到 nav 栏 / tab 栏之下，靠
                // contentInsetAdjustmentBehavior=.automatic 把首/末行内边距顶到安全区内，
                // 内容可以滚到顶部 nav 栏之下。
                .ignoresSafeArea()
            }
        }
        .navigationTitle(isSelecting ? Text("\(selectedPhotos.count) selected") : Text("Gallery"))
        .navigationBarTitleDisplayMode(.inline)
        // 选择模式隐藏底部 tab 栏，让位给 Download / Delete 操作栏（Photos.app 一致）。
        .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
        .toolbar {
            // 全选放左上、xmark 放右上——两端分置，不挤在一起。
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelecting {
                    Button("Select All") { toggleSelectAll() }
                } else if !photos.isEmpty {
                    layoutMenu
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button { exitSelection() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Done selecting")
                } else if !photos.isEmpty {
                    Button("Select") {
                        withAnimation(.easeInOut(duration: 0.25)) { isSelecting = true }
                    }
                }
            }
        }
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    // 下载：批量存入系统相册（保留 EXIF/GPS 元数据）。图标 only。
                    Button(action: saveSelectedPhotos) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(selectedPhotos.isEmpty ? .gray : .green)
                    }
                    .disabled(selectedPhotos.isEmpty || isSavingBatch)
                    .accessibilityLabel("Download")

                    Spacer()

                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 18))
                            .foregroundColor(selectedPhotos.isEmpty ? .gray : .red)
                    }
                    .disabled(selectedPhotos.isEmpty)
                    .accessibilityLabel("Delete")
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
        .alert("Save failed", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        // 详情用 sheet 呈现：原生下滑关闭，且 sheet 盖在 tab 栏之上（详情不与底部冲突）。
        .sheet(item: $selectedDetail) { payload in
            NavigationStack {
                PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { selectedDetail = nil } label: {
                                Image(systemName: "xmark").fontWeight(.semibold)
                            }
                            .tint(.white)
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .preferredColorScheme(.dark)
        }
    }

    /// 左上角网格布局切换：Menu + 两个 inline Picker（密度 + 形状）。切换后 @AppStorage 落库、
    /// PhotoGridView 平滑 reflow。
    private var layoutMenu: some View {
        Menu {
            Picker("Grid size", selection: $density) {
                ForEach(GalleryDensity.allCases) { d in Text(d.displayName).tag(d) }
            }
            .pickerStyle(.inline)
            Picker("Corners", selection: $shape) {
                ForEach(GalleryShape.allCases) { s in Text(s.displayName).tag(s) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityLabel("Grid layout options")
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

    // MARK: - Actions

    /// 全选 / 取消全选：已全选则清空，否则选中全部。
    private func toggleSelectAll() {
        let allPhotoIds = Set(photos.map { $0.id })
        if selectedPhotos.count == allPhotoIds.count {
            selectedPhotos.removeAll()
        } else {
            selectedPhotos = allPhotoIds
        }
    }

    /// 退出选择模式（右上 xmark）：清空选中、恢复 tab 栏。isSelecting 切换包在 withAnimation 里——
    /// 驱动 tab 栏 ↔ 底部操作栏的过渡平滑。
    private func exitSelection() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isSelecting = false
        }
        selectedPhotos.removeAll()
    }

    /// 批量保存选中照片到系统相册（保留拍摄时间 / GPS / 原始 HEIC-or-JPEG 字节）。
    /// 在主 actor 上把 @Model 投影成 Sendable 的 SavePhotoItem，再在一个 performChanges 事务里
    /// 全部写入——避免把非 Sendable 的 Photo 带入异步上下文。保存成功不自动退出选择模式（退出由
    /// 用户点 xmark 决定），仅给成功 haptic。
    private func saveSelectedPhotos() {
        let ids = selectedPhotos
        let items: [SavePhotoItem] = photos
            .filter { ids.contains($0.id) }
            .map { SavePhotoItem(imageData: $0.imageData, timestamp: $0.timestamp,
                                 latitude: $0.latitude, longitude: $0.longitude,
                                 altitude: $0.altitude, locationTimestamp: $0.locationTimestamp) }
        guard !items.isEmpty else { return }

        isSavingBatch = true
        let count = items.count
        let timer = Log.perf("gallery_export", logger: Log.save)

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    isSavingBatch = false
                    saveError = String(localized: "Allow Photos access in Settings to save photos.")
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for item in items {
                        let request = PHAssetCreationRequest.forAsset()
                        request.creationDate = item.timestamp
                        if let lat = item.latitude, let lon = item.longitude {
                            request.location = CLLocation(
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                altitude: item.altitude ?? 0,
                                horizontalAccuracy: 10, verticalAccuracy: 10,
                                timestamp: item.locationTimestamp ?? item.timestamp
                            )
                        }
                        let options = PHAssetResourceCreationOptions()
                        // 用 CGImageSource 检测真实 UTI（HEIC/JPEG），硬编码 jpeg 会让 HEIC 触发
                        // PHPhotosErrorDomain 3302（data 与声明 UTI 不一致）。
                        if let src = CGImageSourceCreateWithData(item.imageData as CFData, nil),
                           let uti = CGImageSourceGetType(src) {
                            options.uniformTypeIdentifier = uti as String
                        }
                        request.addResource(with: .photo, data: item.imageData, options: options)
                    }
                }
                timer.end("result=ok count=\(count)")
                await MainActor.run {
                    isSavingBatch = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                Log.save.error("gallery_export_failed count=\(count) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    isSavingBatch = false
                    saveError = String(localized: "Couldn't save the selected photos.")
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func deleteSelectedPhotos() {
        let idsToDelete = Array(selectedPhotos)
        guard !idsToDelete.isEmpty else { return }
        let container = modelContext.container

        // 关 selection 模式 + 清状态——UI 立刻反馈，删除走后台 actor。
        selectedPhotos.removeAll()
        withAnimation(.easeInOut(duration: 0.25)) { isSelecting = false }

        Task.detached(priority: .userInitiated) {
            do {
                let saver = PhotoSaver(modelContainer: container)
                try await saver.delete(ids: idsToDelete)
                // 主 @Query 通过 SwiftData 跨 context 通知自动刷新——cell 从 grid 中淡出。
                // disk cache 清理可以慢慢来，不阻塞 UI 也不阻塞 SwiftData 写入。
                for id in idsToDelete {
                    ImageLoader.shared.removeDiskCache(for: id)
                }
                Log.save.info("photos_deleted count=\(idsToDelete.count)")
            } catch {
                Log.save.error("photo_delete_failed count=\(idsToDelete.count) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - 批量保存载体
/// Sendable 投影：把要写入相册的字段从非 Sendable 的 @Model Photo 抽出来，安全跨 actor 传递。
private struct SavePhotoItem: Sendable {
    let imageData: Data
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let locationTimestamp: Date?
}

// MARK: - Detail navigation payload
private struct DetailPayload: Identifiable, Equatable, Hashable {
    var id: UUID { startPhoto.id }
    let startPhoto: Photo
    let photos: [Photo]
    static func == (lhs: DetailPayload, rhs: DetailPayload) -> Bool { lhs.startPhoto.id == rhs.startPhoto.id }
    func hash(into hasher: inout Hasher) { hasher.combine(startPhoto.id) }
}
