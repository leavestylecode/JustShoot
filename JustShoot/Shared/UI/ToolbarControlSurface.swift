import SwiftUI
import UIKit

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

enum NavigationBackMetrics {
    static let diameter: CGFloat = 44
    static let compactDiameter: CGFloat = 32
    static let glyph = backGlyph(size: 21)
    static let compactGlyph = backGlyph(size: 16)

    // Freeze the symbol's optical bounds once. SwiftUI toolbar labels otherwise
    // rescale symbols independently of UIKit's native Back item.
    private static func backGlyph(size: CGFloat) -> UIImage {
        let source = UIImage(systemName: "chevron.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold, scale: .medium))!
        return UIGraphicsImageRenderer(size: source.size).image { _ in source.draw(at: .zero) }
            .withRenderingMode(.alwaysTemplate)
    }
}

struct NavigationBackLabel: View {
    var inToolbar = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let compact = inToolbar && verticalSizeClass == .compact
        let glyph = compact ? NavigationBackMetrics.compactGlyph : NavigationBackMetrics.glyph
        let symbol = Image(uiImage: glyph)
            .renderingMode(.template)
            .flipsForRightToLeftLayoutDirection(true)
        if inToolbar {
            symbol.toolbarControlSurface()
        } else {
            symbol
                .frame(width: NavigationBackMetrics.diameter, height: NavigationBackMetrics.diameter)
                .cameraControlSurface()
                .contentShape(.circle)
        }
    }
}

private struct LegacyToolbarControlSurface: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let text: Bool

    func body(content: Content) -> some View {
        let height = verticalSizeClass == .compact ? NavigationBackMetrics.compactDiameter : NavigationBackMetrics.diameter
        content
            .padding(.horizontal, text ? 14 : 0)
            .frame(minWidth: text ? 44 : height)
            .frame(height: height)
            .legacyGlassSurface(Capsule(), material: .regular)
            .frame(minWidth: 44)
            .contentShape(.rect)
    }
}
