import SwiftUI

extension View {
    /// Apply to an action's label. The toolbar supplies the surface on iOS 26 and later.
    @ViewBuilder
    func toolbarControlSurface(text: Bool = false, inToolbar: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else if inToolbar {
            modifier(LegacyToolbarControlSurface(text: text))
        } else {
            self
        }
    }

    @ViewBuilder
    func floatingBottomToolbar() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            toolbarBackground(.hidden, for: .bottomBar)
        }
    }
}

private struct LegacyToolbarControlSurface: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let text: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, text ? 14 : 0)
            .frame(minWidth: 44)
            .frame(height: verticalSizeClass == .compact ? 32 : 44)
            .legacyGlassSurface(Capsule(), material: .regularMaterial)
            .contentShape(.capsule)
    }
}
