import SwiftUI
import UIKit

/// Broader iPad orientations are scoped to scenes displaying the camera.
/// Browsing and iPhone retain their portrait interface.
struct CameraInterfaceOrientationSupport: UIViewControllerRepresentable {
    let enabled: Bool

    @MainActor private static var sceneOwners: [ObjectIdentifier: Set<UUID>] = [:]

    static func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let window, window.traitCollection.userInterfaceIdiom == .pad,
              let scene = window.windowScene, sceneOwners[ObjectIdentifier(scene)]?.isEmpty == false else {
            return .portrait
        }
        return .all
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enabled = enabled
        controller.updateSupport()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        var enabled = false
        private let owner = UUID()
        private weak var registeredScene: UIWindowScene?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateSupport()
        }

        func updateSupport() {
            guard enabled else { restore(); return }
            guard let window = viewIfLoaded?.window, window.traitCollection.userInterfaceIdiom == .pad,
                  let scene = window.windowScene, registeredScene !== scene else { return }
            restore()
            registeredScene = scene
            CameraInterfaceOrientationSupport.sceneOwners[ObjectIdentifier(scene), default: []].insert(owner)
            updateOrientations(in: scene, mask: .all)
        }

        func restore() {
            guard let scene = registeredScene else { return }
            registeredScene = nil
            let key = ObjectIdentifier(scene)
            CameraInterfaceOrientationSupport.sceneOwners[key]?.remove(owner)
            if CameraInterfaceOrientationSupport.sceneOwners[key]?.isEmpty == true {
                CameraInterfaceOrientationSupport.sceneOwners[key] = nil
                updateOrientations(in: scene, mask: .portrait)
            }
        }

        private func updateOrientations(in scene: UIWindowScene, mask: UIInterfaceOrientationMask) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }
}
