import SwiftUI

struct PreparationErrorScreen: View {
    let title: LocalizedStringKey
    let systemImage: String
    var message: String? = nil
    var actionTitle: LocalizedStringKey = "Retry"
    var actionIcon = "arrow.clockwise"
    let onAction: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                PageNotice(title: title, systemImage: systemImage, message: message,
                    action: .init(title: actionTitle, icon: actionIcon, perform: onAction))
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .foregroundStyle(.primary)
        .accessibilityIdentifier("preparation_screen")
    }
}
