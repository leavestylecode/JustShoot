import SwiftUI

private enum ReviewSheetPalette {
    static let background = Color(red: 0.008, green: 0.025, blue: 0.075)
    static let cobalt = Color(red: 0.10, green: 0.42, blue: 0.98)
    static let iceBlue = Color(red: 0.52, green: 0.76, blue: 1.00)
    static let cyan = Color(red: 0.06, green: 0.78, blue: 0.84)
    static let indigo = Color(red: 0.22, green: 0.28, blue: 0.82)
    static let violet = Color(red: 0.56, green: 0.38, blue: 0.94)
    static let starlight = Color(red: 0.88, green: 0.94, blue: 1.00)

    static let actionGradient = LinearGradient(
        colors: [cobalt, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Port of DeepMusic’s manual review sheet using the camera app’s brand and review URL.
struct AnimatedReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let reviewURL: URL?
    @State private var showsRatingUnavailable = false

    var body: some View {
        ZStack {
            ReviewSheetPalette.background
                .ignoresSafeArea()

            ReviewLightBurst()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.52),
                    .init(color: ReviewSheetPalette.background.opacity(0.22), location: 0.70),
                    .init(color: ReviewSheetPalette.background.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 12) {
                    Text("Enjoying \(AppBrand.displayName)?")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Your feedback helps us make \(AppBrand.displayName) even better.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.76))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: writeReview) {
                        Text("review_sheet_button")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ReviewSheetPalette.actionGradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 220)
                    .padding(.top, 20)
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("review_sheet_close"))
            .padding(12)
        }
        .presentationDetents(UIDevice.current.userInterfaceIdiom == .pad ? [.large] : [.height(450)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .environment(\.colorScheme, .dark)
        .alert("App Store Rating Unavailable", isPresented: $showsRatingUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can rate the app when its App Store page is available.")
        }
    }

    private func writeReview() {
        guard let reviewURL else {
            showsRatingUnavailable = true
            return
        }
        openURL(reviewURL) { accepted in
            if accepted { dismiss() }
            else { showsRatingUnavailable = true }
        }
    }
}

private struct ReviewLightBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Ray {
        let angle: Double
        let angularWidth: Double
        let color: Color
        let intensity: Double
    }

    private let rays: [Ray] = [
        Ray(angle: -145, angularWidth: 22, color: ReviewSheetPalette.cobalt, intensity: 0.96),
        Ray(angle: -110, angularWidth: 9, color: ReviewSheetPalette.cyan, intensity: 0.90),
        Ray(angle: 175, angularWidth: 9.5, color: ReviewSheetPalette.iceBlue, intensity: 0.76),
        Ray(angle: 5, angularWidth: 10.5, color: ReviewSheetPalette.indigo, intensity: 0.90),
        Ray(angle: 35, angularWidth: 22, color: ReviewSheetPalette.violet, intensity: 0.92),
        Ray(angle: 63, angularWidth: 9, color: ReviewSheetPalette.starlight, intensity: 0.80)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            GeometryReader { geometry in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    Canvas(
                        opaque: false,
                        colorMode: .linear,
                        rendersAsynchronously: true
                    ) { context, size in
                        drawRays(in: &context, size: size, time: time)
                    }

                    appIcon
                        .scaleEffect(iconScale(at: time))
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.30)

                    sparkleGroup(
                        color: ReviewSheetPalette.starlight,
                        largeSize: 40,
                        smallSize: 13,
                        smallOffset: CGSize(width: 22, height: -15)
                    )
                    .position(x: geometry.size.width * 0.25, y: geometry.size.height * 0.15)

                    sparkleGroup(
                        color: ReviewSheetPalette.cyan,
                        largeSize: 32,
                        smallSize: 11,
                        smallOffset: CGSize(width: -17, height: 14)
                    )
                    .position(x: geometry.size.width * 0.72, y: geometry.size.height * 0.44)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var appIcon: some View {
        AppBrandMark()
            .frame(width: 70, height: 70)
            .frame(width: 104, height: 104)
            .background(.black, in: .rect(cornerRadius: 24))
            .shadow(color: ReviewSheetPalette.iceBlue.opacity(0.35), radius: 18)
            .shadow(color: .black.opacity(0.55), radius: 9, y: 5)
    }

    private func iconScale(at time: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let period = 2.4
        let phase = time.truncatingRemainder(dividingBy: period) / period * 2 * Double.pi
        return 1 + 0.045 * sin(phase)
    }

    private func sparkleGroup(
        color: Color,
        largeSize: CGFloat,
        smallSize: CGFloat,
        smallOffset: CGSize
    ) -> some View {
        ZStack {
            Image(systemName: "sparkle")
                .font(.system(size: largeSize, weight: .black))

            Image(systemName: "sparkle")
                .font(.system(size: smallSize, weight: .black))
                .offset(smallOffset)
        }
        .foregroundStyle(color)
    }

    private func drawRays(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let origin = CGPoint(x: size.width / 2, y: size.height * 0.30)
        let outerRadius = hypot(size.width, size.height)
        let rotationPeriod = 6.0
        let rotationPhase = time
            .truncatingRemainder(dividingBy: rotationPeriod)
            / rotationPeriod
            * 2.0
            * .pi
        let rotation = (-50.0 * (0.5 + 0.5 * cos(rotationPhase))) * .pi / 180
        let brightnessPeriod = 5.5
        let brightnessPhase = time
            .truncatingRemainder(dividingBy: brightnessPeriod)
            / brightnessPeriod
            * 2.0
            * .pi
        let brightness = 0.5 + 0.5 * sin(brightnessPhase)
        let opacity = 0.08 + 0.80 * pow(brightness, 1.45)

        for ray in rays {
            let angle = ray.angle * .pi / 180 + rotation
            let halfWidth = ray.angularWidth * .pi / 360
            let leadingDirection = CGVector(
                dx: cos(angle - halfWidth),
                dy: sin(angle - halfWidth)
            )
            let trailingDirection = CGVector(
                dx: cos(angle + halfWidth),
                dy: sin(angle + halfWidth)
            )

            var path = Path()
            path.move(to: origin)
            path.addLine(to: CGPoint(
                x: origin.x + leadingDirection.dx * outerRadius,
                y: origin.y + leadingDirection.dy * outerRadius
            ))
            path.addLine(to: CGPoint(
                x: origin.x + trailingDirection.dx * outerRadius,
                y: origin.y + trailingDirection.dy * outerRadius
            ))
            path.closeSubpath()

            context.drawLayer { layer in
                layer.opacity = opacity * ray.intensity
                layer.fill(path, with: .color(ray.color))
            }
        }
    }
}
