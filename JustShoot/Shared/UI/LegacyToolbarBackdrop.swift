import SwiftUI

extension View {
    /// System bars render above the page. Paint only their backgrounds here so
    /// UIKit retains the title, buttons, navigation history and hit targets.
    @ViewBuilder
    func legacySoftToolbarEdges(_ bars: VerticalEdge.Set = .top) -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
                .overlay(alignment: .top) {
                    if bars.contains(.top) { LegacyToolbarBackdrop.systemEdge(.top) }
                }
                .overlay(alignment: .bottom) {
                    if bars.contains(.bottom) { LegacyToolbarBackdrop.systemEdge(.bottom) }
                }
        }
    }

    /// A custom toolbar already occupies its own inset. Fade from the back of
    /// that bar into the content without adding padding or changing its height.
    @ViewBuilder
    func legacySoftBarBackground(_ edge: VerticalEdge) -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            background {
                LegacyToolbarBackdrop(edge: edge)
                    .padding(edge == .top ? .bottom : .top, -LegacyToolbarBackdrop.fadeLength)
            }
        }
    }
}

private struct LegacyToolbarBackdrop: View {
    static let fadeLength: CGFloat = 16
    let edge: VerticalEdge
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func systemEdge(_ edge: VerticalEdge) -> some View {
        // The strip sits at the content boundary. Its flexible background also
        // fills the adjacent bar and status/home-indicator safe area.
        Color.clear
            .frame(height: fadeLength)
            .background { Self(edge: edge) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    var body: some View {
        Rectangle()
            .fill(reduceTransparency ? AnyShapeStyle(Color(uiColor: .systemBackground)) : AnyShapeStyle(.regularMaterial))
            .mask {
                VStack(spacing: 0) {
                    if edge == .bottom { fade }
                    Rectangle()
                    if edge == .top { fade }
                }
            }
            .ignoresSafeArea(.container, edges: edge == .top ? .top : .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var fade: some View {
        LinearGradient(colors: [.black, .clear],
                       startPoint: edge == .top ? .top : .bottom,
                       endPoint: edge == .top ? .bottom : .top)
            .frame(height: Self.fadeLength)
    }
}
