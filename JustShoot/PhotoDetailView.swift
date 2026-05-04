import SwiftUI
import SwiftData
import PhotosUI
import ImageIO
import UIKit
import CoreLocation
import os

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
        .alert("Delete photo", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteCurrentPhoto() }
        } message: {
            Text("Delete this photo? This cannot be undone.")
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
