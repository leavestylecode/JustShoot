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

/// Styles UIKit's own Back item so the swipe gesture and press-and-hold history still work.
private struct LegacyNavigationBackButton: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.colorScheme = colorScheme
        controller.styleBackButton()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreBackButtonTitle()
    }

    final class Controller: UIViewController {
        private weak var styledItem: UINavigationItem?
        private var styledScheme: ColorScheme?
        private weak var previousItem: UINavigationItem?
        private var originalDisplayMode: UINavigationItem.BackButtonDisplayMode = .default
        private var isVisible = false
        var colorScheme: ColorScheme = .light

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            styleBackButton()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            restoreBackButtonTitle()
        }

        func restoreBackButtonTitle() {
            if previousItem?.backButtonDisplayMode == .minimal {
                previousItem?.backButtonDisplayMode = originalDisplayMode
            }
            previousItem = nil
        }

        func styleBackButton() {
            guard isVisible, let navigationController else { return }
            // SwiftUI embeds this controller inside the hosting controller that owns the item.
            var host = parent
            while let current = host, current.parent !== navigationController {
                host = current.parent
            }
            guard let host, let index = navigationController.viewControllers.firstIndex(of: host), index > 0 else { return }

            let backItem = navigationController.viewControllers[index - 1].navigationItem
            if previousItem !== backItem {
                restoreBackButtonTitle()
                originalDisplayMode = backItem.backButtonDisplayMode
                previousItem = backItem
                backItem.backButtonDisplayMode = .minimal
            }

            let item = host.navigationItem
            guard styledItem !== item || styledScheme != colorScheme else { return }
            let bar = navigationController.navigationBar
            let standard = item.standardAppearance ?? bar.standardAppearance
            let scrollEdge = item.scrollEdgeAppearance ?? bar.scrollEdgeAppearance ?? standard.copy()
            let compact = item.compactAppearance ?? bar.compactAppearance ?? standard
            let compactScrollEdge = item.compactScrollEdgeAppearance ?? bar.compactScrollEdgeAppearance ?? scrollEdge
            if item.scrollEdgeAppearance == nil, bar.scrollEdgeAppearance == nil {
                scrollEdge.configureWithTransparentBackground()
            }

            let regularImage = backIndicator(diameter: 44, symbolSize: 17)
            let compactImage = backIndicator(diameter: 32, symbolSize: 15)
            item.standardAppearance = Self.appearance(standard, image: regularImage)
            item.scrollEdgeAppearance = Self.appearance(scrollEdge, image: regularImage)
            item.compactAppearance = Self.appearance(compact, image: compactImage)
            item.compactScrollEdgeAppearance = Self.appearance(compactScrollEdge, image: compactImage)
            styledItem = item
            styledScheme = colorScheme
        }

        private func backIndicator(diameter: CGFloat, symbolSize: CGFloat) -> UIImage {
            let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
            let foreground = UIColor.label.resolvedColor(with: traits)
            let fill = UIColor.tertiarySystemFill.resolvedColor(with: traits)
            let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            let symbol = UIImage(systemName: "chevron.left",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold))?
                .withTintColor(foreground, renderingMode: .alwaysOriginal)

            // A rendered image retains its dimensions in UIKit's back indicator slot.
            return UIGraphicsImageRenderer(size: bounds.size).image { _ in
                let outline = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
                fill.setFill()
                outline.fill()
                foreground.withAlphaComponent(0.12).setStroke()
                outline.lineWidth = 0.5
                outline.stroke()
                if let symbol {
                    symbol.draw(at: CGPoint(x: (diameter - symbol.size.width) / 2,
                                            y: (diameter - symbol.size.height) / 2))
                }
            }
            .withRenderingMode(.alwaysOriginal)
            .imageFlippedForRightToLeftLayoutDirection()
        }

        private static func appearance(_ source: UINavigationBarAppearance, image: UIImage) -> UINavigationBarAppearance {
            let appearance = source.copy()
            appearance.setBackIndicatorImage(image, transitionMaskImage: image)
            return appearance
        }
    }
}
