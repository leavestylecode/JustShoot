import SwiftUI

/// The trace closes before the iris opens. Core Animation interpolates between these frames.
struct StartupIntroFrame {
    static let duration: TimeInterval = 1.06
    static let ringRadius: CGFloat = 36
    static let sequence = [
        Self(time: 0, trace: 0, expansion: 0),
        Self(time: 0.62, trace: 1, expansion: 0),
        Self(time: 0.70, trace: 1, expansion: 0),
        Self(time: duration, trace: 1, expansion: 1)
    ]

    let time: TimeInterval
    let trace: CGFloat
    let expansion: CGFloat

    func radii(in size: CGSize) -> (outer: CGFloat, inner: CGFloat) {
        let radius = Self.ringRadius
        let corner = max(radius, hypot(size.width, size.height) / 2 + 1)
        return (radius + (corner - radius) * expansion,
                radius * (1 - 2 * AppBrand.ringStrokeFraction) * (1 - expansion))
    }
}

struct AppStartupIntro: View {
    @Binding var isFinished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: CFTimeInterval?
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            if reduceMotion || isFinished {
                AppBrand.paper
            } else {
                Color.black
                Image(decorative: "LaunchRing")
                    .resizable()
                    .frame(width: 2 * StartupIntroFrame.ringRadius, height: 2 * StartupIntroFrame.ringRadius)
                StartupIris(startedAt: startedAt)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if showsProgress {
                ProgressView()
                    .tint(.black.opacity(0.6))
                    .padding(.bottom, 28)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preparing your library…"))
        .accessibilityIdentifier("preparation_screen")
        .task(id: reduceMotion) {
            guard !isFinished else { return }
            if !reduceMotion {
                startedAt = CACurrentMediaTime()
                do { try await Task.sleep(for: .seconds(StartupIntroFrame.duration)) }
                catch { return }
            }
            isFinished = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { isFinished = true }
        }
        .task(id: isFinished) {
            guard isFinished else { return }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            showsProgress = true
        }
    }
}

/// A layer animation keeps drawing while SwiftUI lays out the home tabs underneath.
private struct StartupIris: UIViewRepresentable {
    let startedAt: CFTimeInterval?

    func makeUIView(context: Context) -> IrisView { IrisView() }

    func updateUIView(_ view: IrisView, context: Context) {
        if view.startedAt != startedAt {
            view.startedAt = startedAt
            view.setNeedsLayout()
        }
    }

    final class IrisView: UIView {
        var startedAt: CFTimeInterval?
        private let ring = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            ring.fillColor = nil
            ring.strokeColor = UIColor(AppBrand.paper).cgColor
            ring.lineCap = .round
            layer.addSublayer(ring)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let startedAt, !bounds.isEmpty else { return }
            let frames = StartupIntroFrame.sequence
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radii = frames.map { $0.radii(in: bounds.size) }
            let paths = radii.map { outer, inner in
                UIBezierPath(arcCenter: center, radius: (outer + inner) / 2,
                             startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true).cgPath
            }
            let widths = radii.map { $0.outer - $0.inner }
            let keyTimes = frames.map { NSNumber(value: $0.time / StartupIntroFrame.duration) }
            let ease = CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1)

            func track(_ property: String, _ values: [Any]) -> CAKeyframeAnimation {
                let animation = CAKeyframeAnimation(keyPath: property)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.duration = StartupIntroFrame.duration
                animation.timingFunctions = Array(repeating: ease, count: frames.count - 1)
                return animation
            }

            let group = CAAnimationGroup()
            group.animations = [track("strokeEnd", frames.map(\.trace)), track("path", paths), track("lineWidth", widths)]
            group.duration = StartupIntroFrame.duration
            group.beginTime = ring.convertTime(startedAt, from: nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.path = paths.last
            ring.lineWidth = widths.last ?? 0
            ring.add(group, forKey: "iris")
            CATransaction.commit()
        }
    }
}
