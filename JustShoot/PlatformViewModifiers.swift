import SwiftUI

extension View {
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
    func scrollingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
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
    func filmCardSurface(in shape: RoundedRectangle) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            overlay(shape.strokeBorder(.white.opacity(0.16)))
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
