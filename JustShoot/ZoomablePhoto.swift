import SwiftUI
import UIKit

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
