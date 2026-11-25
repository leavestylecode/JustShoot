import SwiftUI

extension View {
    /// Soften scroll content at the toolbar edges visible on each platform.
    @ViewBuilder
    func softScrollEdges(legacyBars: VerticalEdge.Set = .top) -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            legacySoftToolbarEdges(legacyBars)
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
            legacyGlassSurface(Capsule(), material: .ultraThinMaterial)
        }
    }

    @ViewBuilder
    func settingsGlassCard(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            legacyGlassSurface(shape)
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        }
    }

    func legacyGlassSurface<S: InsettableShape>(_ shape: S, material: Material = .thinMaterial) -> some View {
        background(material, in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    .allowsHitTesting(false)
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
