import SwiftUI
import UIKit

// The raw values also restore scenes saved by the original integer-based TabView.
enum MainTab: Int, CaseIterable {
    case films = 0, photos = 1, library = 2, settings = 3

    var title: LocalizedStringResource {
        switch self {
        case .films: "Films"
        case .photos: "Photos"
        case .library: "Film Vault"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .films: "camera.aperture"
        case .photos: "photo.stack"
        case .library: "books.vertical"
        case .settings: "gearshape"
        }
    }

    var capsuleSymbol: String { self == .films ? symbol : symbol + ".fill" }
}

extension EnvironmentValues {
    @Entry var capsuleTabSelection: Binding<MainTab>? = nil
}

extension View {
    func mainTabItem(_ tab: MainTab) -> some View {
        tabItem { Image(systemName: tab.symbol).accessibilityLabel(Text(tab.title)) }
            .tag(tab)
    }

    func mainTabRoot(_ tab: MainTab, isHidden: Bool = false) -> some View {
        modifier(MainTabRoot(tab: tab, isHidden: isHidden))
    }
}

private struct MainTabRoot: ViewModifier {
    let tab: MainTab
    let isHidden: Bool
    @Environment(\.capsuleTabSelection) private var selection

    func body(content: Content) -> some View {
        if let selection {
            // Install inside the root of each stack so pushes and interactive pops carry
            // the bar with the page. A library opened in a sheet has no tab bar of its own.
            GeometryReader { geometry in
                content
                    .environment(\.capsuleTabSelection, nil)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !isHidden {
                            let fitsBelowSafeArea = UIDevice.current.userInterfaceIdiom == .phone
                                && geometry.safeAreaInsets.bottom >= 20
                            CapsuleTabBar(selection: selection)
                                .frame(maxWidth: 414)
                                .padding(.horizontal, 20)
                                .padding(.top, 6)
                                .padding(.bottom, fitsBelowSafeArea ? -10 : 2)
                        }
                    }
            }
            .toolbar(.hidden, for: .tabBar)
        } else if tab == .photos {
            content.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
        } else {
            content
        }
    }
}

private struct CapsuleTabBar: View {
    private static let itemInset: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator
    @Binding var selection: MainTab

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    Image(systemName: tab.capsuleSymbol)
                        .font(.system(size: 24))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(.primary.opacity(colorScheme == .dark ? 0.18 : 0.09))
                                    .padding(.horizontal, -5)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: selection)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            CapsuleTabItems(selection: $selection)
        }
        .frame(height: 52)
        .padding(.horizontal, Self.itemInset)
        .frame(height: 60)
        .legacyGlassSurface(Capsule(), material: .bar)
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
    }
}

private struct CapsuleTabItems: UIViewRepresentable {
    @Binding var selection: MainTab

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.accessibilityIdentifier = "main.tabs"
        bar.itemPositioning = .fill
        // Match the four equal slots even in regular-width iPad windows.
        bar.traitOverrides.horizontalSizeClass = .compact
        bar.items = MainTab.allCases.map { tab in
            // UIKit handles touches and VoiceOver. The capsule centers the visible
            // symbols itself because UIKit's stacked layout reserves caption space.
            let item = UITabBarItem(title: nil, image: nil, tag: tab.rawValue)
            item.largeContentSizeImage = UIImage(systemName: tab.capsuleSymbol)
            item.accessibilityLabel = String(localized: tab.title)
            return item
        }
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.selection = $selection
        if bar.selectedItem?.tag != selection.rawValue {
            bar.selectedItem = bar.items?.first { $0.tag == selection.rawValue }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject, UITabBarDelegate {
        var selection: Binding<MainTab>

        init(selection: Binding<MainTab>) { self.selection = selection }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            guard let tab = MainTab(rawValue: item.tag), selection.wrappedValue != tab else { return }
            selection.wrappedValue = tab
        }
    }
}
