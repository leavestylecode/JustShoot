import SwiftUI

extension View {
    /// Keep content behind navigation and bottom bars softly feathered on Liquid Glass.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            self
        }
    }

    @ViewBuilder
    func cameraShutterEvent(_ action: @escaping @MainActor () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onCameraCaptureEvent { event in
                if event.phase == .ended { action() }
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func keepTabBarExpanded() -> some View {
        if #available(iOS 26.0, *) {
            // A minimized icon-only bar conceals the other destinations.
            tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }

    @ViewBuilder
    func cameraControlSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        }
    }

    @ViewBuilder
    func filmTransitionSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func filmZoomTransition(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }

    @ViewBuilder
    func standardCameraTransition() -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.automatic)
        } else {
            self
        }
    }
}
