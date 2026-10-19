import SwiftUI
import UIKit

/// Keep viewfinder adjustments from starting either native navigation-back pan.
/// The camera's explicit Back action still pops normally; other pages regain
/// the recognizers' original state when this controller disappears.
struct CameraNavigationGestureBlocker: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.disableIfVisible()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        private var isVisible = false
        private var savedStates: [(recognizer: UIGestureRecognizer, isEnabled: Bool)] = []

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            disableIfVisible()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            disableIfVisible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        func disableIfVisible() {
            guard isVisible, let navigationController else { return }
            let recognizers = [navigationController.interactivePopGestureRecognizer,
                               navigationController.interactiveContentPopGestureRecognizer].compactMap { $0 }
            for recognizer in recognizers {
                if !savedStates.contains(where: { $0.recognizer === recognizer }) {
                    savedStates.append((recognizer, recognizer.isEnabled))
                }
                recognizer.isEnabled = false
            }
        }

        func restore() {
            isVisible = false
            for state in savedStates { state.recognizer.isEnabled = state.isEnabled }
            savedStates.removeAll()
        }
    }
}
