import SwiftUI
import UIKit

extension View {
    @ViewBuilder
    func matchingNavigationBackButton() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            background(LegacyNavigationBackButton())
        }
    }
}

/// UIKit owns the Back action, accessibility, edge swipe, and navigation history.
private struct LegacyNavigationBackButton: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.colorScheme = colorScheme
        controller.styleBackButton()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        private weak var previousItem: UINavigationItem?
        private weak var destination: UINavigationItem?
        private var originalButton: UIBarButtonItem?
        private var originalDisplayMode: UINavigationItem.BackButtonDisplayMode = .default
        private var styledScheme: ColorScheme?
        private var isVisible = false
        var colorScheme: ColorScheme = .light

        private typealias AppearanceKey = ReferenceWritableKeyPath<UINavigationItem, UINavigationBarAppearance?>
        private var appearances: [(key: AppearanceKey, original: UINavigationBarAppearance?, installed: UINavigationBarAppearance?)] = []

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            styleBackButton()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // iOS 17 can finish an animated push using the outgoing indicator.
            // Refresh the item once UIKit has made the destination current.
            styleBackButton(refreshAfterTransition: true)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            restore()
        }

        func restore() {
            if let previousItem {
                if previousItem.backBarButtonItem == nil { previousItem.backBarButtonItem = originalButton }
                if previousItem.backButtonDisplayMode == .minimal { previousItem.backButtonDisplayMode = originalDisplayMode }
            }
            restoreAppearances()
            previousItem = nil
            destination = nil
            originalButton = nil
            styledScheme = nil
        }

        private func restoreAppearances() {
            if let destination {
                for entry in appearances where destination[keyPath: entry.key] === entry.installed {
                    destination[keyPath: entry.key] = entry.original
                }
            }
            appearances.removeAll()
        }

        func styleBackButton(refreshAfterTransition: Bool = false) {
            guard isVisible, let navigationController else { return }
            var host = parent
            while let current = host, current.parent !== navigationController { host = current.parent }
            guard let host, let index = navigationController.viewControllers.firstIndex(of: host), index > 0 else { return }

            let source = navigationController.viewControllers[index - 1].navigationItem
            let item = host.navigationItem
            if previousItem !== source || destination !== item {
                restore()
                previousItem = source
                destination = item
                originalDisplayMode = source.backButtonDisplayMode
                originalButton = source.backBarButtonItem
                source.backButtonDisplayMode = .minimal
                source.backBarButtonItem = nil
            }
            let appearanceReplaced = appearances.contains { item[keyPath: $0.key] !== $0.installed }
            guard refreshAfterTransition || styledScheme != colorScheme || appearanceReplaced else { return }
            restoreAppearances()
            installIndicator(on: item, in: navigationController.navigationBar)
            styledScheme = colorScheme
        }

        private func installIndicator(on item: UINavigationItem, in bar: UINavigationBar) {
            let standard = item.standardAppearance ?? bar.standardAppearance
            let scrollEdge = item.scrollEdgeAppearance ?? bar.scrollEdgeAppearance ?? standard.copy()
            if item.scrollEdgeAppearance == nil, bar.scrollEdgeAppearance == nil {
                scrollEdge.configureWithTransparentBackground()
            }
            let compact = item.compactAppearance ?? bar.compactAppearance ?? standard
            let compactScrollEdge = item.compactScrollEdgeAppearance ?? bar.compactScrollEdgeAppearance ?? scrollEdge
            let regularImage = backImage(diameter: NavigationBackMetrics.diameter, glyph: NavigationBackMetrics.glyph)
            let compactImage = backImage(diameter: NavigationBackMetrics.compactDiameter, glyph: NavigationBackMetrics.compactGlyph)
            let variants: [(AppearanceKey, UINavigationBarAppearance, UIImage)] = [
                (\.standardAppearance, standard, regularImage), (\.scrollEdgeAppearance, scrollEdge, regularImage),
                (\.compactAppearance, compact, compactImage), (\.compactScrollEdgeAppearance, compactScrollEdge, compactImage)
            ]
            for (key, base, image) in variants {
                let original = item[keyPath: key]
                let copy = base.copy()
                copy.setBackIndicatorImage(image, transitionMaskImage: image)
                item[keyPath: key] = copy
                appearances.append((key, original, item[keyPath: key]))
            }
        }

        private func backImage(diameter: CGFloat, glyph: UIImage) -> UIImage {
            let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
            let foreground = UIColor.label.resolvedColor(with: traits)
            let fill = (colorScheme == .dark ? UIColor.secondarySystemBackground : .systemBackground)
                .resolvedColor(with: traits)
            let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            let symbol = glyph.withTintColor(foreground, renderingMode: .alwaysOriginal)
            // UIKit sizes a Back indicator by its alignment rect. Keep the full-width
            // hit target while fitting the visible circle into the bar's chevron slot.
            let verticalInset = diameter / 4
            return UIGraphicsImageRenderer(size: bounds.size).image { _ in
                let outline = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
                fill.withAlphaComponent(0.94).setFill()
                outline.fill()
                foreground.withAlphaComponent(0.14).setStroke()
                outline.lineWidth = 0.5
                outline.stroke()
                symbol.draw(at: CGPoint(x: (diameter - symbol.size.width) / 2,
                                        y: (diameter - symbol.size.height) / 2))
            }
            .withRenderingMode(.alwaysOriginal)
            .withAlignmentRectInsets(UIEdgeInsets(top: verticalInset, left: -4, bottom: verticalInset, right: 4))
            .imageFlippedForRightToLeftLayoutDirection()
        }
    }
}
