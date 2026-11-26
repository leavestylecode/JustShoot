import SwiftUI
import UIKit

/// Install the design traits before UIKit creates navigation bars and presented controllers.
final class AppVisualSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        scene.traitOverrides.preferredContentSizeCategory = .large
        scene.traitOverrides.legibilityWeight = .regular
        scene.traitOverrides.accessibilityContrast = .normal
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let scene = scene as? UIWindowScene else { return }
        for window in scene.windows where window.windowLevel == .normal {
            window.accessibilityIgnoresInvertColors = true
        }
    }
}

extension View {
    /// Also apply at independently hosted SwiftUI roots, including the gallery's photo viewer.
    @ViewBuilder
    func appVisualDesign() -> some View {
        let content = dynamicTypeSize(.large)
            .environment(\.legibilityWeight, .regular)
            .scrollIndicators(.never)
        if #available(iOS 26.4, *) {
            content.environment(\.accessibilityPrefersCrossFadeTransitions, false)
        } else {
            content
        }
    }
}
