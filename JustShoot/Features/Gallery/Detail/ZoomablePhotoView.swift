import SwiftUI
import SwiftData
import PhotosUI
import ImageIO
import UIKit
import CoreLocation
import os

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
final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let contentView: UIView
    private var naturalSize: CGSize
    private var lastBoundsSize: CGSize = .zero
    private var resizeAnchor: CGPoint?
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

        // The single tap waits for double tap so zoom never also hides controls.
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        single.require(toFail: double)
        addGestureRecognizer(single)
        // Keep PHLivePhotoView's playback accessibility and append our action.
        if contentView is UIImageView {
            contentView.isAccessibilityElement = true
            contentView.accessibilityLabel = String(localized: "Photo preview")
        }
        contentView.accessibilityCustomActions = (contentView.accessibilityCustomActions ?? []) + [UIAccessibilityCustomAction(
            name: String(localized: "Toggle photo controls"), target: self, selector: #selector(toggleAccessibleControls))]

        // 下拉退出 pan：只在 fit 比例 + 向下 + 竖向主导时 begin（见 gestureRecognizerShouldBegin），
        // 单指（maximumNumberOfTouches=1，避免双指捏合误触）。与外层横向分页 pan 并存（不同轴）。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        dismissPan = pan
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var bounds: CGRect {
        willSet { captureResizeAnchor(for: newValue.size) }
    }

    override var frame: CGRect {
        willSet { captureResizeAnchor(for: newValue.size) }
    }

    private func captureResizeAnchor(for size: CGSize) {
        guard size != bounds.size, lastBoundsSize != .zero, resizeAnchor == nil,
              contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        // Capture before UIScrollView adjusts offsets for the new viewport.
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: contentView)
        resizeAnchor = CGPoint(x: center.x / contentView.bounds.width,
            y: center.y / contentView.bounds.height)
    }

    @objc private func handleSingleTap() { dismissController?.toggleChrome() }

    @objc private func toggleAccessibleControls() -> Bool {
        dismissController?.toggleChrome()
        return true
    }

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
            resizeAnchor = nil
            setZoomScale(minimumZoomScale, animated: false)
            contentView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            return
        }

        // Preserve the image point at the viewport's center, rather than scaling
        // offsets by the window dimensions. Refit at 1x before restoring zoom:
        // assigning a fitted frame to an already transformed view shrinks it twice.
        let oldZoom = zoomScale
        let oldSize = contentView.bounds.size
        let center = convert(CGPoint(x: bounds.minX + oldBounds.width / 2,
            y: bounds.minY + oldBounds.height / 2), to: contentView)
        let anchor = resizeAnchor ?? CGPoint(x: oldSize.width > 0 ? center.x / oldSize.width : 0.5,
            y: oldSize.height > 0 ? center.y / oldSize.height : 0.5)
        resizeAnchor = nil
        setZoomScale(minimumZoomScale, animated: false)
        contentView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        setZoomScale(oldZoom, animated: false)
        centerContent()
        let target = CGPoint(x: anchor.x * contentSize.width - viewSize.width / 2,
            y: anchor.y * contentSize.height - viewSize.height / 2)
        contentOffset = CGPoint(
            x: min(max(target.x, -contentInset.left), max(-contentInset.left, contentSize.width - viewSize.width + contentInset.right)),
            y: min(max(target.y, -contentInset.top), max(-contentInset.top, contentSize.height - viewSize.height + contentInset.bottom)))
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
