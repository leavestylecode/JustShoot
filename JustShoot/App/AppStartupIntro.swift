import SwiftUI

enum StartupIntroTiming {
    static let traceDuration: TimeInterval = 0.52
    static let holdDuration: TimeInterval = 0.04
    static let revealDuration: TimeInterval = 0.66

    static func revealStart(tracingFrom start: CFTimeInterval, homeReadyAt ready: CFTimeInterval) -> CFTimeInterval {
        max(start + traceDuration + holdDuration, ready)
    }
}

struct AppStartupIntro: View {
    let homeReady: Bool
    @Binding var isFinished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: CFTimeInterval?
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            Color.clear
            if !reduceMotion && !isFinished {
                StartupMark(startedAt: startedAt, homeReady: homeReady) { isFinished = true }
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

/// The ring and diaphragm run on the compositor while the home view lays out underneath.
private struct StartupMark: UIViewRepresentable {
    let startedAt: CFTimeInterval?
    let homeReady: Bool
    let onFinished: () -> Void

    func makeUIView(context: Context) -> StartupMarkView { StartupMarkView() }

    func updateUIView(_ view: StartupMarkView, context: Context) {
        view.style = context.environment.colorScheme == .dark ? .dark : .light
        view.onFinished = onFinished
        if view.startedAt != startedAt || view.homeReady != homeReady {
            view.startedAt = startedAt
            view.homeReady = homeReady
            view.setNeedsLayout()
        }
    }
}

final class StartupMarkView: UIView, CAAnimationDelegate {
    private let surface = CALayer()
    private let aperture = CALayer()
    private let blades = (0..<StartupAperture.bladeCount).map { _ in CAShapeLayer() }
    private let finishes = (0..<StartupAperture.bladeCount).map { _ in CAGradientLayer() }
    private let rims = (0..<StartupAperture.bladeCount).map { _ in CAShapeLayer() }
    private let guide = CAShapeLayer()
    private let ring = CAShapeLayer()
    var startedAt: CFTimeInterval?
    var revealAt: CFTimeInterval?
    var homeReady = false
    var onFinished: (() -> Void)?
    private var displayLink: CADisplayLink?
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
        layer.addSublayer(surface)
        aperture.opacity = 0
        aperture.masksToBounds = true
        layer.addSublayer(aperture)
        for index in blades.indices {
            let finish = finishes[index]
            let angle = CGFloat(index) * .pi / 3 - .pi / 4
            let dx = 0.5 * cos(angle)
            let dy = 0.5 * sin(angle)
            finish.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
            finish.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
            finish.locations = [0, 0.41, 0.66, 1]
            finish.mask = blades[index]
            aperture.addSublayer(finish)
        }
        for rim in rims {
            rim.fillColor = nil
            rim.lineWidth = 0.7
            aperture.addSublayer(rim)
        }
        let diameter: CGFloat = 72
        let lineWidth = diameter * AppBrand.ringStrokeFraction
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let outline = UIBezierPath(arcCenter: center, radius: (diameter - lineWidth) / 2,
                                   startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true).cgPath
        for stroke in [guide, ring] {
            stroke.bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
            stroke.path = outline
            stroke.fillColor = nil
            stroke.lineCap = .round
            stroke.lineWidth = lineWidth
            layer.addSublayer(stroke)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The system launch storyboard uses the scene style even when the app has its own override.
        if let scene = window?.windowScene {
            updateColors(from: scene.traitCollection.userInterfaceStyle)
            setNeedsLayout()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func beginReveal(_ link: CADisplayLink) {
        let nextFrame = link.targetTimestamp
        link.invalidate()
        displayLink = nil
        guard window != nil, homeReady, let startedAt else { return }
        revealAt = StartupIntroTiming.revealStart(tracingFrom: startedAt, homeReadyAt: nextFrame)
        setNeedsLayout()
        layoutIfNeeded()
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        Task { @MainActor [weak self] in self?.onFinished?() }
    }

    private func updateColors(from previous: UIUserInterfaceStyle) {
        guard style != .unspecified else { return }
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(AppBrand.paper) : UIColor(AppBrand.ink) }
        let traits = UITraitCollection(userInterfaceStyle: style)
        let previousTraits = UITraitCollection(userInterfaceStyle: previous)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func apply(_ color: UIColor, to shape: CALayer, key: String) {
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
        apply(.systemBackground, to: surface, key: "backgroundColor")
        apply(ink.withAlphaComponent(0.16), to: guide, key: "strokeColor")
        apply(ink, to: ring, key: "strokeColor")
        for index in blades.indices {
            // A single raking light picks out the lips of the six satin-finished blades.
            let light = (1 + cos(CGFloat(index) * .pi / 3 - 0.5)) / 2
            let dark = style == .dark
            let base = dark ? 0.09 + 0.10 * light : 0.79 + 0.08 * light
            let highlights: [CGFloat] = dark ? [0, 0.085, 0.018, -0.025] : [0.025, 0.125, 0.045, -0.015]
            finishes[index].colors = highlights.map { offset in
                let v = base + offset
                return UIColor(red: dark ? v * 0.98 : v * 1.01, green: v,
                               blue: dark ? v * 1.07 : v * 0.97, alpha: 1).cgColor
            }
            apply(.white.withAlphaComponent(0.16 + 0.32 * light), to: rims[index], key: "strokeColor")
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bounds.isEmpty else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        surface.frame = bounds
        aperture.frame = bounds
        guide.position = center
        ring.position = center
        // A round cap on this short arc matches the launch storyboard’s starting dot.
        let dot: CGFloat = 0.0001
        ring.strokeEnd = dot
        guard let startedAt else { return }

        func animate(_ shape: CALayer, _ key: String, from: Any, to: Any,
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
        guard let revealAt else {
            // Let the first home layout commit before starting the mechanical movement.
            if homeReady, window != nil, displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(beginReveal(_:)))
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
            return
        }
        let duration = StartupIntroTiming.revealDuration
        let poses = StartupAperture.poses(in: bounds.size)
        let keyTimes = poses.map { NSNumber(value: $0.time) }
        func animatePath(_ shape: CAShapeLayer, through paths: [CGPath]) {
            let motion = CAKeyframeAnimation(keyPath: "path")
            motion.values = paths
            motion.keyTimes = keyTimes
            motion.duration = duration
            motion.beginTime = shape.convertTime(revealAt, from: nil)
            motion.fillMode = .backwards
            if shape === blades[0], onFinished != nil { motion.delegate = self }
            shape.path = paths.last
            shape.add(motion, forKey: "path")
        }
        for index in blades.indices {
            finishes[index].frame = aperture.bounds
            blades[index].frame = finishes[index].bounds
            let outlines = poses.map { $0.outline(for: index, in: aperture.bounds.size) }
            animatePath(blades[index], through: outlines.map(\.face))
            animatePath(rims[index], through: outlines.map(\.rim))
        }
        animate(aperture, "opacity", from: 0, to: 1, at: revealAt, duration: 0.13)
        animate(ring, "lineWidth", from: guide.lineWidth, to: 1.5, at: revealAt, duration: 0.14)
        animate(ring, "opacity", from: 1, to: 0, at: revealAt + 0.035, duration: 0.13)
        // Exchange surfaces while the blades meet. The rest of the reveal is a real opening onto home.
        animate(surface, "opacity", from: 1, to: 0, at: revealAt + duration * 0.23, duration: duration * 0.05)
    }
}
