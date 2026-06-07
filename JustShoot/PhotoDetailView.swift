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

// MARK: - 下拉退出控制器
//
// 交互式 drag-to-dismiss（iPhone 相册手感）：fit 比例下向下拖 → 照片跟手下移 + 缩小、背景渐暗、
// chrome 隐藏；过阈值（距离 or 速度）松手即关闭，否则弹回。手势由每页的 ZoomingScrollView 上一个
// 受控 UIPanGestureRecognizer 驱动（只在 fit 比例 + 向下 + 竖向主导时 begin，放大态让位给平移、
// 横滑翻页不受影响），把竖向位移回报给本控制器，PhotoDetailView 据此变换内容并决定关闭。
@MainActor
final class DragDismissController: ObservableObject {
    /// 当前向下位移（pt，>=0）。驱动内容 offset/scale + 背景透明度。
    @Published var translation: CGFloat = 0
    /// 是否正在下拉。驱动 chrome（导航栏/工具栏/scrubber/角标）的隐藏。
    @Published var dragging = false
    /// 触发实际关闭（PhotoDetailView 在 onAppear 注入 `dismiss()`）。
    var onDismiss: (() -> Void)?

    private let dismissDistance: CGFloat = 150   // 位移阈值
    private let dismissVelocity: CGFloat = 900   // 速度阈值（快速向下甩）

    func begin() { dragging = true }

    func update(_ dy: CGFloat) {
        translation = max(0, dy)
    }

    func end(translation dy: CGFloat, velocity vy: CGFloat) {
        if dy > dismissDistance || vy > dismissVelocity {
            onDismiss?()
            // 关闭动画走 cover 自身；这里不重置，避免回弹一帧。
        } else {
            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.85)) {
                translation = 0
            }
            dragging = false
        }
    }
}

struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var dismisser = DragDismissController()

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
    @State private var showingInfo = false
    @State private var thumbWarmupTask: Task<Void, Never>?
    @State private var previewPreloadTask: Task<Void, Never>?

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

    /// 下拉进度 0…1（位移 / 触发距离的 ~1.6 倍，让缩放/渐暗更克制）。驱动内容 scale + 背景透明度。
    private var dismissProgress: CGFloat {
        min(1, max(0, dismisser.translation) / 240)
    }

    var body: some View {
        ZStack {
            // 背景随下拉渐暗（关闭时透出底层相册的过渡感）。
            Color.black.opacity(1 - dismissProgress * 0.6).ignoresSafeArea()

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
                // 内容整体随下拉做 offset + scale（drag-to-dismiss）。包一层 ZStack 让全屏主图 + 渐变 +
                // chrome 作为一个单位一起变换。
                ZStack {
                    // 分页主图**全屏铺满**（铺到导航栏 / scrubber / 底部工具栏之下），照片占满整屏，
                    // chrome 浮在其上。SwiftUI 5+ 推荐的分页范式（取代 TabView .page）：
                    //   ScrollView + LazyHStack + .scrollTargetBehavior(.paging) + .scrollPosition(id:)。
                    // 每页用 containerRelativeFrame 填满 ScrollView 视口（现在因 ignoresSafeArea = 全屏），
                    // ZoomingScrollView 据此把图 aspect-fit 到整屏——竖图填满竖屏高度。
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(photos) { photoItem in
                                PagerImage(
                                    photo: photoItem,
                                    isCurrent: photoItem.id == currentPhotoID,
                                    previewMaxPixel: previewMaxPixel,
                                    dismisser: dismisser
                                )
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(photoItem.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $currentPhotoID)
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea()

                    // 底部可读性渐变：让浮在亮图上的 scrubber / 底部工具栏仍清晰。纯装饰，不拦手势。
                    // 下拉时隐藏（只留照片在动）。
                    VStack {
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 150)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .opacity(dismisser.dragging ? 0 : 1)

                    // chrome 层（**安全区内**：上沿落在导航栏下方、下沿落在底部工具栏上方），浮在全屏图上。
                    // 中间是空 Spacer（不拦截手势）→ 主图区的缩放/平移/翻页手势照常穿透到下层 ScrollView；
                    // 只有顶部 LIVE 角标与底部 scrubber 这两个实体区域参与命中。下拉时隐藏。
                    VStack(spacing: 0) {
                        HStack {
                            if let p = currentPhoto, p.isLivePhoto {
                                LiveBadge().allowsHitTesting(false)
                            }
                            Spacer()
                        }
                        .padding(.leading, 16)
                        .padding(.top, 8)

                        Spacer()

                        PhotoScrubber(photos: photos, currentPhotoID: $currentPhotoID)
                            .padding(.vertical, 6)
                    }
                    .opacity(dismisser.dragging ? 0 : 1)
                }
                .scaleEffect(1 - dismissProgress * 0.15)
                .offset(y: dismisser.translation)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // 详情页（从相册 push 进来）始终不显示底部 tab 栏。
        .toolbar(.hidden, for: .tabBar)
        // 下拉退出时把系统导航栏/底部工具栏一起隐藏，只留照片在动（与 iPhone 相册一致）。
        .toolbar(dismisser.dragging ? .hidden : .visible, for: .navigationBar)
        .toolbar(dismisser.dragging ? .hidden : .visible, for: .bottomBar)
        .toolbar { navigationToolbar }
        .toolbar { bottomToolbar }
        .onAppear {
            dismisser.onDismiss = { dismiss() }
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
            // 资产路径：批量 PHCachingImageManager 预取（idle 后台预解码）；遗留路径：节流解码。
            var assetIDs: [String] = []
            var legacy: [(UUID, Data)] = []
            for photo in ordered {
                if let aid = photo.assetLocalIdentifier { assetIDs.append(aid) }
                else if let data = photo.imageData { legacy.append((photo.id, data)) }
            }
            if !assetIDs.isEmpty {
                AssetImageLoader.shared.startCaching(ids: assetIDs, maxPixel: placeholder)
            }
            if !legacy.isEmpty {
                await withTaskGroup(of: Void.self) { group in
                    var inflight = 0
                    let cap = 4
                    for (id, data) in legacy {
                        if Task.isCancelled { break }
                        if inflight >= cap {
                            _ = await group.next()
                            inflight -= 1
                        }
                        group.addTask {
                            _ = await ImageLoader.shared.loadThumbnail(imageData: data, photoId: id, maxPixel: placeholder)
                        }
                        inflight += 1
                    }
                }
            }
        }

        // ±2 高分预览预热：资产走 PHImageManager（自带缓存），遗留走 ImageLoader。PhotoImage 在
        // @MainActor 上分流后进入异步取图；顺序 await 即可（命中后立即返回）。
        previewPreloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.preloadDebounceMs * 1_000_000)
            if Task.isCancelled { return }
            let center = currentIndex
            for i in (center - 2)...(center + 2) where photos.indices.contains(i) {
                if Task.isCancelled { break }
                _ = await PhotoImage.preview(for: photos[i], maxPixel: pixel)
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
            Spacer()

            // 照片已在系统相册（JustShoot 相簿），无需「保存到相册」。删除走 PhotoKit，系统弹原生
            // 确认 + 「最近删除」可恢复。
            Button(role: .destructive) {
                deleteCurrentPhoto()
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
        let assetID = photoToDelete.assetLocalIdentifier
        let container = modelContext.container

        // 先选好"下一张" id：删除确认后 `scrollPosition(id:)` 的 binding 立刻指向仍存在的 photo.id，
        // 避免 selection 瞬态。优先右邻（idx+1），最末位回退左邻（idx-1）。
        let nextID: UUID? = {
            if photos.count <= 1 { return nil }
            if deletedIdx + 1 < photos.count { return photos[deletedIdx + 1].id }
            if deletedIdx - 1 >= 0 { return photos[deletedIdx - 1].id }
            return nil
        }()

        // 真相源在系统相册：先 PHAsset 删除（系统弹原生确认）。用户确认 → 更新 UI + 删索引行；
        // 取消 → 抛错，照片原样保留（不做乐观移除，避免删失败后照片"复活"闪烁）。
        Task { @MainActor in
            do {
                if let assetID { try await PhotoLibrary.delete(localIdentifiers: [assetID]) }
                if let idx = photos.firstIndex(where: { $0.id == deletedId }) {
                    photos.remove(at: idx)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if let nextID { currentPhotoID = nextID } else { dismiss() }
                let saver = PhotoSaver(modelContainer: container)
                try await saver.delete(ids: [deletedId])
                ImageLoader.shared.removeDiskCache(for: deletedId)
                Log.save.info("photo_deleted id=\(deletedId.uuidString, privacy: .public)")
            } catch {
                Log.save.info("photo_delete_cancelled_or_failed id=\(deletedId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
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
    let dismisser: DragDismissController

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
            ?? assetCachedThumb
            ?? ImageLoader.shared.anyCachedThumbnail(for: photo.id)
    }

    /// 资产路径的同步首帧探测：grid/scrubber 已把 placeholder 尺寸缩略图写进 AssetImageLoader
    /// 缓存时，进详情那一帧直接复用（先糊后清，消除黑屏占位）。
    private var assetCachedThumb: UIImage? {
        guard let aid = photo.assetLocalIdentifier else { return nil }
        return AssetImageLoader.shared.cachedThumbnail(id: aid, maxPixel: PhotoDetailView.placeholderMaxPixel)
    }

    var body: some View {
        Group {
            if photo.isLivePhoto {
                // Live Photo：当前页用可缩放的 PHLivePhotoView（长按播放含音轨）；displayImage 作为
                // live 资源加载前的占位静图。
                LivePhotoPage(
                    photo: photo,
                    isCurrent: isCurrent,
                    fallback: displayImage,
                    targetMaxPixel: previewMaxPixel,
                    dismisser: dismisser
                )
            } else if let image = displayImage {
                ZoomablePhotoView(image: image, isCurrent: isCurrent, dismisser: dismisser)
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
                asyncThumb = await PhotoImage.thumbnail(for: photo, maxPixel: PhotoDetailView.placeholderMaxPixel)
            }
            if preview == nil {
                preview = await PhotoImage.preview(for: photo, maxPixel: previewMaxPixel)
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
    let dismisser: DragDismissController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.image = image
        context.coordinator.imageView = iv
        return ZoomingScrollView(contentView: iv, naturalSize: image.size, dismiss: dismisser)
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        if let iv = context.coordinator.imageView, iv.image !== image {
            // 同源 thumb→preview 升清：直接换 UIImageView 的图，aspect 一致时 updateNaturalSize
            // 不重排、保留 zoom（从软到锐零位移）；aspect 变才重排。
            iv.image = image
            view.updateNaturalSize(image.size)
        }
        if !isCurrent && view.zoomScale > view.minimumZoomScale + 0.01 {
            view.setZoomScale(view.minimumZoomScale, animated: false)
        }
    }

    final class Coordinator { var imageView: UIImageView? }
}

/// imageView 是 zoomable view，frame 在 bounds 里做 aspect-fit；缩放时通过 contentInset 把图
/// 居中——图比 viewport 小时左右/上下加 inset 充当 letterbox，比 viewport 大时 inset=0
/// 让 UIScrollView 接管平移。bouncesZoom 让 pinch-out 越过 minimumZoomScale 时有原生 rubber-band。
// 内容无关：承载任意 contentView（静图 UIImageView / Live Photo PHLivePhotoView）+ 一个
// naturalSize（用于 aspect-fit）。缩放/平移/双击/边界翻页逻辑两类内容完全复用。
private final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let contentView: UIView
    private var naturalSize: CGSize
    private var lastBoundsSize: CGSize = .zero
    /// 下拉退出控制器（弱引用，由 SwiftUI 层持有）。dismissPan 把竖向位移回报给它。
    private weak var dismissController: DragDismissController?
    private var dismissPan: UIPanGestureRecognizer!

    init(contentView: UIView, naturalSize: CGSize, dismiss: DragDismissController) {
        self.contentView = contentView
        self.naturalSize = naturalSize
        self.dismissController = dismiss
        super.init(frame: .zero)
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
        // 对 Live Photo：PHLivePhotoView 自带的「触摸长按播放」是长按手势，与本类的 pan/pinch/双击
        // 互不冲突，fit 态（pan 关）下长按照常播放。
        isScrollEnabled = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast

        contentView.isUserInteractionEnabled = true   // PHLivePhotoView 需要它接收长按播放
        addSubview(contentView)

        // 双击放大/还原。单击不再有交互（已去掉沉浸模式），故不再注册单击识别器，也无需
        // require(toFail:)——双击直接生效，无 ~250ms 等待。
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)

        // 下拉退出 pan：只在 fit 比例 + 向下 + 竖向主导时 begin（见 gestureRecognizerShouldBegin），
        // 单指（maximumNumberOfTouches=1，避免双指捏合误触）。与外层横向分页 pan 并存（不同轴）。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        dismissPan = pan
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// 内容自然尺寸更新（静图 thumb→preview 升清、或切到另一张/另一段 Live Photo）。
    /// aspect 不变（同源升清）→ 不重排、保留当前 zoom + offset；aspect 变 → 重排并 reset zoom。
    func updateNaturalSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if sameAspect(naturalSize, size) { naturalSize = size; return }
        naturalSize = size
        lastBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != .zero, naturalSize.width > 0, naturalSize.height > 0 else { return }
        if bounds.size != lastBoundsSize {
            // 第一次（lastBoundsSize == .zero）走完整 reset；后续的 bounds 变化（旋转 /
            // safe area 变化等）只重算 content frame 并按比例 preserve zoomScale + offset，
            // 不打断用户当前的放大查看。
            let isInitial = lastBoundsSize == .zero
            relayoutContent(resetZoom: isInitial, oldBounds: lastBoundsSize)
            lastBoundsSize = bounds.size
        }
        centerContent()
    }

    private func relayoutContent(resetZoom: Bool, oldBounds: CGSize) {
        let viewSize = bounds.size
        let aspect = naturalSize.width / naturalSize.height
        let viewAspect = viewSize.width / viewSize.height
        let fitted: CGSize = aspect > viewAspect
            ? CGSize(width: viewSize.width, height: viewSize.width / aspect)
            : CGSize(width: viewSize.height * aspect, height: viewSize.height)

        if resetZoom {
            contentView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            setZoomScale(minimumZoomScale, animated: false)
            return
        }

        // 保 zoom：把 content frame 缩放到新 fit 尺寸；contentSize / contentOffset
        // 按 viewport 缩放比例做线性映射，让屏幕上"看到"的相对位置基本不变。
        let scaleX = oldBounds.width > 0 ? viewSize.width / oldBounds.width : 1
        let scaleY = oldBounds.height > 0 ? viewSize.height / oldBounds.height : 1
        let scale = min(scaleX, scaleY) // 安全起见取较小，避免越界
        let oldZoom = zoomScale
        let oldOffset = contentOffset
        contentView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = CGSize(width: fitted.width * oldZoom, height: fitted.height * oldZoom)
        setZoomScale(oldZoom, animated: false)
        contentOffset = CGPoint(x: oldOffset.x * scale, y: oldOffset.y * scale)
    }

    private func sameAspect(_ a: CGSize, _ b: CGSize) -> Bool {
        guard a.height > 0, b.height > 0 else { return false }
        return abs(a.width / a.height - b.width / b.height) < 0.01
    }

    private func centerContent() {
        let viewSize = bounds.size
        let size = contentView.frame.size
        let x = max(0, (viewSize.width - size.width) / 2)
        let y = max(0, (viewSize.height - size.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        // 跟随 zoomScale 切换 pan：放大后允许内层平移；回到 fit 后立即把 pan 还给外层 ScrollView。
        let canPan = zoomScale > minimumZoomScale + 0.01
        if isScrollEnabled != canPan {
            isScrollEnabled = canPan
        }
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let target: CGFloat = 2.0
            let point = gr.location(in: contentView)
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
        // 下拉退出 pan：仅 fit 比例（未放大）+ 起手向下 + 竖向主导才启用。放大态让位给内层平移，
        // 横向/向上手势不触发——横滑翻页与放大平移都不受影响。
        if gestureRecognizer === dismissPan {
            guard zoomScale <= minimumZoomScale + 0.01 else { return false }
            let v = dismissPan.velocity(in: self)
            return v.y > 0 && abs(v.y) > abs(v.x) * 1.2
        }
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

    // 让下拉退出 pan 与外层横向分页 ScrollView 的 pan 并存（不同轴，不会真冲突）。返回 true 即足以
    // 允许同时识别（UIKit：任一方返回 true 即放行）。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === dismissPan
    }

    // 下拉退出手势驱动。位移/速度用 **window 坐标** 量取——内容正被 SwiftUI offset 下移，若用 self
    // 坐标会与位移形成反馈环（量到的位移被自身移动抵消）。window 不变换，量到的就是真实手指位移。
    @objc private func handleDismissPan(_ gr: UIPanGestureRecognizer) {
        let ref: UIView = window ?? self
        switch gr.state {
        case .began:
            dismissController?.begin()
        case .changed:
            dismissController?.update(gr.translation(in: ref).y)
        case .ended, .cancelled, .failed:
            dismissController?.end(translation: gr.translation(in: ref).y,
                                   velocity: gr.velocity(in: ref).y)
        default:
            break
        }
    }
}

// MARK: - Live Photo 页（PHLivePhotoView 长按播放）
//
// 当前页是 Live Photo 时替代 ZoomablePhotoView：基于 PHLivePhotoView，系统自带「触摸并长按播放」
// 手势（含音轨）。加载 PHLivePhoto 前先显示 fallback 静图（消除黑屏）。左上角 LIVE 角标做静态标识。
// 只为 isCurrent 的页加载 live 资源——相邻页只显示静图占位，省内存。
private struct LivePhotoPage: View {
    let photo: Photo
    let isCurrent: Bool
    let fallback: UIImage?
    let targetMaxPixel: Int
    let dismisser: DragDismissController

    @State private var livePhoto: PHLivePhoto?

    var body: some View {
        ZStack {
            Color.black
            if let livePhoto, let size = fallback?.size {
                // 可缩放 Live Photo：放进通用 ZoomingScrollView（双指缩放/双击/平移），PHLivePhotoView
                // 自带的长按播放照常。naturalSize 取自 fallback 静图（与 Live Photo 同次拍摄、aspect 一致）。
                ZoomableLivePhotoView(livePhoto: livePhoto, naturalSize: size, isCurrent: isCurrent, dismisser: dismisser)
            } else if let fallback {
                Image(uiImage: fallback)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        // LIVE 角标不在这里画——图片区会延伸到导航栏下方，贴顶会被导航栏遮挡。改由 PhotoDetailView
        // 在安全区内（导航栏下方）统一绘制，见 body 的 .overlay。
        // photo.id + isCurrent 任一变化都重评估：翻到该页（isCurrent 变 true）即异步加载 live 资源。
        .task(id: "\(photo.id.uuidString)-\(isCurrent)") {
            guard isCurrent, livePhoto == nil, let aid = photo.assetLocalIdentifier else { return }
            let side = CGFloat(targetMaxPixel)
            livePhoto = await AssetImageLoader.shared.livePhoto(id: aid, targetSize: CGSize(width: side, height: side))
        }
    }
}

/// 可缩放 Live Photo：PHLivePhotoView 放进通用 ZoomingScrollView，复用静图那套缩放/平移/双击/
/// 边界翻页逻辑。PHLivePhotoView 自带的「触摸长按播放」（含音轨）是长按手势，与缩放/平移互不冲突。
private struct ZoomableLivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let naturalSize: CGSize
    let isCurrent: Bool
    let dismisser: DragDismissController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let lpv = PHLivePhotoView()
        lpv.contentMode = .scaleAspectFit
        lpv.livePhoto = livePhoto
        context.coordinator.liveView = lpv
        return ZoomingScrollView(contentView: lpv, naturalSize: naturalSize, dismiss: dismisser)
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        if let lpv = context.coordinator.liveView, lpv.livePhoto !== livePhoto {
            lpv.livePhoto = livePhoto
            view.updateNaturalSize(naturalSize)
        }
        // 切走当前页时还原 zoom（与静图一致）。
        if !isCurrent && view.zoomScale > view.minimumZoomScale + 0.01 {
            view.setZoomScale(view.minimumZoomScale, animated: false)
        }
    }

    final class Coordinator { var liveView: PHLivePhotoView? }
}

/// 左上角 LIVE 标识（仿系统相册详情页）。
private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "livephoto")
            Text("LIVE")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
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
                thumb = await PhotoImage.thumbnail(for: photo, maxPixel: Self.loadMaxPixel)
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
            // 资产照片从系统相册异步取原始字节再解析；遗留照片直接读内部 blob。
            guard let data = await PhotoImage.exifData(for: photo) else { return }
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
