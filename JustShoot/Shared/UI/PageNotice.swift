import SwiftUI

/// A compact status for a whole page. Explanations are reserved for actionable details.
struct PageNotice: View {
    struct Action {
        let title: LocalizedStringKey
        var icon = "arrow.forward"
        let perform: () -> Void
    }

    let title: LocalizedStringKey
    let systemImage: String
    var message: String?
    var action: Action?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.bottom, 16)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.medium))
                    .accessibilityAddTraits(.isHeader)

                if let message {
                    Text(verbatim: message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let action {
                Button(action: action.perform) {
                    HStack(spacing: 6) {
                        Text(action.title)
                        Image(systemName: action.icon)
                            .font(.caption.weight(.medium))
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
