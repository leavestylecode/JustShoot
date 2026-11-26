import SwiftUI

/// Keep the page visible through app-owned controls when iOS flattens its backdrop materials.
/// Photo wallpapers have already been blurred at the user's chosen radius by BackgroundPhotoStore.
enum AppSurfaceMaterial: ShapeStyle {
    case ultraThin, thin, regular, bar

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        if environment.accessibilityReduceTransparency {
            let tint = environment.colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.97)
            let opacity: Double = switch self {
            case .ultraThin: 0.40
            case .thin: 0.56
            case .regular: 0.72
            case .bar: 0.80
            }
            return AnyShapeStyle(tint.opacity(opacity))
        }
        let material: Material = switch self {
        case .ultraThin: .ultraThin
        case .thin: .thin
        case .regular: .regular
        case .bar: .bar
        }
        return AnyShapeStyle(material)
    }
}

@available(iOS 26.0, *)
private struct AppGlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        content
            .glassEffect(reduceTransparency ? .identity : .regular.interactive(interactive), in: shape)
            .clipShape(shape)
            .background {
                if reduceTransparency {
                    shape.fill((scheme == .dark ? Color(white: 0.13) : .white).opacity(0.56))
                        .overlay {
                            shape.strokeBorder(.linearGradient(colors: [.white.opacity(0.40), .primary.opacity(0.13)],
                                startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                        }
                        .allowsHitTesting(false)
                }
            }
    }
}

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
            modifier(AppGlassSurface(shape: Capsule(), interactive: false))
        } else {
            legacyGlassSurface(Capsule(), material: .ultraThin)
        }
    }

    @ViewBuilder
    func settingsGlassCard(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(iOS 26.0, *) {
            modifier(AppGlassSurface(shape: shape, interactive: interactive))
        } else {
            legacyGlassSurface(shape)
        }
    }

    func legacyGlassSurface<S: InsettableShape>(_ shape: S, material: AppSurfaceMaterial = .thin) -> some View {
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
