import SwiftUI
import SwiftData
import PhotosUI
import ImageIO
import UIKit
import os

/// iOS 26 deprecated `UIScreen.main`. For non-view contexts we still need
/// a screen handle for full-resolution preview sizing — fish it out of the
/// active window scene.
@MainActor
private func currentScreen() -> UIScreen? {
    UIApplication.shared.connectedScenes
        .lazy
        .compactMap { $0 as? UIWindowScene }
        .first?
        .screen
}

// MARK: - 图片加载器
// @unchecked Sendable：NSCache 和 FileManager.default 本身线程安全，
// init 后所有可变状态都仅通过线程安全 API 写入
final class ImageLoader: ObservableObject, @unchecked Sendable {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default

    /// 按设备物理内存自适应：上限 = min(128MB, RAM/32)
    /// 低端设备（2GB RAM）约 64MB；高端设备（8GB RAM）封顶 128MB
    private static func defaultCostLimit() -> Int {
        let mem = Int(ProcessInfo.processInfo.physicalMemory)
        return min(128 * 1024 * 1024, mem / 32)
    }

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = Self.defaultCostLimit()
    }

    // MARK: - In-flight dedup
    //
    // 同一张图（同 key）被并发请求时——常见场景：handleTap 起一个 loadPreview，detail
    // mount 后 PagerImage.task 又起一个；schedulePreheat 跟 ThumbnailStripCell.task 撞同一
    // 张 600px thumb——旧实现会启动多个 Task.detached 并行 decode 同一帧，互相抢 CPU
    // cores，每个 decode 慢 ~2x，首张照片要等近 1 秒才出现。
    //
    // 新实现：每个 key 维护一个 in-flight Task，后续 caller 直接 await 已存在的 Task，
    // 同 key 同一份 decode。NSCache 命中走快路径不动；只有 miss 时才进 lock。
    //
    // 用 `OSAllocatedUnfairLock` 而不是 `NSLock`：NSLock 的 `lock()` / `unlock()` 在
    // Swift 6 完整并发模式下被标记为"unavailable from asynchronous contexts"（async 函数里
    // 调用会阻塞 cooperative thread pool 的 worker，破坏调度）。`OSAllocatedUnfairLock` 提供
    // 闭包式 `withLock` API，async 安全；持锁极短时间（dict 读写）足够快，不会影响调度。
    /// Dict 用 `String` key（不是 NSString）：String 是 Sendable，可以安全在 @Sendable 闭包里
    /// 捕获；NSString 不是，会触发"capture of 'key' with non-Sendable type"警告。
    /// NSCache 仍要 NSString，调用点用 `key as NSString` 临时转换即可。
    private struct InflightTasks {
        var previews: [String: Task<UIImage?, Never>] = [:]
        var thumbs: [String: Task<UIImage?, Never>] = [:]
    }
    /// `uncheckedState` 跳过 State: Sendable 约束——访问由锁串行化，State 内的 Task 实际不会
    /// 被并发触碰；Sendable 检查由我们用法担保，不交给类型系统强制。
    private let inflight = OSAllocatedUnfairLock(uncheckedState: InflightTasks())

    /// UIImage 的近似内存占用（字节）：解码后按 RGBA8 估算，未解码也安全
    private func memoryCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else {
            let pixels = Int(image.size.width * image.size.height * image.scale * image.scale)
            return max(pixels * 4, 4096)
        }
        return max(cg.bytesPerRow * cg.height, 4096)
    }

    private func cacheImage(_ image: UIImage, forKey key: NSString) {
        cache.setObject(image, forKey: key, cost: memoryCost(of: image))
    }

    /// 把带 alpha channel 的 CGImage 重绘成 opaque RGB，去掉无意义的 alpha 字节。
    /// 触发场景：HEIC 源经 CGImageSourceCreateThumbnailAtIndex 出来的 CGImage 默认带 RGBA，
    /// 内容明明 opaque——直接 jpegData 会报"opaque image with AlphaLast"且文件多 25%。
    /// 重绘到 noneSkipFirst（XRGB）后存盘即可消除 ImageIO 警告，同时减小文件、加快解码。
    static func makeOpaque(_ cgImage: CGImage) -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return cgImage }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cgImage
    }

    /// 便捷重载：在主 actor 上预取 `Photo` 的 imageData/id，再转发到 Sendable 版本。
    /// 调用点仍然写 `loadPreview(for: photo, ...)`，但 Sendable 契约由 @MainActor 担保。
    @MainActor
    func loadPreview(for photo: Photo, maxPixel: Int) async -> UIImage? {
        await loadPreview(imageData: photo.imageData, photoId: photo.id, maxPixel: maxPixel)
    }

    /// 同步查内存 cache（不触发 disk / 解码）。命中则零延迟，用于 view body 第一次评估时
    /// 给出占位图——避免 SwiftUI .task 启动那一帧露出黑屏。
    @MainActor
    func cachedPreview(for photoId: UUID, maxPixel: Int) -> UIImage? {
        cache.object(forKey: "preview_\(photoId.uuidString)_\(maxPixel)" as NSString)
    }

    @MainActor
    func cachedThumbnail(for photoId: UUID, maxPixel: Int) -> UIImage? {
        cache.object(forKey: "thumb_\(photoId.uuidString)_\(maxPixel)" as NSString)
    }

    /// 探测常见 thumb 尺寸（按高分辨率优先）找任意一份可用的——大屏 detail 页用 600，gallery
    /// 4 列网格用 264，列表头像用 88……不同来源算出的 maxPixel 不一样，cache key 也不一样，
    /// 旧实现单 key 查找会错过其他地方解码好的同一张图。
    ///
    /// 关键作用：用户从 gallery 点入 detail 那一帧——gallery 的 264 已在内存里，PagerImage
    /// 的占位 fallback 直接用它（虽然偏糊但**立刻有图**），后续 600 / preview 解码完再 soft-swap
    /// 升清，黑屏占位窗口被消除。
    @MainActor
    func anyCachedThumbnail(for photoId: UUID) -> UIImage? {
        // 高分→低分顺序遍历：找到第一个 hit 就用，保证拿到当前内存里"最好"的那份。
        let commonSizes = [1500, 1200, 800, 600, 400, 300, 264, 256, 200, 150, 120, 96, 88]
        let prefix = "thumb_\(photoId.uuidString)_"
        for size in commonSizes {
            if let img = cache.object(forKey: "\(prefix)\(size)" as NSString) {
                return img
            }
        }
        return nil
    }

    /// 加载大图预览。imageData/photoId 必须在调用者所在的 actor 上预取，避免跨 actor 传递非 Sendable 的 `Photo`。
    /// 同 key 并发请求会被 in-flight dedup 合并成一份 Task.detached——见 `inflight` 注释。
    func loadPreview(imageData: Data, photoId: UUID, maxPixel: Int) async -> UIImage? {
        let key = "preview_\(photoId.uuidString)_\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        // Atomic check-and-register：同 key 已有 in-flight Task 就复用，否则注册新 Task。
        // 临界区只做 dict 读写（< 1µs），符合 OSAllocatedUnfairLock 的"持锁极短"用例。
        let task: Task<UIImage?, Never> = inflight.withLock { state in
            if let existing = state.previews[key] { return existing }
            let new = Task<UIImage?, Never>.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return nil }
                // disk hit 也走 detached：避免 caller 在 main actor 上同步读 17MB JPEG。
                if let url = self.previewURL(for: photoId, maxPixel: maxPixel),
                   self.fileManager.fileExists(atPath: url.path),
                   let data = try? Data(contentsOf: url),
                   let img = UIImage(data: data) {
                    self.cacheImage(img, forKey: key as NSString)
                    Log.gallery.debug("preview_disk_hit id=\(photoId.uuidString, privacy: .public) max=\(maxPixel)")
                    return img
                }
                let timer = Log.perf("preview_decode", logger: Log.gallery)
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false
                ]
                guard let src = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }
                let downOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 256),
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, downOptions as CFDictionary) else { return nil }
                let opaque = ImageLoader.makeOpaque(cgThumb)
                let image = UIImage(cgImage: opaque)
                self.cacheImage(image, forKey: key as NSString)
                if let url = self.previewURL(for: photoId, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.9) {
                    try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? jpeg.write(to: url, options: .atomic)
                }
                timer.end("id=\(photoId.uuidString) max=\(maxPixel) px=\(cgThumb.width)x\(cgThumb.height)")
                return image
            }
            state.previews[key] = new
            return new
        }

        let result = await task.value

        // 用 subscript-set-nil 让 closure body 自然返回 Void，避免 removeValue 的可选返回值被
        // withLock 透传给调用方触发"unused result"警告。
        inflight.withLock { state in
            state.previews[key] = nil
        }

        return result
    }

    /// 便捷重载：在主 actor 上预取 `Photo` 的 imageData/id。
    @MainActor
    func loadThumbnail(for photo: Photo, maxPixel: Int) async -> UIImage? {
        await loadThumbnail(imageData: photo.imageData, photoId: photo.id, maxPixel: maxPixel)
    }

    /// 加载缩略图。调用者须在 actor 上预取 imageData/photoId，避免跨 actor 传递 SwiftData `Photo` 模型。
    /// 同 key 并发请求会被 in-flight dedup 合并——常见场景：schedulePreheat 与 ThumbnailStripCell.task
    /// 同时请求同一张 600px thumb，旧实现会双重 decode 抢 CPU。
    func loadThumbnail(imageData: Data, photoId: UUID, maxPixel: Int) async -> UIImage? {
        let key = "thumb_\(photoId.uuidString)_\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let task: Task<UIImage?, Never> = inflight.withLock { state in
            if let existing = state.thumbs[key] { return existing }
            let new = Task<UIImage?, Never>.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return nil }
                if let url = self.thumbnailURL(for: photoId, maxPixel: maxPixel),
                   self.fileManager.fileExists(atPath: url.path),
                   let data = try? Data(contentsOf: url),
                   let img = UIImage(data: data) {
                    self.cacheImage(img, forKey: key as NSString)
                    return img
                }
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false
                ]
                guard let src = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 96),
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else { return nil }
                let opaque = ImageLoader.makeOpaque(cgThumb)
                let image = UIImage(cgImage: opaque)
                self.cacheImage(image, forKey: key as NSString)
                if let url = self.thumbnailURL(for: photoId, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? jpeg.write(to: url, options: .atomic)
                }
                return image
            }
            state.thumbs[key] = new
            return new
        }

        let result = await task.value

        inflight.withLock { state in
            state.thumbs[key] = nil
        }

        return result
    }

    private func thumbsDirectory() -> URL? {
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Thumbs", isDirectory: true)
    }

    private func thumbnailURL(for photoId: UUID, maxPixel: Int) -> URL? {
        guard let dir = thumbsDirectory() else { return nil }
        return dir.appendingPathComponent("\(photoId.uuidString)_t_\(maxPixel).jpg")
    }

    private func previewDirectory() -> URL? {
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Previews", isDirectory: true)
    }

    private func previewURL(for photoId: UUID, maxPixel: Int) -> URL? {
        guard let dir = previewDirectory() else { return nil }
        return dir.appendingPathComponent("\(photoId.uuidString)_p_\(maxPixel).jpg")
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    /// 删除指定照片的磁盘缓存文件
    func removeDiskCache(for photoId: UUID) {
        let fm = fileManager
        // 清理缩略图和预览的所有尺寸变体
        for dir in [thumbsDirectory(), previewDirectory()] {
            guard let dir else { continue }
            let prefix = photoId.uuidString
            if let files = try? fm.contentsOfDirectory(atPath: dir.path) {
                for file in files where file.hasPrefix(prefix) {
                    try? fm.removeItem(at: dir.appendingPathComponent(file))
                }
            }
        }
        // 清理内存缓存中对应的条目
        // NSCache 没有遍历 API，但 key 模式固定，尝试移除常见尺寸
        let commonSizes = [88, 96, 256, 400, 600, 800, 1200, 2000, 3000]
        for size in commonSizes {
            cache.removeObject(forKey: "thumb_\(photoId.uuidString)_\(size)" as NSString)
            cache.removeObject(forKey: "preview_\(photoId.uuidString)_\(size)" as NSString)
        }
    }
}

// MARK: - 相册视图
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
        .navigationTitle(isSelecting ? "已选择 \(selectedPhotos.count) 张" : "相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !photos.isEmpty {
                    Button(isSelecting ? "全选" : "选择") {
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
                    Button("取消") {
                        isSelecting = false
                        selectedPhotos.removeAll()
                        resetDragState()
                    }

                    Spacer()

                    Button(action: { showDeleteConfirm = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                            Text("删除")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(selectedPhotos.isEmpty ? .gray : .red)
                    }
                    .disabled(selectedPhotos.isEmpty)
                }
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deleteSelectedPhotos()
            }
        } message: {
            Text("确定要删除选中的 \(selectedPhotos.count) 张照片吗？此操作不可撤销。")
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
            Text("暂无照片")
                .font(.title3)
                .foregroundColor(.gray)
                .padding(.top, 16)
            Text("前往拍摄页面开始拍照")
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

private struct DetailPayload: Identifiable, Equatable, Hashable {
    var id: UUID { startPhoto.id }
    let startPhoto: Photo
    let photos: [Photo]
    static func == (lhs: DetailPayload, rhs: DetailPayload) -> Bool { lhs.startPhoto.id == rhs.startPhoto.id }
    func hash(into hasher: inout Hasher) { hasher.combine(startPhoto.id) }
}

// MARK: - 缩略图视图
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
        .accessibilityHint(isSelecting ? "切换选中状态" : "查看照片")
        .accessibilityAddTraits(isSelected ? [.isImage, .isSelected] : .isImage)
    }

    private var accessibilityLabel: String {
        let dateStr = photo.timestamp.formatted(.dateTime.year().month().day().hour().minute())
        return "\(photo.filmDisplayName) · \(dateStr)"
    }
}

// MARK: - 照片详情
struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var photos: [Photo]
    /// `scrollPosition(id:)` 与所有 cross-component 同步都按 photo.id 走，不按 index。
    /// 旧实现 `.tag(index)` + `selection: $currentIndex`（Int）在删除时易错位——index 跟着数组左移
    /// 一格，binding 没及时同步会一帧错配。改用 ID 后 selection 与 ForEach identity 同源，删除/重排
    /// 都不会出现"选中但找不到 id"的瞬态。
    ///
    /// 类型是 `UUID?`（不是 `UUID`）：`.scrollPosition(id:)` 要求 `Binding<Hashable?>`——可见 item
    /// 不在视口里时它会写 nil，所以源端必须可空。`UUID == UUID?` 由 Optional 的 Equatable 自动 lift，
    /// 比较点写起来跟非可空一样。
    @State private var currentPhotoID: UUID?
    /// 屏幕长边（点）× scale = 高分预览解码尺寸。@State + 一次性 init 避免每次 body re-eval 都
    /// `walk(connectedScenes)`（量小但能省就省，且确保 PagerImage 在所有 body 评估里看到稳定值）。
    @State private var previewMaxPixel: Int
    @State private var saveStatus: SaveStatus = .none
    @State private var saveResetTask: Task<Void, Never>?
    @State private var showingInfo = false
    @State private var showDeleteConfirm = false
    @State private var isFullScreen = false
    @State private var thumbWarmupTask: Task<Void, Never>?
    @State private var previewPreloadTask: Task<Void, Never>?

    enum SaveStatus { case none, saving, success, failed }

    /// 占位缩略图目标像素——大约屏幕长边的 1/3，`PagerImage` 占位 + `PhotoScrubber` cell 共享同一份
    /// NSCache 解码（两边都用这个 key）。单张 ~80KB，100 张 ~8MB 落 NSCache，受 totalCostLimit 自然
    /// 淘汰。值不再用于"区间预热"，所以删掉了之前的 placeholderRange 常量。
    static let placeholderMaxPixel = 600

    /// 翻页/scrubber 触发的预热任务统一 debounce 这么久——快速连翻时只有最后一次落定才真正预热，
    /// 中间所有 cancel 掉的 Task 在 sleep 里就退出，省掉 TaskGroup 重建/调度开销。
    private static let preloadDebounceMs: UInt64 = 70

    init(photo: Photo, allPhotos: [Photo]) {
        _photos = State(initialValue: allPhotos)
        _currentPhotoID = State(initialValue: photo.id)
        // 在 init 里一次性算 preview 解码尺寸——SwiftUI View init 是 @MainActor，可以直接读 screen。
        // 兜底 2556（iPhone 14 Pro 长边 × scale=3）防止 connectedScenes 早期返回空。
        let screen = currentScreen()
        let bounds = screen?.bounds ?? .zero
        let scale = screen?.scale ?? 3.0
        let computed = Int(max(bounds.width, bounds.height) * scale)
        _previewMaxPixel = State(initialValue: max(computed, 2556))
    }

    private var currentIndex: Int {
        photos.firstIndex(where: { $0.id == currentPhotoID }) ?? 0
    }

    private var currentPhoto: Photo? {
        photos.first(where: { $0.id == currentPhotoID })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if photos.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo")
                        .font(.system(size: 80))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("没有照片")
                        .font(.title3)
                        .foregroundColor(.gray)
                }
            } else {
                VStack(spacing: 0) {
                    // SwiftUI 5+ 推荐的分页范式（取代 iOS 16 时代的 TabView .page）：
                    //   ScrollView + LazyHStack + .scrollTargetBehavior(.paging) + .scrollPosition(id:)
                    // 比 TabView 强在：
                    //   1) LazyHStack 真正按需 materialize cell（TabView 也 lazy 但仍要把所有 ForEach
                    //      identifier 物化一遍；上千张照片时差距明显）。
                    //   2) `.scrollPosition(id:)` 是显式的双向 binding，scrubber 同步语义干净；
                    //      旧 TabView selection binding 与 UIPageViewController 内部状态有几个已知 bug。
                    //   3) 后续要加 `.scrollTransition` / `.containerRelativeFrame` 自定义页面进出动画，
                    //      TabView 完全不支持。
                    //   4) 与 iOS 17+ 其它 scroll API（scrollClipDisabled、scrollBounceBehavior、
                    //      scrollTargetLayout）协同自然。
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(photos) { photoItem in
                                PagerImage(
                                    photo: photoItem,
                                    isCurrent: photoItem.id == currentPhotoID,
                                    previewMaxPixel: previewMaxPixel,
                                    onSingleTap: {
                                        // 单击切 chrome——动画从 0.2 缩到 0.12s。`single.require(toFail: double)`
                                        // 已经吃掉 ~250ms 等双击失败，这层动画再多 0.2s 累计感觉很迟钝；
                                        // 0.12s 仍然有过渡感（不会 hard cut）但贴近用户手指 release 的时序。
                                        withAnimation(.easeInOut(duration: 0.12)) { isFullScreen.toggle() }
                                    }
                                )
                                // 每页填满 ScrollView 视口（横+竖）。containerSize 来自外层 ScrollView 的
                                // frame（由 maxHeight: .infinity 在 VStack 里撑开决定），不依赖 LazyHStack
                                // 子项尺寸，所以不会形成"子项要 container 尺寸 / container 要子项尺寸"的循环。
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(photoItem.id)
                            }
                        }
                        // `.scrollTargetLayout()` 把 LazyHStack 标成"snap candidate 集合"——`.paging`
                        // 才知道按子项边界做 page snap，而不是按视口宽度盲滑。
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $currentPhotoID)
                    .scrollIndicators(.hidden)
                    // ScrollView 在 horizontal 模式下默认按内容 intrinsic 高定高；给一个 `maxHeight: .infinity`
                    // 让它在 VStack 里吃满"剩余高度"（scrubber 是固定高），子项的 containerRelativeFrame
                    // 才有稳定的 vertical container 尺寸可参照。
                    .frame(maxHeight: .infinity)
                    // 嵌套 UIScrollView 的原生协议：zoom > 1 时内层 UIScrollView 吃掉 pan 用作平移，
                    // 到水平边界让位给外层 ScrollView 翻页（见 ZoomingScrollView.gestureRecognizerShouldBegin）；
                    // zoom == 1 时内层不可滚，pan 直接给外层 swipe。与 iPhone Photos.app 行为一致。

                    PhotoScrubber(photos: photos, currentPhotoID: $currentPhotoID)
                        .padding(.vertical, 6)
                        .opacity(isFullScreen ? 0 : 1)
                        .animation(.easeInOut(duration: 0.12), value: isFullScreen)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isFullScreen)
        .toolbar(isFullScreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(isFullScreen ? .hidden : .visible, for: .bottomBar)
        .toolbar { navigationToolbar }
        .toolbar { bottomToolbar }
        .statusBarHidden(isFullScreen)
        .onAppear {
            schedulePreheat()
        }
        .onChange(of: currentPhotoID) { _, _ in
            // 翻页/scrubber tap/删除都走这里。统一 debounce ~70ms：快速连翻时只在用户停下后才真正
            // 启动 thumb warmup + ±2 preview 预解，中间所有 cancel 掉的 Task 在 sleep 里就退出，
            // 不会重建 TaskGroup / 不会触发并行 decode。
            // zoom 重置由 ZoomablePhotoView 根据 isCurrent 处理；图片缓存由 NSCache 自然淘汰。
            schedulePreheat()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            ImageLoader.shared.clearCache()
        }
        .alert("删除照片", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteCurrentPhoto() }
        } message: {
            Text("确定要删除这张照片吗？此操作不可撤销。")
        }
        .sheet(isPresented: $showingInfo) {
            if let photo = currentPhoto {
                PhotoInfoPanel(photo: photo, getImageDimensions: getImageDimensions)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Loading

    /// 入口：currentPhotoID 变化时调一次，~70ms debounce 后真正启动 thumb warmup + ±2 preview
    /// 预解。debounce 的存在让快速连翻 5–6 张时只有最后一次落定真正启动预热，中间的 cancel 在
    /// `Task.sleep` 里直接退出，不再重建 TaskGroup / 不再 fire-and-forget 5×N 个 Task。
    /// 不收 index 入参——sleep 唤醒后总是用最新的 `currentIndex`，避免捕获过期快照。
    private func schedulePreheat() {
        thumbWarmupTask?.cancel()
        previewPreloadTask?.cancel()
        let pixel = previewMaxPixel
        let placeholder = Self.placeholderMaxPixel

        thumbWarmupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.preloadDebounceMs * 1_000_000)
            if Task.isCancelled { return }
            let ordered = orderedByDistance(from: currentIndex)
            await withTaskGroup(of: Void.self) { group in
                var inflight = 0
                let cap = 4
                for photo in ordered {
                    if Task.isCancelled { break }
                    if inflight >= cap {
                        _ = await group.next()
                        inflight -= 1
                    }
                    let id = photo.id
                    let data = photo.imageData // MainActor 上读 SwiftData externalStorage
                    group.addTask {
                        _ = await ImageLoader.shared.loadThumbnail(imageData: data, photoId: id, maxPixel: placeholder)
                    }
                    inflight += 1
                }
            }
        }

        // ±2 高分预览：5 张 × ~17MB ≈ 85MB，加 thumb cache 约 111MB，在 NSCache 上限内。
        // ImageLoader 的 in-flight dedup 让同 key 并发请求合一份；这里只做"请求触发"，不等返回。
        previewPreloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.preloadDebounceMs * 1_000_000)
            if Task.isCancelled { return }
            let center = currentIndex
            for i in (center - 2)...(center + 2) where photos.indices.contains(i) {
                if Task.isCancelled { break }
                let photo = photos[i]
                let id = photo.id
                let data = photo.imageData
                Task.detached(priority: .userInitiated) {
                    _ = await ImageLoader.shared.loadPreview(imageData: data, photoId: id, maxPixel: pixel)
                }
            }
        }
    }

    private func orderedByDistance(from index: Int) -> [Photo] {
        var result: [Photo] = []
        result.reserveCapacity(photos.count)
        let count = photos.count
        for d in 0..<count {
            if d == 0 {
                if photos.indices.contains(index) { result.append(photos[index]) }
            } else {
                let right = index + d
                let left = index - d
                if photos.indices.contains(right) { result.append(photos[right]) }
                if photos.indices.contains(left) { result.append(photos[left]) }
            }
        }
        return result
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let photo = currentPhoto {
                VStack(spacing: 1) {
                    Text(photo.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline.weight(.semibold))
                    Text("\(currentIndex + 1) / \(photos.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showingInfo.toggle()
            } label: {
                Image(systemName: "info")
                    .fontWeight(showingInfo ? .bold : .regular)
            }
            .tint(showingInfo ? .yellow : .white)
        }
    }

    @ToolbarContentBuilder
    private var bottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                saveToPhotoLibrary()
            } label: {
                Image(systemName: saveButtonIcon)
            }
            .tint(saveButtonColor)
            .disabled(saveStatus == .saving)
            .accessibilityLabel(saveStatus == .saving ? "保存中" :
                                  saveStatus == .success ? "保存成功" :
                                  saveStatus == .failed ? "保存失败" : "保存到相册")

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("删除这张照片")
        }
    }

    // MARK: - Actions

    private func deleteCurrentPhoto() {
        guard let photoToDelete = currentPhoto else { return }
        let deletedId = photoToDelete.id
        let deletedIdx = currentIndex

        modelContext.delete(photoToDelete)
        do {
            try modelContext.save()
            Log.save.info("photo_deleted id=\(deletedId.uuidString, privacy: .public) remaining=\(self.photos.count - 1)")
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            // 关键：先选好"下一张" id 再 mutate 数组——`scrollPosition(id:)` 的 binding 在删除瞬间就
            // 指向一个仍存在的 photo.id，避免 selection 暂时找不到匹配 id 的瞬态。优先选右邻（idx+1），
            // 最末位时回退到左邻（idx-1）。两次 @State 写入会被 SwiftUI 在同一个 render tick 里 batch。
            let nextID: UUID? = {
                if photos.count <= 1 { return nil }
                if deletedIdx + 1 < photos.count { return photos[deletedIdx + 1].id }
                if deletedIdx - 1 >= 0 { return photos[deletedIdx - 1].id }
                return nil
            }()

            photos.remove(at: deletedIdx)
            ImageLoader.shared.removeDiskCache(for: deletedId)
            // NSCache 内存条目随后续访问/内存压力自然过期；这里无需手动清理 @State 字典
            // 因为已经全部迁移到 NSCache + PagerImage 局部 @State。

            if let nextID {
                currentPhotoID = nextID
            } else {
                dismiss()
            }
        } catch {
            Log.save.error("photo_delete_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private var saveButtonIcon: String {
        switch saveStatus {
        case .none: return "square.and.arrow.down"
        case .saving: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var saveButtonColor: Color {
        switch saveStatus {
        case .none: return .white
        case .saving: return .blue
        case .success: return .green
        case .failed: return .red
        }
    }

    private func getImageDimensions(from imageData: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        return (width, height)
    }

    private func saveToPhotoLibrary() {
        guard let photo = currentPhoto, !photo.imageData.isEmpty else { return }

        saveStatus = .saving
        let imageData = photo.imageData
        let photoRef = photo
        let timer = Log.perf("photos_export", logger: Log.save)
        Log.save.info("photos_export_begin bytes=\(imageData.count) id=\(photo.id.uuidString, privacy: .public)")

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                Log.save.error("photos_auth_denied status=\(status.rawValue)")
                await MainActor.run {
                    saveStatus = .failed
                    resetSaveStatus()
                }
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = photoRef.timestamp

                    if let lat = photoRef.latitude, let lon = photoRef.longitude {
                        request.location = CLLocation(
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            altitude: photoRef.altitude ?? 0,
                            horizontalAccuracy: 10,
                            verticalAccuracy: 10,
                            timestamp: photoRef.locationTimestamp ?? photoRef.timestamp
                        )
                    }

                    let options = PHAssetResourceCreationOptions()
                    // 用 CGImageSource 自适配检测真实 UTI（HEIC/JPEG），不再硬编码——LUT 管线已切到
                    // HEIF 后 imageData 是 HEIC，仍写 "public.jpeg" 会让 PhotoKit 报 PHPhotosErrorDomain 3302
                    // (data 与声明 UTI 不一致)。
                    if let src = CGImageSourceCreateWithData(imageData as CFData, nil),
                       let uti = CGImageSourceGetType(src) {
                        options.uniformTypeIdentifier = uti as String
                    }
                    request.addResource(with: .photo, data: imageData, options: options)
                }

                timer.end("result=ok")
                await MainActor.run {
                    saveStatus = .success
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    resetSaveStatus()
                }
            } catch {
                Log.save.error("photos_export_failed error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    saveStatus = .failed
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    resetSaveStatus()
                }
            }
        }
    }

    private func resetSaveStatus() {
        // Cancellable 句柄：连续点保存或快速离场时，旧的 reset task 不会再覆写到新状态上。
        saveResetTask?.cancel()
        saveResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            saveStatus = .none
        }
    }
}

// MARK: - 详情页单张图项
//
// 把"加载占位 / 加载预览 / 显示交互式 zoom view"打包成自包含 sub-view。
// 内存语义：每个 PagerImage 的 @State preview/asyncThumb 跟随 LazyHStack 页面挂载-卸载自然
// scope；翻到远处的页面被 LazyHStack 卸载后，本地 UIImage 引用一并释放，剩下的全靠 ImageLoader
// 的 NSCache（受 totalCostLimit 自动淘汰）。**详情页层级再不持有任何 [UUID:UIImage] 字典**，
// 大相册不会因为详情页停留而内存爆涨。
//
// 黑屏防护：body 第一次评估就同步查 NSCache（cachedThumbnail / cachedPreview），命中即零延迟
// 显示——不依赖 .task 启动那一帧的时序。aggressive 预热（PhotoDetailView.schedulePreheat）保证缓存
// 通常已热，黑屏 + spinner 的 ZStack 分支只在最坏情况下短暂出现。
private struct PagerImage: View {
    let photo: Photo
    let isCurrent: Bool
    let previewMaxPixel: Int
    let onSingleTap: () -> Void

    @State private var preview: UIImage?
    @State private var asyncThumb: UIImage?

    /// 取图优先级（按分辨率从高到低）：
    ///   State.preview > NSCache preview > State.asyncThumb > NSCache thumb (any size)
    ///
    /// 两个关键点：
    /// 1) `cachedPreview` 必须排在 `asyncThumb` 之前——`handleTap` 已把 preview 预热到 NSCache
    ///    的情况下，首帧显示 cachedPreview（高分），随后 `.task` 把 600px 缩略图写进 `asyncThumb`
    ///    时不能降级，否则主图肉眼可见 高→低→高 闪烁。
    /// 2) **末位用 `anyCachedThumbnail`**（探测多尺寸），而不是只查 `placeholderMaxPixel` 单一尺寸。
    ///    用户从 gallery 点入 detail 那一帧——gallery 的 264 已在内存里——fallback 直接复用，
    ///    立刻有图（虽糊），等 600 / preview 解码完再 soft-swap 升清。**消除黑屏占位窗口**。
    private var displayImage: UIImage? {
        preview
            ?? ImageLoader.shared.cachedPreview(for: photo.id, maxPixel: previewMaxPixel)
            ?? asyncThumb
            ?? ImageLoader.shared.anyCachedThumbnail(for: photo.id)
    }

    var body: some View {
        Group {
            if let image = displayImage {
                ZoomablePhotoView(image: image, isCurrent: isCurrent, onSingleTap: onSingleTap)
            } else {
                ZStack {
                    Color.black
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            }
        }
        .task(id: photo.id) {
            // 已经有任何可显示的图（State 或 NSCache）就不再付低分缩略图的解码——
            // 避免高分 preview 已在 cache 里时还白白解一张 thumb，body 重渲染顺序不当时
            // 还会触发主图降级闪烁。
            if displayImage == nil {
                asyncThumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: PhotoDetailView.placeholderMaxPixel)
            }
            if preview == nil {
                preview = await ImageLoader.shared.loadPreview(for: photo, maxPixel: previewMaxPixel)
            }
        }
    }
}

// MARK: - 可缩放照片视图（UIScrollView 原生路径）
//
// 把 UIScrollView 包成 UIViewRepresentable，让 pinch-zoom / 弹性 / 拖动 / 双击切档 / 惯性
// 都走 UIKit 原生通路。SwiftUI 的 MagnifyGesture + DragGesture 组合在 TabView .page
// 嵌套里有几个已知坑：
//   1) `min(max(scale, 1.0), 5.0)` clamp 到 1，没法 rubber-band；
//   2) lastScale/scale 的同步时序在某些设备上让 pinch-out 卡死，缩放回不到 1.0；
//   3) 翻页与拖动手势必须靠 `including: .all/.none` 互斥，状态机复杂易错。
// UIScrollView 的 viewForZooming + min/max ZoomScale + bouncesZoom 三件套就是 Photos.app
// 同款交互——零自定义状态。
struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage
    /// 当前是否为外层 paging ScrollView 的可见页。从 true → false 时强制把 zoomScale 还原成 fit——
    /// scrubber 切走某页时，下次切回来不会带着旧 zoom + 偏移（与 Photos.app 一致：
    /// 滑离当前页等于"放手"，再回来从头开始）。
    let isCurrent: Bool
    var onSingleTap: (() -> Void)?

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.coordinator = context.coordinator
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        view.setImage(image)
        if !isCurrent && view.zoomScale > view.minimumZoomScale + 0.01 {
            view.setZoomScale(view.minimumZoomScale, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onSingleTap: (() -> Void)?
    }
}

/// imageView 是 zoomable view，frame 在 bounds 里做 aspect-fit；缩放时通过 contentInset 把图
/// 居中——图比 viewport 小时左右/上下加 inset 充当 letterbox，比 viewport 大时 inset=0
/// 让 UIScrollView 接管平移。bouncesZoom 让 pinch-out 越过 minimumZoomScale 时有原生 rubber-band。
final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    weak var coordinator: ZoomablePhotoView.Coordinator?
    private let imageView = UIImageView()
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        delegate = self
        minimumZoomScale = 1.0
        maximumZoomScale = 4.0
        bouncesZoom = true
        // **关键**：zoom == 1 时关掉 pan gesture，让外层 paging ScrollView 独占左右 swipe。
        // 不关的话——即便 contentSize 跟 bounds 一致没有可滚区，UIScrollView 的
        // panGestureRecognizer 仍然 active，会先抢到用户 swipe 判断能不能滚，期间阻断
        // 外层的 page swipe；判完释放，外层已错过 swipe 起点，结果是当前页
        // snap-back 后再 catch-up——用户感知就是"当前照片弹回去，新照片从左边重新弹出"。
        // pinch 走 pinchGestureRecognizer，与 isScrollEnabled 无关，pinch-to-zoom 仍可正常触发。
        isScrollEnabled = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        single.numberOfTapsRequired = 1
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        addGestureRecognizer(single)
        addGestureRecognizer(double)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setImage(_ image: UIImage) {
        let prev = imageView.image
        guard prev !== image else { return }
        imageView.image = image
        // 同源 thumb→preview 升级时 aspect 一致，**不重排**——保留用户当前 zoomScale + offset，
        // UIImageView 直接用更高分辨率的同一帧贴回去，从软到锐零位移。
        // aspect 真正变化时（首次设图 / 切到不同照片）才强制重排并 reset zoom。
        if let prev, sameAspect(prev.size, image.size) {
            return
        }
        lastBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != .zero, imageView.image != nil else { return }
        if bounds.size != lastBoundsSize {
            // 第一次（lastBoundsSize == .zero）走完整 reset；后续的 bounds 变化（chrome 切换 /
            // safe area 变化等）只重算 imageView frame 并按比例 preserve zoomScale + offset，
            // 不打断用户当前的放大查看。
            let isInitial = lastBoundsSize == .zero
            relayoutImage(resetZoom: isInitial, oldBounds: lastBoundsSize)
            lastBoundsSize = bounds.size
        }
        centerImageView()
    }

    private func relayoutImage(resetZoom: Bool, oldBounds: CGSize) {
        guard let image = imageView.image else { return }
        let viewSize = bounds.size
        let imageAspect = image.size.width / image.size.height
        let viewAspect = viewSize.width / viewSize.height
        let fitted: CGSize = imageAspect > viewAspect
            ? CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
            : CGSize(width: viewSize.height * imageAspect, height: viewSize.height)

        if resetZoom {
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            setZoomScale(minimumZoomScale, animated: false)
            return
        }

        // 保 zoom：把 imageView frame 缩放到新 fit 尺寸；contentSize / contentOffset
        // 按 viewport 缩放比例做线性映射，让屏幕上"看到"的相对位置基本不变。
        let scaleX = oldBounds.width > 0 ? viewSize.width / oldBounds.width : 1
        let scaleY = oldBounds.height > 0 ? viewSize.height / oldBounds.height : 1
        let scale = min(scaleX, scaleY) // 安全起见取较小，避免越界
        let oldZoom = zoomScale
        let oldOffset = contentOffset
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = CGSize(width: fitted.width * oldZoom, height: fitted.height * oldZoom)
        setZoomScale(oldZoom, animated: false)
        contentOffset = CGPoint(x: oldOffset.x * scale, y: oldOffset.y * scale)
    }

    private func sameAspect(_ a: CGSize, _ b: CGSize) -> Bool {
        guard a.height > 0, b.height > 0 else { return false }
        return abs(a.width / a.height - b.width / b.height) < 0.01
    }

    private func centerImageView() {
        let viewSize = bounds.size
        let contentSize = imageView.frame.size
        let x = max(0, (viewSize.width - contentSize.width) / 2)
        let y = max(0, (viewSize.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
        // 跟随 zoomScale 切换 pan：放大后允许内层平移；回到 fit 后立即把 pan 还给外层 ScrollView。
        let canPan = zoomScale > minimumZoomScale + 0.01
        if isScrollEnabled != canPan {
            isScrollEnabled = canPan
        }
    }

    @objc private func handleSingleTap() {
        coordinator?.onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let target: CGFloat = 2.0
            let point = gr.location(in: imageView)
            let size = bounds.size
            let rect = CGRect(
                x: point.x - size.width / (2 * target),
                y: point.y - size.height / (2 * target),
                width: size.width / target,
                height: size.height / target
            )
            zoom(to: rect, animated: true)
        }
    }

    // 边界翻页：放大状态下，如果用户在水平边缘起手且 velocity 朝向边缘外侧，**让我们的 pan 直接
    // 不开始**——外层 paging ScrollView 的 UIScrollView pan 就能拿到这串 touches，整页翻过去。
    // 不做这层拦截的话，内层 UIScrollView 永远先抢到 pan：到边缘后只 rubber-band（contentInset 范围内），
    // 跨页翻不出去；用户必须 zoom out 才能切下一张，与 Photos.app 体验断层。
    //
    // 限制条件（缺一不可，避免误伤合法的内层平移）：
    //   1) 是我们这个 panGestureRecognizer（pinch/tap 不管）
    //   2) zoomScale > minimumZoomScale（fit 状态下 isScrollEnabled=false 本就不会跑到这里）
    //   3) 起手 velocity 主导方向是水平（|vx|>|vy|）——竖向平移不会被错让出去
    //   4) 当前 contentOffset 已贴住对应方向的边缘（容差 0.5pt）
    //   5) velocity 朝边缘**外侧**（左边缘+右滑 / 右边缘+左滑）；朝内侧仍归我们处理
    //
    // 用户从中间起手 pan 到边缘的情况不归这里：那条路径会先 rubber-band，松手再起手才能翻——
    // 与 Photos.app 一致（边缘起手才是切页操作）。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let baseDecision = super.gestureRecognizerShouldBegin(gestureRecognizer)
        guard gestureRecognizer === panGestureRecognizer,
              baseDecision,
              zoomScale > minimumZoomScale + 0.01 else {
            return baseDecision
        }
        let velocity = panGestureRecognizer.velocity(in: self)
        guard abs(velocity.x) > abs(velocity.y) else { return baseDecision }

        let leftEdge = -contentInset.left
        let rightEdge = max(leftEdge, contentSize.width - bounds.width + contentInset.right)
        let atLeft = contentOffset.x <= leftEdge + 0.5
        let atRight = contentOffset.x >= rightEdge - 0.5

        if velocity.x > 0 && atLeft { return false }   // 左边缘 + 右滑 → 让外层 ScrollView 翻上一张
        if velocity.x < 0 && atRight { return false }  // 右边缘 + 左滑 → 让外层 ScrollView 翻下一张
        return baseDecision
    }
}


// MARK: - 底部缩略图 scrubber
//
// 设计要点（之前的实现踩过的坑都在这里说明）：
//
// 1) **Selection 来源 = `currentIndex`，不是 `scrollPosition.viewID()`**。
//    旧实现把 cell 的 isSelected 绑到 viewID()——程序化 `scrollTo` 后 viewID() 不一定同步刷新，
//    首次 onAppear 没有任何 cell 显示选中态，"当前 cell"既不放大也无白边，视觉上"不在中心"。
//
// 2) **Tap 直接改 `currentIndex`，不要先 `scrollTo` 再等 commit**。
//    旧实现：tap → scrollTo（程序化）→ 期待 `.idle` phase 触发 `commitFromScroll` 写回
//    currentIndex。但程序化滚动后 viewID() 立即就是目标 id，commitFromScroll 里
//    `idx != currentIndex` 判定不成立——currentIndex **永远不动**，主图不切换。新实现：tap
//    直接 `currentIndex = index`，外层的 `.onChange` 自然把 scrubber 滚到位，TabView 跟着翻页。
//
// 3) **用户手动 scrub 时仅在 `.interacting` → `.idle` 路径上 commit**。
//    程序化 scrollTo 走 `idle → animating → idle`，不经过 interacting；用户手指 drag 走
//    `idle → tracking → interacting → (decelerating) → idle`。用 `userIsScrolling` 标记区
//    分两条路径，杜绝 TabView↔Scrubber 互相覆盖的反馈环（旧实现里 `.idle` 无差别 commit，
//    程序化滚动结束也回写 currentIndex，跟 TabView 滑动产生抢占式覆盖）。
//
// 4) **cell 选中态用 `scaleEffect`，不改 frame size**。
//    旧实现 frame 在 40 ↔ 50 之间切换，LazyHStack 每帧重排 → 滚动位置漂移 → centeredID 又变
//    → 反复抖动。scaleEffect 是渲染层变换，不影响布局，cell 在 strip 里的中心永远在固定栅格上。
private struct PhotoScrubber: View {
    let photos: [Photo]
    /// 与 PhotoDetailView 同源——`UUID?` 而不是 `UUID`：上游 `.scrollPosition(id:)` 会在视口暂时
    /// 找不到任何 item 时把 binding 写成 nil（极少出现，但类型协议里允许）。比较点 `photo.id == currentPhotoID`
    /// 仍按 Optional 的 Equatable lift 规则正常工作。
    @Binding var currentPhotoID: UUID?

    /// 首次 layout 完成后才允许 scrollTo——padding 依赖 geo.size.width，width=0 那一帧
    /// 滚到的位置是错的。latch 一次性置位，避免后续 size 微调反复滚。
    @State private var didInitialScroll = false

    private static let itemSize: CGFloat = 40
    private static let spacing: CGFloat = 6
    /// 选中态视觉放大比例：40 × 1.25 = 50（与旧实现的 selectedSize 视觉一致）。
    /// 用 scaleEffect 实现——不影响 LazyHStack 的布局栅格。
    private static let selectedScale: CGFloat = 1.25

    var body: some View {
        GeometryReader { geo in
            // ScrollViewReader 比 ScrollPosition 更适合这里：
            // proxy.scrollTo(id:anchor: .center) 的 anchor 语义干净——target 中心对齐 viewport
            // 中心，独立于 scrollTargetBehavior 之类的 modifier。
            // 旧实现叠了 .scrollTargetBehavior(.viewAligned) + .scrollPosition($pos, anchor: .center)
            // + scrollPosition.scrollTo(anchor: .center)，三条互相打架——viewAligned 默认按 cell
            // 边缘对齐 viewport 边缘，再加上 scrollPosition 的 binding 写回，最终 cell 被 re-snap
            // 到 viewport trailing edge（**用户感知就是"选中的图片一直在最右边"**）。
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: Self.spacing) {
                        ForEach(photos) { photo in
                            ThumbnailStripCell(
                                photo: photo,
                                isSelected: photo.id == currentPhotoID,
                                selectedScale: Self.selectedScale
                            )
                            .id(photo.id)
                            .onTapGesture { handleTap(photo: photo) }
                        }
                    }
                    // 留白让首/末 cell 也能被 anchor: .center 滚到正中央。
                    // 用 itemSize（布局尺寸），不是放大后的视觉尺寸——padding 跟 layout 走。
                    .padding(.horizontal, max(0, (geo.size.width - Self.itemSize) / 2))
                }
                // initial: true 让 onChange 在 onAppear 那一帧也跑；guard `w > 0` 拦掉布局
                // 未就绪的早期触发；didInitialScroll latch 防止后续 size 微调重复滚动。
                .onChange(of: geo.size.width, initial: true) { _, w in
                    guard !didInitialScroll, w > 0, let id = currentPhotoID else { return }
                    didInitialScroll = true
                    proxy.scrollTo(id, anchor: .center)
                }
                .onChange(of: currentPhotoID) { _, newID in
                    // 曲线 .smooth(0.32) 接近外层 ScrollView `.scrollTargetBehavior(.paging)` 的 settle
                    // 时长（≈0.3s spring）。旧 easeOut 时长接近但 in/out 节奏不一致，快速连翻时 scrubber
                    // 明显落后于主图；.smooth 在中段加速，与主图 paging settle 同步更好。
                    guard let newID else { return }
                    withAnimation(.smooth(duration: 0.32)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
        // 给 scaleEffect 留垂直空间：itemSize × selectedScale + 一点边距。
        .frame(height: Self.itemSize * Self.selectedScale + 6)
    }

    /// 远距离跳转（|Δ|>1）禁用外层 ScrollView 的逐帧 fly-by 动画——用 `Transaction.disablesAnimations`
    /// 强制瞬切。否则从第 1 张点跳到第 20 张，paging ScrollView 会逐帧滑过中间所有页面，慢且会触发
    /// 中间所有 PagerImage 的短暂挂载/卸载，浪费 NSCache 命中。近邻（|Δ|=1）保留动画感。
    private func handleTap(photo: Photo) {
        UISelectionFeedbackGenerator().selectionChanged()
        guard photo.id != currentPhotoID else { return }
        let currentIdx = photos.firstIndex(where: { $0.id == currentPhotoID }) ?? 0
        let newIdx = photos.firstIndex(where: { $0.id == photo.id }) ?? 0
        let distance = abs(newIdx - currentIdx)

        if distance > 1 {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentPhotoID = photo.id
            }
        } else {
            withAnimation(.smooth(duration: 0.32)) {
                currentPhotoID = photo.id
            }
        }
    }
}

// MARK: - 缩略图 cell
//
// 选中态用 `scaleEffect` 放大（不影响布局栅格），并加白边、提亮 opacity。
// **关键**：旧实现切换 frame size，LazyHStack 重排，跟外层 ScrollPosition 互相干扰，
// 滑动时整条 strip 抖动；改成 scaleEffect 后布局完全静止，只有渲染层做仿射变换。
//
// 缩略图统一按 600px 解码（与 PhotoDetailView.placeholderMaxPixel 对齐）——scrubber 与详
// 情页占位共享同一份 NSCache 命中，PhotoDetailView.schedulePreheat 预热完后，scrubber 滚到哪
// 都瞬间有图。
private struct ThumbnailStripCell: View {
    let photo: Photo
    let isSelected: Bool
    let selectedScale: CGFloat
    @State private var thumb: UIImage?

    private static let itemSize: CGFloat = 40
    /// 与 PhotoDetailView.placeholderMaxPixel 同值——共享 NSCache 命中
    private static let loadMaxPixel = 600

    var body: some View {
        Group {
            if let image = thumb {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.1))
            }
        }
        .frame(width: Self.itemSize, height: Self.itemSize)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? .white : .clear, lineWidth: 2)
        )
        .opacity(isSelected ? 1.0 : 0.5)
        .scaleEffect(isSelected ? selectedScale : 1.0)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .task {
            if thumb == nil {
                thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: Self.loadMaxPixel)
            }
        }
    }
}

// MARK: - 照片信息面板
struct PhotoInfoPanel: View {
    let photo: Photo
    let getImageDimensions: (Data) -> (width: Int, height: Int)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.yellow)
                    Text(photo.timestamp, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 14))
                    Spacer()
                }

                Divider()

                HStack {
                    Image(systemName: "film")
                        .foregroundColor(.yellow)
                    Text(photo.filmDisplayName)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                }

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ExifInfoCard(icon: "camera.aperture", title: "光圈", value: photo.aperture)
                    ExifInfoCard(icon: "timer", title: "快门", value: photo.shutterSpeed)
                    ExifInfoCard(icon: "speedometer", title: "ISO", value: photo.iso)
                    ExifInfoCard(icon: "scope", title: "焦距", value: photo.focalLength)
                    ExifInfoCard(icon: "bolt.fill", title: "闪光灯", value: photo.flashMode)
                    if let dims = getImageDimensions(photo.imageData) {
                        ExifInfoCard(icon: "aspectratio", title: "尺寸", value: "\(dims.width)×\(dims.height)")
                    } else {
                        ExifInfoCard(icon: "aspectratio", title: "尺寸", value: "未知")
                    }
                }

                if let lat = photo.latitude, let lon = photo.longitude {
                    Divider()
                    HStack {
                        Image(systemName: "location.fill")
                            .foregroundColor(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.6f, %.6f", lat, lon))
                                .font(.system(size: 13, design: .monospaced))
                            if let alt = photo.altitude {
                                Text("海拔 \(String(format: "%.1f", alt))m")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }

                if let device = photo.deviceInfo {
                    Divider()
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundColor(.yellow)
                        Text("\(device.make) \(device.model)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - EXIF 信息卡片
struct ExifInfoCard: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.yellow.opacity(0.8))
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
