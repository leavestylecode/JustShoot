import SwiftUI
import UIKit

extension View {
    /// Zoom transitions install their own interactive dismissal gestures, beyond
    /// UINavigationController's edge/content pans. Use the standard transition
    /// and block those pans together so only the camera's Back button exits.
    func cameraButtonOnlyNavigation(customBackButton: Bool = false) -> some View {
        modifier(CameraButtonOnlyNavigationModifier(customBackButton: customBackButton))
    }
}

private struct CameraButtonOnlyNavigationModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let customBackButton: Bool

    func body(content: Content) -> some View {
        content
            .standardCameraTransition()
            .navigationBarBackButtonHidden(true)
            .toolbar(customBackButton ? .hidden : .visible, for: .navigationBar)
            .background(CameraNavigationGestureBlocker())
            .toolbar {
                if !customBackButton {
                    ToolbarItem(placement: .navigationBarLeading) { backButton }
                }
            }
    }

    private var backButton: some View {
        let tint = CameraPalette.foreground(for: colorScheme)
        return Button { dismiss() } label: {
            Image(systemName: "chevron.backward")
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .toolbarControlSurface()
        }
        .tint(tint)
        .accessibilityIdentifier("camera.back")
        .accessibilityLabel("Back")
    }
}

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
            var recognizers = [navigationController.interactivePopGestureRecognizer].compactMap { $0 }
            if #available(iOS 26.0, *), let content = navigationController.interactiveContentPopGestureRecognizer {
                recognizers.append(content)
            }
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
