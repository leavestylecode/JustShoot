import SwiftUI
import SwiftData
import UIKit
import os
import Photos
import CoreLocation
import ImageIO

// MARK: - 相册视图（grid + drag-to-select 多选）
//
// 详情页（PhotoDetailView + PagerImage + ZoomingScrollView + PhotoScrubber + PhotoInfoPanel）
// 与 ImageLoader 已拆到独立文件。本文件保留 grid 主视图、grid cell（PhotoThumbnailView）和
// 跳转 payload（DetailPayload）。
//
// **drag-to-select 命中策略**：用网格数学（已知列数 + padding + spacing 常量）从触点坐标
// 反算 (col, row) → photo index，O(1)。比之前用 `[UUID: CGRect]` 字典 + onGeometryChange
// 注册每个 cell frame、再 first(where: contains) O(n) 命中要快得多——也少了一份 @State，
// 滚动时不会因为 cellFrames 写入触发 body 重算。
struct GalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.timestamp, order: .reverse) private var photos: [Photo]
    @Environment(\.displayScale) private var displayScale

    @State private var selectedDetail: DetailPayload?
    @State private var isSelecting = false
    @State private var selectedPhotos: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var isSavingBatch = false
    @State private var saveError: String?

    // ScrollView 宽度——通过 .onGeometryChange 同步。portrait 锁定 + 全屏 ScrollView，
    // 设一次后基本不变。cell 尺寸 / drag 命中数学都用这个常量算。
    @State private var containerWidth: CGFloat = 0

    // Drag-to-select 状态。锚定 mode（adding/removing）由起手 cell 的当前选中态决定，
    // 一次手势内每个 cell 只生效一次（避免反向擦回触发翻飞）。
    /// Range-based 拖选状态。**Photos.app 核心模型**：起手 cell 锚定、当前手指位置 clamp 到最近
    /// cell、范围 = [anchor, current] 在 grid index 上的闭区间。手指反方向拖 → 范围收缩自动撤选。
    /// 比"逐 cell visit"模式：用户不必滑过每个 cell（斜着拖到对角即覆盖整个矩形），右/下边缘外溢
    /// clamp 到最近 cell 时"整行选中"自然涌现，路径采样防漏选也不需要了。
    @State private var dragAnchorIndex: Int? = nil
    @State private var dragMode: DragMode? = nil
    @State private var dragRangeIndices: Set<Int> = []

    /// 单调递增计数——每次范围扩展（有新 cell 进入）+1，配合 .sensoryFeedback(.selection, trigger:)
    /// 触发一次 selection haptic。SwiftUI 自动管理 generator 生命周期，与 Photos.app 体感一致。
    @State private var dragHapticTrigger: Int = 0

    /// cell→detail zoom 转场（iOS 18+ navigationTransition + matchedTransitionSource）。
    /// ContentView 首页 tile→camera 也是同套机制，这里 grid→detail 跟齐。
    @Namespace private var detailZoom

    private enum DragMode { case adding, removing }

    /// `nonisolated` 让 .onGeometryChange / drag closure 这类 @Sendable 闭包也能读。
    /// 都是 String/Int/CGFloat 常量、天然线程安全。
    nonisolated private static let gridCoordSpace = "gallery.grid"
    nonisolated private static let columns: Int = 4
    nonisolated private static let hPadding: CGFloat = 14
    nonisolated private static let topPadding: CGFloat = 8
    nonisolated private static let bottomPadding: CGFloat = 20
    nonisolated private static let spacing: CGFloat = 6

    private var cellWidth: CGFloat {
        let totalSpacing = Self.spacing * CGFloat(Self.columns - 1)
        return max(0, (containerWidth - 2 * Self.hPadding - totalSpacing) / CGFloat(Self.columns))
    }

    private var thumbnailMaxPixel: Int {
        max(96, Int(cellWidth * displayScale))
    }

    private static let gridColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: Self.spacing),
        count: Self.columns
    )

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if photos.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: Self.gridColumns, spacing: Self.spacing) {
                    ForEach(photos) { photo in
                        photoCell(photo)
                    }
                }
                .padding(.horizontal, Self.hPadding)
                .padding(.top, Self.topPadding)
                .padding(.bottom, Self.bottomPadding)
                .coordinateSpace(.named(Self.gridCoordSpace))
                .gesture(dragSelectGesture, including: isSelecting ? .all : .none)
            }
        }
        .background(Color.black)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
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
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 18))
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
        .sensoryFeedback(.selection, trigger: dragHapticTrigger)
        .navigationDestination(item: $selectedDetail) { payload in
            PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos)
                .navigationTransition(.zoom(sourceID: payload.startPhoto.id, in: detailZoom))
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
            maxPixel: thumbnailMaxPixel,
            isSelecting: isSelecting,
            isSelected: selectedPhotos.contains(photo.id)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .matchedTransitionSource(id: photo.id, in: detailZoom)
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
            // PhotoDetailView 自己会按 previewMaxPixel(屏幕长边像素) 异步解码并在期间用
            // anyCachedThumbnail 兜底——这里再 schedule 一次 loadPreview 是冗余且时机更晚。
            selectedDetail = DetailPayload(startPhoto: photo, photos: Array(photos))
        }
    }

    // MARK: - Drag-to-select

    private var dragSelectGesture: some Gesture {
        // 长按 ~0.25s 后才进入拖动多选。旧实现是纯 DragGesture(minimumDistance: 20)，与 ScrollView
        // 抢手势——选择模式下上下滑动超过 20pt 就被判成 drag-select，频繁误选。改成
        // LongPressGesture.sequenced(before: DragGesture)：
        //   · 普通快速上下滑（没按住）→ 长按不成立 → ScrollView 正常滚动，绝不误选；
        //   · 按住 cell ~0.25s 再拖 → 锚定起手 cell + 区间填充多选；
        //   · 单击 cell 仍走 .onTapGesture 逐个 toggle。
        // 这是 iOS Files/Photos 一致的「按住-拖拽」多选语义，彻底分离滚动与选择。
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridCoordSpace)))
            .onChanged { value in
                // .second(true, drag?)：长按已成立、进入拖动阶段。drag 为 nil 时（刚成立未移动）跳过。
                if case .second(true, let drag?) = value {
                    applyDragRange(start: drag.startLocation, current: drag.location)
                }
            }
            .onEnded { _ in
                resetDragState()
            }
    }

    /// Range-based 拖选核心。Photos.app 一致的"锚定 + 区间填充"模型——
    /// - `start` 是 DragGesture 的 startLocation（finger touch-down 位置，即使 onChanged 在
    ///   minimumDistance 阈值后才首次回包，startLocation 仍指向最初触点）；
    /// - `current` 是当前手指位置；
    /// - 范围 = [anchor, current] 闭区间，向前向后均可，反向拖时区间收缩、之前 add 的 cell 被
    ///   反向 remove（或反之），完美对称。
    private func applyDragRange(start: CGPoint, current: CGPoint) {
        // 首次回包：锚定起手 cell + 决定 mode（起手 cell 已选 → 反选模式，未选 → 选中模式）。
        if dragAnchorIndex == nil {
            guard let anchor = nearestPhotoIndex(at: start) else { return }
            dragAnchorIndex = anchor
            dragMode = selectedPhotos.contains(photos[anchor].id) ? .removing : .adding
        }

        guard let anchor = dragAnchorIndex,
              let cur = nearestPhotoIndex(at: current),
              let mode = dragMode else { return }

        let lo = min(anchor, cur)
        let hi = max(anchor, cur)
        let newRange = Set(lo...hi)

        let entered = newRange.subtracting(dragRangeIndices)
        let exited = dragRangeIndices.subtracting(newRange)

        // 进入区间的 cell 应用 mode；退出区间的 cell 反向应用——支持反方向拖回收缩区间。
        for idx in entered {
            applyMode(mode, to: photos[idx].id, reverse: false)
        }
        for idx in exited {
            applyMode(mode, to: photos[idx].id, reverse: true)
        }

        if !entered.isEmpty {
            dragHapticTrigger &+= 1
        }

        dragRangeIndices = newRange
    }

    private func applyMode(_ mode: DragMode, to id: UUID, reverse: Bool) {
        switch (mode, reverse) {
        case (.adding, false), (.removing, true): selectedPhotos.insert(id)
        case (.removing, false), (.adding, true): selectedPhotos.remove(id)
        }
    }

    /// 把任意点 clamp 到最近 photo 的 grid index。**右/下/外溢区都会落到最近 cell**——这是
    /// "右边缘 = 整行选中"行为的关键：手指拖到第 N 行右侧外溢区 → clamp 到第 N 行最右 cell →
    /// 区间 [anchor, 第N行末尾] 自然覆盖前 N-1 行 + 当前行到末尾。
    /// `point` 在 `.named(gridCoordSpace)` 坐标系下——origin = padded LazyVGrid 左上。
    private func nearestPhotoIndex(at point: CGPoint) -> Int? {
        let cellW = cellWidth
        guard cellW > 0, !photos.isEmpty else { return nil }
        let stride = cellW + Self.spacing
        let x = point.x - Self.hPadding
        let y = point.y - Self.topPadding

        let totalRows = (photos.count + Self.columns - 1) / Self.columns
        let row = max(0, min(totalRows - 1, Int(y / stride)))
        let col = max(0, min(Self.columns - 1, Int(x / stride)))

        // 末行可能不满 columns（e.g. 13 张照片 4 列时末行只有 1 张）——clamp 到 photos.count-1。
        return min(row * Self.columns + col, photos.count - 1)
    }

    private func resetDragState() {
        dragAnchorIndex = nil
        dragMode = nil
        dragRangeIndices.removeAll()
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

    /// 退出选择模式（右上 xmark）：清空选中、复位拖选状态、恢复 tab 栏。
    /// isSelecting 切换包在 withAnimation 里——驱动 tab 栏 ↔ 底部操作栏的过渡平滑滑入/滑出。
    private func exitSelection() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isSelecting = false
        }
        selectedPhotos.removeAll()
        resetDragState()
    }

    /// 批量保存选中照片到系统相册（保留拍摄时间 / GPS / 原始 HEIC-or-JPEG 字节）。
    /// 在主 actor 上把 @Model 投影成 Sendable 的 SavePhotoItem，再在一个 performChanges
    /// 事务里全部写入——避免把非 Sendable 的 Photo 带入异步上下文。保存成功不自动退出选择模式
    /// （退出由用户点 xmark 决定），仅给成功 haptic。
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
        resetDragState()

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

// MARK: - 缩略图视图（grid cell）
struct PhotoThumbnailView: View {
    let photo: Photo
    let maxPixel: Int
    var isSelecting: Bool = false
    var isSelected: Bool = false

    /// 同步 cache 命中：init 时直接读 NSCache，命中就立即作为 thumb 初值——避免 .task 启动那一帧
    /// 露出 ProgressView 占位（NSCache 命中只要 µs，但 .task 会让出一次 runloop，肉眼可见一帧白）。
    /// miss 才进入 .task 异步路径；同 photo 同 size 第二次出现就完全无闪烁。
    @State private var thumb: UIImage?

    init(photo: Photo, maxPixel: Int, isSelecting: Bool = false, isSelected: Bool = false) {
        self.photo = photo
        self.maxPixel = maxPixel
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        let cached = ImageLoader.shared.cachedThumbnail(for: photo.id, maxPixel: maxPixel)
            ?? ImageLoader.shared.anyCachedThumbnail(for: photo.id)
        _thumb = State(initialValue: cached)
    }

    var body: some View {
        // Color.clear + .aspectRatio(1, .fit) 确立方形画布；图像在 .overlay 里以 .scaledToFill
        // 填满，溢出由外层 .clipped() 裁到方形边界——这是 SwiftUI 标准的"图像方形裁切"惯用法。
        // 不能用 Image(...).aspectRatio(.fill) 直接当 ZStack 子项：Image 在 .fill 模式下会以
        // 实际像素比例外溢父框，相邻 cell 视觉上互相重叠。
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = thumb {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                                .scaleEffect(0.8)
                        )
                }
            }
            .clipped()
            // 选中遮罩——深色薄洗压暗已选 cell 的照片，让选中态在亮/暗照片上都一眼可辨；
            // 蒙板下沉、角标上浮，互不干扰。
            .overlay {
                if isSelecting && isSelected {
                    Color.black.opacity(0.4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    selectionBadge
                        .padding(8)
                }
            }
            // task(id:) 让 maxPixel 改变时（首次容器宽度从 0 变到真实值）重新解码到精确尺寸。
            .task(id: maxPixel) {
                guard maxPixel > 0, thumb == nil else { return }
                thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: maxPixel)
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(isSelecting ? "Toggle selection" : "View photo")
            .accessibilityAddTraits(isSelected ? [.isImage, .isSelected] : .isImage)
    }

    /// Photos.app 一致的选中角标：右上 22pt SF Symbol。
    /// - 选中 = `checkmark.circle.fill` + palette rendering（白勾 + 蓝底）
    /// - 未选 = `circle` 白色描边
    /// - 都加一层薄阴影，保证在白色/纯亮照片上仍清晰可见
    /// - **故意不画 cell 蓝边框 / 不缩放 / 不暗化**——Photos.app 仅角标变化，cell 本身保持原貌
    @ViewBuilder
    private var selectionBadge: some View {
        Group {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.blue)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.white)
            }
        }
        .font(.system(size: 22, weight: .regular))
        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
    }

    private var accessibilityLabel: String {
        let dateStr = photo.timestamp.formatted(.dateTime.year().month().day().hour().minute())
        return "\(photo.filmDisplayName) · \(dateStr)"
    }
}
