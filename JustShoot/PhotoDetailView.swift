import SwiftUI
import SwiftData
import PhotosUI
import ImageIO
import UIKit
import CoreLocation
import os

// MARK: - 照片详情
//
// 单文件覆盖整个详情页的渲染树：分页主图（PagerImage）/ pinch-zoom UIScrollView 包装
// (ZoomablePhotoView + ZoomingScrollView) / 底部缩略图 scrubber（PhotoScrubber +
// ThumbnailStripCell) / EXIF info sheet（PhotoInfoPanel + ExifInfoCard）。
//
// 这些子类型彼此紧耦合 —— 仅由 PhotoDetailView 使用，共享同一份 currentPhotoID binding 与
// NSCache 命中策略。同文件 + `private` 比拆 N 个 ~100 行的 helper file 更内聚，与 Apple
// SwiftUI sample 的"feature 一文件"做法一致。

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

    /// thumb warmup 只预热当前页 ±N 张，不是整册。原实现 orderedByDistance 走 0..<count——
    /// 即便有 cap=4 节流，仍会逐张在 MainActor 上 fault 整个 externalStorage blob（5000 张 =
    /// 5000 次磁盘读 + 瞬时内存）。thumb 用 50 项共享 NSCache，预热整册只会自相淘汰，纯浪费。
    private static let preheatThumbnailRadius = 12

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
        // 同时排除已失效（跨视图删除 / 状态恢复后留下的 stale）模型——对已删除的 SwiftData
        // @Model 访问属性会触发 "object has been deleted" 崩溃。
        photos.first(where: { $0.id == currentPhotoID && !$0.isDeleted })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if photos.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo")
                        .font(.system(size: 80))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("No photos")
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
        // 详情页（从相册 push 进来）始终不显示底部 tab 栏。
        .toolbar(.hidden, for: .tabBar)
        .toolbar(isFullScreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(isFullScreen ? .hidden : .visible, for: .bottomBar)
        .toolbar { navigationToolbar }
        .toolbar { bottomToolbar }
        .statusBarHidden(isFullScreen)
        .onAppear {
            reconcilePhotos()
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
        .alert("Delete photo", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteCurrentPhoto() }
        } message: {
            Text("Delete this photo? This cannot be undone.")
        }
        .sheet(isPresented: $showingInfo) {
            if let photo = currentPhoto {
                PhotoInfoPanel(photo: photo)
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
            let ordered = orderedByDistance(from: currentIndex, radius: Self.preheatThumbnailRadius)
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

    /// 当前页向两侧交替展开的 Photo 列表，最多到 ±radius——预热只关心邻近页，不走整册。
    private func orderedByDistance(from index: Int, radius: Int) -> [Photo] {
        var result: [Photo] = []
        let count = photos.count
        let maxD = min(radius, count)
        result.reserveCapacity(min(2 * radius + 1, count))
        for d in 0...maxD {
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
            .accessibilityLabel(saveStatus == .saving ? Text("Saving…") :
                                  saveStatus == .success ? Text("Saved") :
                                  saveStatus == .failed ? Text("Save failed") : Text("Save to Photos"))

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete this photo")
        }
    }

    // MARK: - Actions

    /// 与底层数据对账：剔除快照里已被删除 / 失效的 Photo（跨视图删除、状态恢复会留下 stale 引用，
    /// 渲染时访问其属性会崩）。剔除后若当前选中项已不存在，则改选首张，整册皆空则退出。
    private func reconcilePhotos() {
        let live = photos.filter { !$0.isDeleted }
        if live.count != photos.count {
            photos = live
        }
        if currentPhoto == nil {
            if let first = photos.first {
                currentPhotoID = first.id
            } else {
                dismiss()
            }
        }
    }

    private func deleteCurrentPhoto() {
        guard let photoToDelete = currentPhoto else { return }
        let deletedId = photoToDelete.id
        let deletedIdx = currentIndex
        let container = modelContext.container

        // 关键：先选好"下一张" id 再 mutate 数组——`scrollPosition(id:)` 的 binding 在删除瞬间就
        // 指向一个仍存在的 photo.id，避免 selection 暂时找不到匹配 id 的瞬态。优先选右邻（idx+1），
        // 最末位时回退到左邻（idx-1）。两次 @State 写入会被 SwiftUI 在同一个 render tick 里 batch。
        let nextID: UUID? = {
            if photos.count <= 1 { return nil }
            if deletedIdx + 1 < photos.count { return photos[deletedIdx + 1].id }
            if deletedIdx - 1 >= 0 { return photos[deletedIdx - 1].id }
            return nil
        }()

        // 乐观 UI：立即从本地快照移除并切换选中项；SwiftData 删除/落盘 + disk cache 清理走后台
        // actor（与 GalleryView.deleteSelectedPhotos 一致），不再在主线程同步 save 阻塞翻页/缩放动画。
        photos.remove(at: deletedIdx)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let nextID {
            currentPhotoID = nextID
        } else {
            dismiss()
        }

        Task.detached(priority: .userInitiated) {
            do {
                let saver = PhotoSaver(modelContainer: container)
                try await saver.delete(ids: [deletedId])
                ImageLoader.shared.removeDiskCache(for: deletedId)
                Log.save.info("photo_deleted id=\(deletedId.uuidString, privacy: .public)")
            } catch {
                Log.save.error("photo_delete_failed id=\(deletedId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
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

// MARK: - 详情页单张图项（PagerImage）
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
private struct ZoomablePhotoView: UIViewRepresentable {
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
private final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
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
private struct PhotoInfoPanel: View {
    let photo: Photo
    /// 离主线程解析后填入；初始 .empty 让首帧显示占位（"Unknown"），解析完成再刷新。
    /// 关键：解析（CGImageSource + 元数据 copy）从前述 body 内的 @MainActor 同步路径挪到 .task
    /// 的 detached 子任务，info 面板首次展开不再卡主线程 fault + 解析整张 22MP HEIF。
    @State private var exif: ParsedExifInfo = .empty

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
                    ExifInfoCard(icon: "camera.aperture", title: "Aperture", value: exif.aperture)
                    ExifInfoCard(icon: "timer", title: "Shutter", value: exif.shutterSpeed)
                    ExifInfoCard(icon: "speedometer", title: "ISO", value: exif.iso)
                    ExifInfoCard(icon: "scope", title: "Focal length", value: exif.focalLength)
                    ExifInfoCard(icon: "bolt.fill", title: "Flash", value: exif.flashMode)
                    if let w = exif.pixelWidth, let h = exif.pixelHeight {
                        ExifInfoCard(icon: "aspectratio", title: "Size", value: "\(w)×\(h)")
                    } else {
                        ExifInfoCard(icon: "aspectratio", title: "Size", value: String(localized: "Unknown"))
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
                                Text("Altitude \(String(format: "%.1f", alt))m")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }

                if let device = exif.deviceInfo {
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
        .task(id: photo.id) {
            let data = photo.imageData   // MainActor 读 externalStorage（一次）
            exif = await Task.detached(priority: .userInitiated) {
                ParsedExifInfo.parse(from: data)
            }.value
        }
    }
}

// MARK: - EXIF 信息卡片
private struct ExifInfoCard: View {
    let icon: String
    let title: LocalizedStringKey
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
