import SwiftUI

enum StartupIntroTiming {
    static let traceDuration: TimeInterval = 0.62
    static let holdDuration: TimeInterval = 0.08
    static let expansionDuration: TimeInterval = 0.36

    static func expansionStart(tracingFrom start: CFTimeInterval, homeReadyAt ready: CFTimeInterval) -> CFTimeInterval {
        max(start + traceDuration + holdDuration, ready)
    }
}

struct AppStartupIntro: View {
    let homeReady: Bool
    @Binding var isFinished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: CFTimeInterval?
    @State private var opensAt: CFTimeInterval?
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            Color.clear
            if !reduceMotion && !isFinished {
                StartupIris(startedAt: startedAt, opensAt: opensAt)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if showsProgress && !homeReady {
                ProgressView()
                    .tint(.secondary)
                    .padding(.bottom, 28)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preparing your library…"))
        .accessibilityIdentifier("preparation_screen")
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            if reduced {
                isFinished = true
            } else if !isFinished && startedAt == nil {
                startedAt = CACurrentMediaTime()
            }
        }
        .task(id: homeReady && startedAt != nil) {
            guard homeReady, !isFinished, let startedAt else { return }
            let now = CACurrentMediaTime()
            let opening = StartupIntroTiming.expansionStart(tracingFrom: startedAt, homeReadyAt: now)
            opensAt = opening
            do { try await Task.sleep(for: .seconds(opening - now + StartupIntroTiming.expansionDuration)) }
            catch { return }
            isFinished = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { isFinished = true }
        }
        .task(id: homeReady) {
            guard !homeReady else { return }
            do { try await Task.sleep(for: .seconds(reduceMotion ? 0.5 : 1.5)) }
            catch { return }
            showsProgress = true
        }
    }
}

/// A transparent opening reveals the real home surface, including its configured background.
private struct StartupIris: UIViewRepresentable {
    let startedAt: CFTimeInterval?
    let opensAt: CFTimeInterval?

    func makeUIView(context: Context) -> StartupIrisView { StartupIrisView() }

    func updateUIView(_ view: StartupIrisView, context: Context) {
        view.style = context.environment.colorScheme == .dark ? .dark : .light
        if view.startedAt != startedAt || view.opensAt != opensAt {
            view.startedAt = startedAt
            view.opensAt = opensAt
            view.setNeedsLayout()
        }
    }
}

final class StartupIrisView: UIView {
    private let surface = CAShapeLayer()
    private let guide = CAShapeLayer()
    private let ring = CAShapeLayer()
    var startedAt: CFTimeInterval?
    var opensAt: CFTimeInterval?
    private let radius: CGFloat = 36
    var style: UIUserInterfaceStyle = .unspecified {
        didSet {
            guard style != oldValue else { return }
            let sceneStyle = window?.windowScene?.traitCollection.userInterfaceStyle ?? .unspecified
            updateColors(from: window != nil && oldValue != .unspecified ? oldValue : sceneStyle)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        surface.fillRule = .evenOdd
        layer.addSublayer(surface)
        for stroke in [guide, ring] {
            stroke.fillColor = nil
            stroke.lineCap = .round
            stroke.lineWidth = 2 * radius * AppBrand.ringStrokeFraction
            layer.addSublayer(stroke)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The system launch storyboard uses the scene style even when the app has its own override.
        if let scene = window?.windowScene {
            updateColors(from: scene.traitCollection.userInterfaceStyle)
        }
    }

    private func updateColors(from previous: UIUserInterfaceStyle) {
        guard style != .unspecified else { return }
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(AppBrand.paper) : UIColor(AppBrand.ink) }
        let traits = UITraitCollection(userInterfaceStyle: style)
        let previousTraits = UITraitCollection(userInterfaceStyle: previous)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (shape, key, color) in [(surface, "fillColor", UIColor.systemBackground),
                                    (guide, "strokeColor", ink.withAlphaComponent(0.16)),
                                    (ring, "strokeColor", ink)] {
            let target = color.resolvedColor(with: traits).cgColor
            if previous != .unspecified && previous != style && !UIAccessibility.isReduceMotionEnabled {
                let fade = CABasicAnimation(keyPath: key)
                let inFlightColor = shape.animation(forKey: key) == nil ? nil : shape.presentation()?.value(forKey: key)
                fade.fromValue = inFlightColor ?? color.resolvedColor(with: previousTraits).cgColor
                fade.toValue = target
                fade.duration = 0.18
                shape.add(fade, forKey: key)
            }
            shape.setValue(target, forKey: key)
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bounds.isEmpty else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let corner = hypot(bounds.width, bounds.height) / 2 + 1
        func circle(_ radius: CGFloat) -> CGPath {
            UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2,
                         endAngle: 3 * .pi / 2, clockwise: true).cgPath
        }
        func backdrop(opening radius: CGFloat) -> CGPath {
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: 2 * radius, height: 2 * radius)))
            return path.cgPath
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // A subpixel opening keeps path topology stable. The round cap on the short arc draws the launch dot.
        let closed = backdrop(opening: 0.001)
        let outline = circle(radius - ring.lineWidth / 2)
        let dot: CGFloat = 0.0001
        surface.path = closed
        guide.path = outline
        ring.path = outline
        ring.strokeEnd = dot
        guard let startedAt else { return }

        func animate(_ shape: CAShapeLayer, _ key: String, from: Any, to: Any,
                     at start: CFTimeInterval, duration: TimeInterval) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = shape.convertTime(start, from: nil)
            animation.duration = duration
            animation.fillMode = .backwards
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1)
            shape.setValue(to, forKey: key)
            shape.add(animation, forKey: key)
        }
        animate(ring, "strokeEnd", from: dot, to: 1, at: startedAt, duration: StartupIntroTiming.traceDuration)
        animate(guide, "opacity", from: 1, to: 0, at: startedAt, duration: StartupIntroTiming.traceDuration)
        guard let opensAt else { return }
        let duration = StartupIntroTiming.expansionDuration
        animate(surface, "path", from: closed, to: backdrop(opening: corner), at: opensAt, duration: duration)
        animate(ring, "path", from: outline, to: circle(corner + ring.lineWidth / 2), at: opensAt, duration: duration)
        animate(ring, "opacity", from: 1, to: 0, at: opensAt, duration: duration)
    }
}
