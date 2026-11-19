import SwiftUI

enum AppAppearance: String, CaseIterable {
    static let key = "appearance.mode"
    case automatic, light, dark

    var scheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum BackgroundStyle: String { case gradient, photo }

enum BackgroundPalette: String, CaseIterable {
    case aurora, nebula, cosmic, crimson, ember, lunar, rose, stellar, cyan

    var title: LocalizedStringKey {
        switch self {
        case .aurora: "Aurora"
        case .nebula: "Nebula"
        case .cosmic: "Deep Space"
        case .crimson: "Crimson"
        case .ember: "Ember"
        case .lunar: "Moonlight"
        case .rose: "Rose Gold"
        case .stellar: "Starlight"
        case .cyan: "Cyan"
        }
    }

    var colors: (inner: Color, outer: Color) {
        switch self {
        case .aurora: (.init(red: 0, green: 0.9, blue: 0.5), .teal)
        case .nebula: (.init(red: 0.56, green: 0.16, blue: 0.8), .indigo)
        case .cosmic: (.init(red: 0.05, green: 0.3, blue: 0.8), .indigo)
        case .crimson: (.init(red: 1, green: 0.15, blue: 0.25), .pink)
        case .ember: (.init(red: 0.9, green: 0.45, blue: 0.15), .red)
        case .lunar: (.init(red: 0.72, green: 0.78, blue: 0.86), .gray)
        case .rose: (.init(red: 1, green: 0.55, blue: 0.75), .pink)
        case .stellar: (.init(red: 1, green: 0.92, blue: 0.15), .orange)
        case .cyan: (.init(red: 0.05, green: 0.65, blue: 0.85), .blue)
        }
    }
}

enum GradientOrigin: String, CaseIterable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

    var point: UnitPoint {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case .bottomLeading: .bottomLeading
        case .bottom: .bottom
        case .bottomTrailing: .bottomTrailing
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .topLeading: "Top Left"
        case .top: "Top"
        case .topTrailing: "Top Right"
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        case .bottomLeading: "Bottom Left"
        case .bottom: "Bottom"
        case .bottomTrailing: "Bottom Right"
        }
    }
}

enum PhotoEffectLevel: String, CaseIterable {
    case low, medium, high

    var title: LocalizedStringKey {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var blur: Double {
        switch self {
        case .low: 6
        case .medium: 20
        case .high: 40
        }
    }

    var saturation: Double {
        switch self {
        case .low: 0.65
        case .medium: 1
        case .high: 1.4
        }
    }
}

struct PageBackgroundPreferences: DynamicProperty {
    @AppStorage("appearance.background.enabled") var isEnabled = false
    @AppStorage("appearance.background.style") var style = BackgroundStyle.gradient
    @AppStorage("appearance.background.palette") var palette = BackgroundPalette.cosmic
    @AppStorage("appearance.background.origin") var origin = GradientOrigin.top
    @AppStorage("appearance.background.intensity") var intensity = 0.6
    @AppStorage("appearance.background.range") var range = 0.6
    @AppStorage("appearance.background.blur") var blur = PhotoEffectLevel.medium
    @AppStorage("appearance.background.saturation") var saturation = PhotoEffectLevel.medium
}

struct AppPageBackground: View {
    var lightBase = Color(uiColor: .systemBackground)
    private var preferences = PageBackgroundPreferences()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            scheme == .light ? lightBase : Color.black
            if preferences.isEnabled {
                switch preferences.style {
                case .gradient:
                    BackgroundGradient(palette: preferences.palette, origin: preferences.origin,
                                       intensity: preferences.intensity, range: preferences.range)
                case .photo:
                    CustomPhotoBackground(effect: BackgroundPhotoEffect(blur: preferences.blur.blur,
                                                                         saturation: preferences.saturation.saturation))
                        .opacity(scheme == .dark ? 0.45 : 0.32)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct BackgroundGradient: View {
    let palette: BackgroundPalette
    let origin: GradientOrigin
    let intensity: Double
    let range: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let strength = (scheme == .dark ? 0.62 : 0.42) * min(max(intensity, 0.1), 1)
            let radius = hypot(geometry.size.width, geometry.size.height) * (0.32 + min(max(range, 0.1), 1))
            RadialGradient(colors: [palette.colors.inner.opacity(strength),
                                    palette.colors.outer.opacity(strength * 0.55), .clear],
                           center: origin.point, startRadius: 0, endRadius: radius)
        }
    }
}

private struct CustomPhotoBackground: View {
    let effect: BackgroundPhotoEffect
    private let store = BackgroundPhotoStore.shared

    var body: some View {
        GeometryReader { geometry in
            if let image = store.filteredImage {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }
        .task(id: BackgroundPhotoRequest(source: store.image.map(ObjectIdentifier.init), effect: effect)) {
            await store.prepare(effect)
        }
    }
}

extension View {
    func appPageBackground() -> some View {
        background { AppPageBackground() }
    }
}
