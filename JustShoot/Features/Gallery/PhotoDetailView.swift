import SwiftUI
import SwiftData
import PhotosUI
import ImageIO
import UIKit
import CoreLocation
import os

// Photo paging, zooming, scrubber and metadata panels live in Detail/.

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
    @Published var chromeHidden = false
    /// 触发实际关闭（PhotoDetailView 在 onAppear 注入 `dismiss()`）。
    var onDismiss: (() -> Void)?
    let usesSystemTransition: Bool

    init(usesSystemTransition: Bool = false) {
        self.usesSystemTransition = usesSystemTransition
    }

    private let dismissDistance: CGFloat = 150   // 位移阈值
    private let dismissVelocity: CGFloat = 900   // 速度阈值（快速向下甩）

    func begin() { dragging = true }

    func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.18)) { chromeHidden.toggle() }
    }

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
    @StateObject private var dismisser: DragDismissController
    private let initialPhotoID: UUID
    private let initialImage: UIImage?
    private let modelIDs: [UUID: PersistentIdentifier]
    private let onSelectionChanged: (UUID) -> Void
    private let onClose: (() -> Void)?

    @State private var photos: [Photo]
    @State private var orderedPhotoIDs: [UUID]
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
    @State private var isPreparingShare = false
    @State private var shareTask: Task<Void, Never>?
    @State private var isDeleting = false
    @State private var localDeletionID: UUID?
    @State private var actionError: String?
    @State private var thumbWarmupTask: Task<Void, Never>?
    @State private var preheatedAssetIDs: [String] = []
    @State private var isVisible = false
    @State private var didPositionPager = false
    @State private var limitsPreviewsToCurrent = false

    /// The thumbnail strip and the pager share one small, display-ready placeholder.
    static let placeholderMaxPixel = PhotoDetailImagePolicy.thumbnailMaxPixel

    /// 翻页/scrubber 触发的预热任务统一 debounce 这么久——快速连翻时只有最后一次落定才真正预热，
    /// 中间所有 cancel 掉的 Task 在 sleep 里就退出，省掉 TaskGroup 重建/调度开销。
    private static let preloadDebounceMs: UInt64 = 70

    /// Warm only the nearby strip, and release PhotoKit's previous preheat window.
    private static let preheatThumbnailRadius = PhotoDetailImagePolicy.thumbnailRadius

    init(photo: Photo, allPhotos: [Photo], initialImage: UIImage? = nil,
         usesSystemTransition: Bool = false, onSelectionChanged: @escaping (UUID) -> Void = { _ in },
         onClose: (() -> Void)? = nil) {
        self.initialPhotoID = photo.id
        self.initialImage = initialImage
        self.modelIDs = Dictionary(uniqueKeysWithValues: allPhotos.map { ($0.id, $0.persistentModelID) })
        self.onSelectionChanged = onSelectionChanged
        self.onClose = onClose
        _dismisser = StateObject(wrappedValue: DragDismissController(usesSystemTransition: usesSystemTransition))
        _photos = State(initialValue: allPhotos)
        _orderedPhotoIDs = State(initialValue: allPhotos.map(\.id))
        _currentPhotoID = State(initialValue: photo.id)
        // 在 init 里一次性算 preview 解码尺寸——SwiftUI View init 是 @MainActor，可以直接读 screen。
        // 兜底 2556（iPhone 14 Pro 长边 × scale=3）防止 connectedScenes 早期返回空。
        let screen = currentScreen()
        let bounds = screen?.bounds ?? .zero
        let scale = screen?.scale ?? 3.0
        _previewMaxPixel = State(initialValue: PhotoDetailImagePolicy.previewMaxPixel(bounds: bounds, scale: scale))
    }

    private var currentIndex: Int {
        orderedPhotoIDs.firstIndex(of: currentPhotoID ?? initialPhotoID) ?? 0
    }

    private var currentPhoto: Photo? {
        // 同时排除已失效（跨视图删除 / 状态恢复后留下的 stale）模型——对已删除的 SwiftData
        // @Model 访问属性会触发 "object has been deleted" 崩溃。
        photos.first(where: { !$0.isDeleted && $0.id == currentPhotoID })
    }

    /// 下拉进度 0…1（位移 / 触发距离的 ~1.6 倍，让缩放/渐暗更克制）。驱动内容 scale + 背景透明度。
    private var dismissProgress: CGFloat {
        min(1, max(0, dismisser.translation) / 240)
    }

    private var chromeVisible: Bool { !dismisser.dragging && !dismisser.chromeHidden }

    var body: some View {
        let previewRange = PhotoDetailImagePolicy.previewRange(count: photos.count, currentIndex: currentIndex)
        let previewIDs = limitsPreviewsToCurrent ? Set(currentPhotoID.map { [$0] } ?? []) : Set(photos[previewRange].map(\.id))
        ZStack {
            // 背景随下拉渐暗（关闭时透出底层相册的过渡感）。
            Color.black.opacity(1 - dismissProgress * 0.6).ignoresSafeArea()

            if photos.isEmpty {
                Text("No photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // 内容整体随下拉做 offset + scale（drag-to-dismiss）。包一层 ZStack 让全屏主图 + 渐变 +
                // chrome 作为一个单位一起变换。
                ZStack {
                    // 分页主图**全屏铺满**（铺到导航栏 / scrubber / 底部工具栏之下），照片占满整屏，
                    // chrome 浮在其上。SwiftUI 5+ 推荐的分页范式（取代 TabView .page）：
                    //   ScrollView + LazyHStack + .scrollTargetBehavior(.paging) + .scrollPosition(id:)。
                    // Measure the full viewport explicitly. containerRelativeFrame subtracts
                    // navigation bars even here, making a single tap resize the photograph.
                    GeometryReader { viewport in
                        ScrollViewReader { reader in
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 0) {
                                    ForEach(photos) { photoItem in
                                        PagerImage(
                                            photo: photoItem,
                                            isCurrent: photoItem.id == currentPhotoID,
                                            loadsPreview: isVisible && previewIDs.contains(photoItem.id),
                                            previewMaxPixel: previewMaxPixel,
                                            dismisser: dismisser,
                                            initialImage: photoItem.id == initialPhotoID ? initialImage : nil
                                        )
                                        .frame(width: viewport.size.width, height: viewport.size.height)
                                        .id(photoItem.id)
                                    }
                                }
                                .scrollTargetLayout()
                            }
                            .scrollTargetBehavior(.paging)
                            .scrollPosition(id: Binding(get: { currentPhotoID }, set: {
                                // Layout can transiently report no visible page. Keep the last
                                // selection so actions and deletion reconciliation stay anchored.
                                if let id = $0 { currentPhotoID = id }
                            }))
                            .scrollIndicators(.hidden)
                            // Toolbars must not add content insets and shift the fitted image.
                            .contentMargins(.all, 0, for: .scrollContent)
                            .task(id: viewport.size.width) {
                                guard #unavailable(iOS 18.0), !didPositionPager, viewport.size.width > 0 else { return }
                                // On iOS 17 the initial scrollPosition can precede the lazy stack's layout.
                                // Position it once the viewport exists, including when opening the last item.
                                await Task.yield()
                                guard !Task.isCancelled, let currentPhotoID else { return }
                                reader.scrollTo(currentPhotoID, anchor: .center)
                                didPositionPager = true
                            }
                        }
                    }
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
                    .opacity(chromeVisible ? 1 : 0)

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
                    .opacity(chromeVisible ? 1 : 0)
                    .allowsHitTesting(chromeVisible)
                    .accessibilityHidden(!chromeVisible)
                }
                .scaleEffect(1 - dismissProgress * 0.15)
                .offset(y: dismisser.translation)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .softScrollEdges(legacyBars: chromeVisible ? [.top, .bottom] : [])
        // 详情页始终不显示底部 tab 栏。
        .toolbar(.hidden, for: .tabBar)
        // 下拉退出时把系统导航栏/底部工具栏一起隐藏，只留照片在动（与 iPhone 相册一致）。
        .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar(chromeVisible ? .visible : .hidden, for: .bottomBar)
        .toolbar { navigationToolbar }
        .toolbar { bottomToolbar }
        .onAppear {
            isVisible = true
            Diagnostics.emit("photo_detail_open", id: currentPhotoID?.uuidString ?? "photo-detail",
                fields: "count=\(photos.count) photos_auth=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
            dismisser.onDismiss = close
            reconcilePhotos()
            schedulePreheat()
        }
        .onChange(of: currentPhotoID) { _, _ in
            if let currentPhotoID { onSelectionChanged(currentPhotoID) }
            limitsPreviewsToCurrent = false
            Diagnostics.emit("photo_detail_selection", id: currentPhotoID?.uuidString ?? "photo-detail")
            // Debounce strip preheat; page identity changes independently cancel obsolete previews.
            schedulePreheat()
        }
        .onDisappear {
            isVisible = false
            shareTask?.cancel()
            shareTask = nil
            cancelPreheat()
            ImageLoader.shared.clearPreviewCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            limitsPreviewsToCurrent = true
            cancelPreheat()
            ImageLoader.shared.clearCache()
            AssetImageLoader.shared.clearCache()
        }
        // 视图存活期间的实时对账：reconcilePhotos 原本只在 onAppear 跑一次，详情页打开期间用户在
        // 「照片」app 删掉当前资产 → PhotoLibrarySync 剪掉索引行 → 快照数组里留下已删 @Model，
        // 渲染读其属性即崩。监听 reconcile 完成通知，把快照与底层数据重新对齐。
        .onReceive(NotificationCenter.default.publisher(for: .photoLibraryDidReconcile)) { _ in
            reconcilePhotos(reloadIndex: true)
        }
        .alert("Photo action failed", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .confirmationDialog("Delete this photo? This cannot be undone.", isPresented: Binding(
            get: { localDeletionID != nil }, set: { if !$0 { localDeletionID = nil } }
        ), titleVisibility: .visible) {
            Button("Delete photo", role: .destructive) {
                if let id = localDeletionID, id == currentPhotoID { deleteCurrentPhoto() }
                localDeletionID = nil
            }
        }
    }

    private func close() {
        if let onClose { onClose() }
        else { dismiss() }
    }

    // MARK: - Loading

    /// Debounce strip preheat so rapid paging cancels work before it reaches a decoder.
    /// 不收 index 入参——sleep 唤醒后总是用最新的 `currentIndex`，避免捕获过期快照。
    private func schedulePreheat() {
        cancelPreheat()
        guard isVisible else { return }
        let placeholder = Self.placeholderMaxPixel

        thumbWarmupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.preloadDebounceMs * 1_000_000)
            if Task.isCancelled { return }
            let ordered = orderedByDistance(from: currentIndex, radius: Self.preheatThumbnailRadius)
            // 资产路径：批量 PHCachingImageManager 预取（idle 后台预解码）；遗留路径：节流解码。
            var assetIDs: [String] = []
            var legacy: [Photo] = []
            for photo in ordered where !photo.isDeleted {
                if let aid = photo.assetLocalIdentifier { assetIDs.append(aid) }
                else { legacy.append(photo) }
            }
            if !assetIDs.isEmpty {
                preheatedAssetIDs = assetIDs
                AssetImageLoader.shared.startCaching(ids: assetIDs, maxPixel: placeholder)
            }
            // Read a legacy blob only after its cached thumbnail misses, one neighbour
            // at a time. Keep speculative decoding behind the visible page's requests.
            for photo in legacy {
                if Task.isCancelled { break }
                _ = await PhotoImage.thumbnail(for: photo, maxPixel: placeholder)
            }
        }

        // PagerImage owns the current/adjacent preview demand. A second preloader
        // would duplicate PhotoKit's high-resolution requests for those same pages.
    }

    private func cancelPreheat() {
        thumbWarmupTask?.cancel()
        thumbWarmupTask = nil
        AssetImageLoader.shared.stopCaching(ids: preheatedAssetIDs, maxPixel: Self.placeholderMaxPixel)
        preheatedAssetIDs.removeAll()
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

        ToolbarItem(placement: .topBarTrailing) {
            // 一键分享当前照片到其他 app：导出全分辨率原图临时文件 → 系统分享面板。
            // 导出期间（异步取原始字节）显示 spinner 并禁用，防连点。
            Button {
                shareCurrentPhoto()
            } label: {
                Group {
                    if isPreparingShare {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .toolbarControlSurface()
            }
            .disabled(isPreparingShare || isDeleting || currentPhoto == nil)
            .accessibilityLabel("Share this photo")
        }
    }

    @ToolbarContentBuilder
    private var bottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                showingInfo.toggle()
            } label: {
                Image(systemName: "info")
                    .fontWeight(showingInfo ? .bold : .regular)
                    .toolbarControlSurface()
            }
            .tint(showingInfo ? .yellow : .white)
            .disabled(currentPhoto == nil)
            .accessibilityLabel("Photo information")
            .popover(isPresented: $showingInfo) {
                if let photo = currentPhoto {
                    PhotoInfoPanel(photo: photo)
                        .frame(idealWidth: 420, idealHeight: 560)
                        .presentationCompactAdaptation(.sheet)
                        .presentationDetents([.medium, .large])
                }
            }
            Spacer()

            // 照片已在系统相册（JustShoot 相簿），无需「保存到相册」。删除走 PhotoKit，系统弹原生
            // 确认 + 「最近删除」可恢复。
            Button(role: .destructive) {
                if let photo = currentPhoto, photo.assetLocalIdentifier == nil {
                    localDeletionID = photo.id
                } else {
                    deleteCurrentPhoto()
                }
            } label: {
                Group {
                    if isDeleting { ProgressView() }
                    else { Image(systemName: "trash") }
                }
                .toolbarControlSurface()
            }
            .disabled(isDeleting || isPreparingShare || currentPhoto == nil)
            .accessibilityLabel("Delete this photo")
        }
    }

    // MARK: - Actions

    /// 与底层数据对账：剔除快照里已被删除 / 失效的 Photo（跨视图删除、状态恢复会留下 stale 引用，
    /// 渲染时访问其属性会崩）。保持相邻位置，整册皆空则退出。
    private func reconcilePhotos(removing removedIDs: Set<UUID> = [], reloadIndex: Bool = false) {
        var indexedModels: Set<PersistentIdentifier>?
        if reloadIndex {
            do {
                let ids = orderedPhotoIDs
                // isDeleted resets after a save. Fetch identities only on reconciliation,
                // never image blobs or the catalog during ordinary paging/UI updates.
                indexedModels = Set(try modelContext.fetchIdentifiers(
                    FetchDescriptor<Photo>(predicate: #Predicate { ids.contains($0.id) })))
            } catch {
                actionError = String(localized: "Photos could not be loaded. Please try again.")
                return
            }
        }
        let live = zip(orderedPhotoIDs, photos).filter { id, photo in
            !removedIDs.contains(id)
                && (indexedModels.map { models in modelIDs[id].map { models.contains($0) } ?? false } ?? true)
                && !photo.isDeleted && photo.modelContext != nil
        }
        let liveIDs = live.map { $0.0 }
        let selection = PhotoDetailSelectionPolicy.selection(current: currentPhotoID,
            previousIDs: orderedPhotoIDs, remainingIDs: liveIDs)
        photos = live.map { $0.1 }
        orderedPhotoIDs = liveIDs
        currentPhotoID = selection
        if selection == nil { close() }
        else { schedulePreheat() }
    }

    /// 分享当前照片：异步导出全分辨率原图临时文件后，从最顶层 VC present 系统分享面板。
    private func shareCurrentPhoto() {
        guard !isPreparingShare, let photo = currentPhoto else { return }
        let photoID = photo.id
        isPreparingShare = true
        shareTask = Task { @MainActor in
            defer { isPreparingShare = false }
            guard let url = await PhotoShareExporter.export(photo) else {
                if !Task.isCancelled, isVisible {
                    actionError = String(localized: "This photo could not be shared. Please try again.")
                }
                return
            }
            guard !Task.isCancelled, isVisible else {
                ShareExportDirectory.application.remove(files: [url])
                return
            }
            SharePresenter.present([url])   // [URL]，包成图片 NSItemProvider 后呈现
            Log.gallery.info("photo_shared id=\(photoID.uuidString, privacy: .public)")
        }
    }

    private func deleteCurrentPhoto() {
        guard !isDeleting, let photoToDelete = currentPhoto else { return }
        isDeleting = true
        let deletedId = photoToDelete.id
        let assetID = photoToDelete.assetLocalIdentifier
        let container = modelContext.container
        let pipeline = CapturePipeline.shared

        // 真相源在系统相册：先 PHAsset 删除（系统弹原生确认）。用户确认 → 更新 UI + 删索引行；
        // 取消 → 抛错，照片原样保留（不做乐观移除，避免删失败后照片"复活"闪烁）。
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                guard let removedIDs = try await PhotoDeletionService(container: container, pipeline: pipeline)
                    .delete(rowIDs: [deletedId], assetIDs: assetID.map { [$0] } ?? []) else {
                    actionError = pipeline.lastError ?? String(localized: "Please wait for these photos to finish saving before deleting them.")
                    return
                }
                reconcilePhotos(removing: removedIDs.union([deletedId]))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Log.save.info("photo_deleted id=\(deletedId.uuidString, privacy: .public)")
            } catch {
                Log.save.info("photo_delete_cancelled_or_failed id=\(deletedId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                let photosError = error as NSError
                if photosError.domain != PHPhotosErrorDomain || photosError.code != PHPhotosError.Code.userCancelled.rawValue {
                    actionError = error.localizedDescription
                }
            }
        }
    }
}
