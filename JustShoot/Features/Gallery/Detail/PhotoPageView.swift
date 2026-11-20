import SwiftUI
import SwiftData
import PhotosUI
import ImageIO
import UIKit
import CoreLocation
import os

// MARK: - 详情页单张图项（PagerImage）
//
// 把"加载占位 / 加载预览 / 显示交互式 zoom view"打包成自包含 sub-view。
// Explicitly release images outside the current/adjacent window and on disappearance.
// Lazy containers may retain view state after their content scrolls off screen.
//
// 黑屏防护：body 第一次评估就同步查 NSCache（cachedThumbnail / cachedPreview），命中即零延迟
// 显示——不依赖 .task 启动那一帧的时序。aggressive 预热（PhotoDetailView.schedulePreheat）保证缓存
// 通常已热，黑屏 + spinner 的 ZStack 分支只在最坏情况下短暂出现。
struct PagerImage: View {
    let photo: Photo
    let isCurrent: Bool
    let loadsPreview: Bool
    let previewMaxPixel: Int
    let dismisser: DragDismissController
    var initialImage: UIImage?

    @State private var preview: UIImage?
    @State private var asyncThumb: UIImage?
    @State private var loadFailed = false
    @State private var loadAttempt = 0

    private struct LoadRequest: Hashable {
        let photoID: UUID
        let assetID: String?
        let attempt: Int
        let loadsPreview: Bool
    }

    /// 取图优先级（按分辨率从高到低）：
    ///   State.preview > NSCache preview > State.asyncThumb > NSCache thumb (any size)
    ///
    /// 两个关键点：
    /// 1) `cachedPreview` 必须排在 `asyncThumb` 之前——`handleTap` 已把 preview 预热到 NSCache
    ///    的情况下，首帧显示 cachedPreview（高分），随后 `.task` 把缩略图写进 `asyncThumb`
    ///    时不能降级，否则主图肉眼可见 高→低→高 闪烁。
    /// 2) **末位用 `anyCachedThumbnail`**（探测多尺寸），而不是只查 `placeholderMaxPixel` 单一尺寸。
    ///    用户从 gallery 点入 detail 那一帧——gallery 的 264 已在内存里——fallback 直接复用，
    ///    立刻有图（虽糊），等 preview 解码完再升清。
    private var displayImage: UIImage? {
        (loadsPreview ? preview ?? ImageLoader.shared.cachedPreview(for: photo.id, maxPixel: previewMaxPixel) : nil)
            ?? asyncThumb
            ?? assetCachedThumb
            ?? ImageLoader.shared.anyCachedThumbnail(for: photo.id)
            ?? initialImage
    }

    /// 资产路径的同步首帧探测：grid/scrubber 已把 placeholder 尺寸缩略图写进 AssetImageLoader
    /// 缓存时，进详情那一帧直接复用（先糊后清，消除黑屏占位）。
    private var assetCachedThumb: UIImage? {
        guard let aid = photo.assetLocalIdentifier else { return nil }
        return AssetImageLoader.shared.cachedThumbnail(id: aid, maxPixel: PhotoDetailView.placeholderMaxPixel)
    }

    var body: some View {
        Group {
            if photo.isDeleted {
                // 外部/跨视图删除与 reconcile 剪枝之间的窗口：对已删除 @Model 读持久化属性会
                // "object has been deleted" trap，渲染层先于数组剪枝兜底成黑占位。
                Color.black
            } else if photo.isLivePhoto {
                // Live Photo：当前页用可缩放的 PHLivePhotoView（长按播放含音轨）；displayImage 作为
                // live 资源加载前的占位静图。
                LivePhotoPage(
                    photo: photo,
                    isCurrent: isCurrent && loadsPreview,
                    fallback: displayImage,
                    targetMaxPixel: previewMaxPixel,
                    dismisser: dismisser,
                    stillLoadFailed: loadFailed,
                    loadAttempt: $loadAttempt
                )
            } else if let image = displayImage {
                ZoomablePhotoView(image: image, isCurrent: isCurrent, dismisser: dismisser)
            } else {
                ZStack {
                    Color.black
                    VStack(spacing: 12) {
                        if !loadFailed {
                            ProgressView().controlSize(.small).tint(.white)
                                .accessibilityLabel("Loading photo…")
                        } else {
                            PhotoLoadRetry(label: "Unable to load photo") { loadAttempt += 1 }
                        }
                    }
                }
            }
        }
        .onDisappear { preview = nil; asyncThumb = nil }
        .task(id: LoadRequest(photoID: photo.id, assetID: photo.isDeleted ? nil : photo.assetLocalIdentifier,
            attempt: loadAttempt, loadsPreview: loadsPreview)) {
            guard loadsPreview, !photo.isDeleted else {
                preview = nil
                asyncThumb = nil
                return
            }
            let trace = DiagnosticTrace(id: photo.id.uuidString)
            let load = trace.span("photo_page_load", "attempt=\(loadAttempt) asset_backed=\(photo.assetLocalIdentifier != nil)")
            loadFailed = false
            // 已经有任何可显示的图（State 或 NSCache）就不再付低分缩略图的解码——
            // 避免高分 preview 已在 cache 里时还白白解一张 thumb，body 重渲染顺序不当时
            // 还会触发主图降级闪烁。
            await PhotoPageImageLoader.load(thumbnail: {
                guard displayImage == nil else { return nil }
                return await PhotoImage.thumbnail(for: photo, maxPixel: PhotoDetailView.placeholderMaxPixel, trace: trace)
            }, preview: {
                if let preview { return preview }
                return await PhotoImage.preview(for: photo, maxPixel: previewMaxPixel, trace: trace)
            }, onThumbnail: { asyncThumb = $0 }, onPreview: { preview = $0 })
            guard !Task.isCancelled else { load.end("cancelled"); return }
            loadFailed = displayImage == nil
            load.end(preview != nil ? "ok" : loadFailed ? "missing" : "thumbnail_only")
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
    let stillLoadFailed: Bool
    @Binding var loadAttempt: Int

    @State private var livePhoto: PHLivePhoto?
    @State private var liveLoadFailed = false
    @State private var loadedAssetID: String?

    private struct LoadRequest: Hashable {
        let photoID: UUID
        let assetID: String?
        let isCurrent: Bool
        let maxPixel: Int
        let attempt: Int
    }

    var body: some View {
        ZStack {
            Color.black
            if let livePhoto {
                // 可缩放 Live Photo：放进通用 ZoomingScrollView（双指缩放/双击/平移），PHLivePhotoView
                // 自带的长按播放照常。使用 Live Photo 自身尺寸，不依赖静态占位图加载成功。
                ZoomableLivePhotoView(livePhoto: livePhoto, naturalSize: livePhoto.size, isCurrent: isCurrent, dismisser: dismisser)
            } else if let fallback {
                Image(uiImage: fallback)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isCurrent, liveLoadFailed {
                    PhotoLoadRetry(label: "Unable to load Live Photo") { loadAttempt += 1 }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 20)
                }
            } else {
                VStack(spacing: 12) {
                    if stillLoadFailed {
                        PhotoLoadRetry(label: "Unable to load photo") { loadAttempt += 1 }
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                            .accessibilityLabel("Loading photo…")
                    }
                }
            }
        }
        // LIVE 角标不在这里画——图片区会延伸到导航栏下方，贴顶会被导航栏遮挡。改由 PhotoDetailView
        // 在安全区内（导航栏下方）统一绘制，见 body 的 .overlay。
        // photo.id + isCurrent 任一变化都重评估：翻到该页（isCurrent 变 true）即异步加载 live 资源。
        .task(id: LoadRequest(photoID: photo.id, assetID: photo.isDeleted ? nil : photo.assetLocalIdentifier,
            isCurrent: isCurrent, maxPixel: targetMaxPixel, attempt: loadAttempt)) {
            guard !photo.isDeleted, isCurrent else {
                livePhoto = nil
                loadedAssetID = nil
                return
            }
            guard let aid = photo.assetLocalIdentifier,
                  livePhoto == nil || loadedAssetID != aid else { return }
            if loadedAssetID != aid { livePhoto = nil }
            liveLoadFailed = false
            let side = CGFloat(targetMaxPixel)
            let result = await AssetImageLoader.shared.livePhoto(id: aid, targetSize: CGSize(width: side, height: side),
                trace: DiagnosticTrace(id: photo.id.uuidString))
            guard !Task.isCancelled else { return }
            livePhoto = result
            loadedAssetID = aid
            liveLoadFailed = result == nil
        }
        .onDisappear { livePhoto = nil; loadedAssetID = nil }
    }
}

private struct PhotoLoadRetry: View {
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.65), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.25)) }
        }
        .tint(.white)
        .accessibilityLabel(label)
        .accessibilityHint("Retry")
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
        if !isCurrent { context.coordinator.liveView?.stopPlayback() }
        if !isCurrent && view.zoomScale > view.minimumZoomScale + 0.01 {
            view.setZoomScale(view.minimumZoomScale, animated: false)
        }
    }

    static func dismantleUIView(_ view: ZoomingScrollView, coordinator: Coordinator) {
        coordinator.liveView?.stopPlayback()
        coordinator.liveView?.livePhoto = nil
        coordinator.liveView = nil
    }

    final class Coordinator { var liveView: PHLivePhotoView? }
}

/// 左上角 LIVE 标识（仿系统相册详情页）。
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "livephoto")
        }
        .accessibilityLabel("Live Photo")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
