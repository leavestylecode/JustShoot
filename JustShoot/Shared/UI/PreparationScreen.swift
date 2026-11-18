import SwiftUI

struct AppStartupLoadingScreen: View {
    var body: some View {
        // Match the launch storyboard's lockup. Progress sits below it without shifting it.
        VStack(spacing: 16) {
            AppBrandMark()
                .frame(width: 64, height: 64)
            Text(verbatim: AppBrand.displayName)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(height: 30)
        }
        .overlay(alignment: .bottom) {
            ProgressView()
                .tint(.white)
                .offset(y: 40)
                .accessibilityLabel("Preparing your library…")
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("preparation_screen")
    }
}

struct PreparationErrorScreen: View {
    let title: LocalizedStringKey
    var message: String? = nil
    var actionTitle: LocalizedStringKey = "Try Again"
    let onAction: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 48, weight: .light))
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)

                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button(actionTitle, action: onAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .padding(.top, 6)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("preparation_screen")
    }
}
