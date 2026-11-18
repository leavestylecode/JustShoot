import SwiftUI

/// The trace closes before the iris opens.
struct StartupIntroFrame {
    static let duration: TimeInterval = 1.06
    static let ringRadius: CGFloat = 36
    static let strokeFraction: CGFloat = 1 / 7

    let trace: CGFloat
    let expansion: CGFloat

    init(elapsed: TimeInterval) {
        func eased(from start: TimeInterval, to end: TimeInterval) -> CGFloat {
            let t = min(max((elapsed - start) / (end - start), 0), 1)
            return t * t * (3 - 2 * t)
        }

        trace = eased(from: 0, to: 0.62)
        expansion = eased(from: 0.70, to: Self.duration)
    }

    func radii(in size: CGSize) -> (outer: CGFloat, inner: CGFloat) {
        let radius = Self.ringRadius
        let corner = max(radius, hypot(size.width, size.height) / 2 + 1)
        return (radius + (corner - radius) * expansion,
                radius * (1 - 2 * Self.strokeFraction) * (1 - expansion))
    }
}

struct StartupLetterBeat: Equatable {
    let lettersShown: Int
    let delay: Duration
    let intensity: Double

    static let sequence = [
        Self(lettersShown: 1, delay: .milliseconds(35), intensity: 0.82),
        Self(lettersShown: 2, delay: .milliseconds(230), intensity: 0.91),
        Self(lettersShown: 3, delay: .milliseconds(280), intensity: 1)
    ]

    @MainActor
    static func play(_ strike: (Self) -> Void) async throws {
        for beat in sequence {
            try await Task.sleep(for: beat.delay)
            try Task.checkCancellation()
            strike(beat)
        }
    }
}

struct AppStartupIntro: View {
    @Binding var isFinished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var elapsed: TimeInterval = 0
    @State private var irisOpened = false
    @State private var lastBeat: StartupLetterBeat?
    @State private var showsProgress = false

    private var settled: Bool { reduceMotion || isFinished }
    private var playsLetters: Bool { irisOpened && !settled }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                StartupIris(elapsed: settled ? StartupIntroFrame.duration : elapsed)
                StartupWordmark(
                    diameter: min(88, min(geometry.size.width, geometry.size.height) * 0.16),
                    lettersShown: lastBeat?.lettersShown ?? 0,
                    settled: settled
                )
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
        .accessibilityLabel(Text(verbatim: AppBrand.wordmark))
        .accessibilityValue(Text("Preparing your library…"))
        .accessibilityIdentifier("preparation_screen")
        .task(id: reduceMotion) {
            guard !isFinished else { return }
            if reduceMotion {
                isFinished = true
            } else {
                withAnimation(.linear(duration: StartupIntroFrame.duration)) {
                    elapsed = StartupIntroFrame.duration
                } completion: {
                    irisOpened = true
                }
            }
        }
        .task(id: playsLetters) {
            guard playsLetters else { return }
            do {
                try await StartupLetterBeat.play { lastBeat = $0 }
                try await Task.sleep(for: .milliseconds(570))
                isFinished = true
            } catch { return }
        }
        .sensoryFeedback(trigger: lastBeat) { _, beat in
            guard let beat, !settled, scenePhase == .active else { return nil }
            return .impact(weight: .heavy, intensity: beat.intensity)
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

private struct StartupIris: View, Animatable {
    nonisolated var elapsed: TimeInterval
    nonisolated var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    private let paper = Color(red: 0.957, green: 0.941, blue: 0.910)

    var body: some View {
        let frame = StartupIntroFrame(elapsed: elapsed)
        ZStack {
            Color.black
            Image(decorative: "LaunchRing")
                .resizable()
                .frame(width: 2 * StartupIntroFrame.ringRadius, height: 2 * StartupIntroFrame.ringRadius)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let (outer, inner) = frame.radii(in: size)
                if frame.trace < 1 {
                    var arc = Path()
                    arc.addArc(center: center, radius: (outer + inner) / 2, startAngle: .degrees(-90),
                               endAngle: .degrees(-90 + 360 * frame.trace), clockwise: false)
                    context.stroke(arc, with: .color(paper),
                                   style: StrokeStyle(lineWidth: outer - inner, lineCap: .round))
                } else {
                    func circle(_ radius: CGFloat) -> CGRect {
                        CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                    }
                    var iris = Path(ellipseIn: circle(outer))
                    if inner > 0 { iris.addEllipse(in: circle(inner)) }
                    context.fill(iris, with: .color(paper), style: FillStyle(eoFill: true))
                }
            }
        }
        .transaction { $0.animation = nil }
    }
}

private struct StartupWordmark: View {
    let diameter: CGFloat
    let lettersShown: Int
    let settled: Bool

    var body: some View {
        HStack(spacing: diameter * 0.10) {
            ForEach(0..<AppBrand.wordmark.count, id: \.self) { index in
                let arrived = index < lettersShown
                Circle()
                    .strokeBorder(lineWidth: diameter * StartupIntroFrame.strokeFraction)
                    .frame(width: diameter, height: diameter)
                    .keyframeAnimator(initialValue: 0.0, trigger: arrived) { ring, recoil in
                        ring.offset(y: settled ? 0 : diameter * 0.15 * recoil)
                    } keyframes: { _ in
                        MoveKeyframe(1)
                        CubicKeyframe(-0.62, duration: 0.055)
                        CubicKeyframe(0.29, duration: 0.055)
                        CubicKeyframe(-0.11, duration: 0.055)
                        CubicKeyframe(0, duration: 0.065)
                    }
                    .opacity(settled || arrived ? 1 : 0)
            }
        }
        .foregroundStyle(Color(red: 0.102, green: 0.094, blue: 0.086))
        .environment(\.layoutDirection, .leftToRight)
    }
}
