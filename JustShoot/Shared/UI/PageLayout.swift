import SwiftUI

/// Shared limits for browsing in either orientation. All sizes use the available container,
/// so a larger display does not stretch forms or turn covers into tiny icons.
enum PageLayout {
    static let browseWidth: CGFloat = 1120
    static let readingWidth: CGFloat = 680
    static let cameraControlsWidth: CGFloat = 640
    static let detailCoverWidth: CGFloat = 400
    static let curveEditorWidth: CGFloat = 420

    static func homeColumns(width: CGFloat, isRegular: Bool, scale: CGFloat = 1) -> Int {
        let contentWidth = (isRegular ? min(width, browseWidth) : width) - (isRegular ? 48 : 28)
        return gridColumns(width: contentWidth, minimum: (isRegular ? 176 : 100) * scale,
            spacing: 14, maximum: isRegular ? 6 : 4)
    }

    static func usesLandscapeColumns(in size: CGSize, isRegular: Bool) -> Bool {
        isRegular && size.width >= 900 && size.width > size.height
    }

    static func gridColumns(width: CGFloat, minimum: CGFloat, spacing: CGFloat, maximum: Int) -> Int {
        guard width.isFinite, minimum.isFinite, width > 0, minimum > 0 else { return 1 }
        return max(1, min(maximum, Int((width + spacing) / (minimum + spacing))))
    }
}

private struct PageContentWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let regularWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: sizeClass == .regular ? regularWidth : .infinity)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func pageContentWidth(_ regularWidth: CGFloat = PageLayout.readingWidth) -> some View {
        modifier(PageContentWidth(regularWidth: regularWidth))
    }
}
