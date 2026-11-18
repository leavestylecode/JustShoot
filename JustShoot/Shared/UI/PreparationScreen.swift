import SwiftUI

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
