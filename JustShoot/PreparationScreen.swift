import SwiftUI

/// A shared entry screen for launch and camera preparation. Work continues underneath;
/// callers decide readiness from completed work instead of a presentation delay.
struct PreparationScreen: View {
    let title: LocalizedStringKey
    var message: String? = nil
    var isLoading = true
    var actionTitle: LocalizedStringKey = "Try Again"
    var onAction: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: isLoading ? "camera.aperture" : "exclamationmark.circle")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)

                    Text("JustShoot")
                        .font(.system(size: 24, weight: .semibold))
                        .padding(.top, 20)

                    VStack(spacing: 14) {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                                .accessibilityLabel(title)
                        }
                        if !isLoading {
                            Text(title)
                                .font(.subheadline.weight(.medium))
                                .multilineTextAlignment(.center)
                                .accessibilityAddTraits(.isHeader)
                        }

                        if let message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        if let onAction {
                            Button(actionTitle, action: onAction)
                                .buttonStyle(.borderedProminent)
                                .tint(.white)
                                .foregroundStyle(.black)
                        }
                        if let onClose {
                            Button("Back", action: onClose)
                                .buttonStyle(.bordered)
                                .tint(.white)
                        }
                    }
                    .padding(.top, 30)
                    .frame(maxWidth: 320)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("preparation_screen")
    }
}
