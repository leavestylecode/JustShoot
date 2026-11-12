import Foundation

/// Shared scene vocabulary. Keep identifiers independent of translated display names.
enum FilmSceneTag: String, CaseIterable, Identifiable, Sendable {
    case sunny, cloudy, rainy
    case sunrise, sunset, night
    case backlight, neon
    case portrait, street, landscape, architecture, stillLife, flowers, food, travel
    case indoor, forest, beach, snow

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .sunny: return "Sunny"
        case .cloudy: return "Cloudy"
        case .rainy: return "Rainy"
        case .sunrise: return "Sunrise"
        case .sunset: return "Sunset"
        case .night: return "Night"
        case .backlight: return "Backlight"
        case .neon: return "Neon"
        case .portrait: return "Portrait"
        case .street: return "Street"
        case .landscape: return "Landscape"
        case .architecture: return "Architecture"
        case .stillLife: return "Still life"
        case .flowers: return "Flowers"
        case .food: return "Food"
        case .travel: return "Travel"
        case .indoor: return "Indoor"
        case .forest: return "Forest"
        case .beach: return "Beach"
        case .snow: return "Snow"
        }
    }

    func localizedTitle(locale: Locale) -> String {
        var resource = title
        resource.locale = locale
        return String(localized: resource)
    }
}

extension FilmPreset {
    /// Ordered recommendations for the film-page subtitle, independent of rendering recipes.
    var sceneTags: [FilmSceneTag] {
        switch self {
        case .fujiRawVelvia: return [.sunset, .landscape, .forest]
        case .fujiRawASTIA: return [.sunny, .portrait, .flowers]
        case .fujiRawClassicChrome: return [.cloudy, .street, .architecture]
        case .fujiRawClassicNeg: return [.sunny, .street, .travel]
        case .fujiRawACROS: return [.street, .architecture, .portrait]
        case .fujiC200: return [.sunny, .travel, .street]
        case .fujiPro400H: return [.cloudy, .portrait, .indoor]
        case .fujiProvia100F: return [.sunny, .landscape, .travel]
        case .kodakPortra400: return [.portrait, .backlight, .sunset]
        case .kodakGold200: return [.sunny, .travel, .street]
        case .kodakEktar100: return [.landscape, .sunny, .flowers]
        case .kodakPortra800: return [.portrait, .indoor, .night]
        case .fujiSuperiaXTRA400: return [.street, .travel, .cloudy]
        case .fujiVelvia50: return [.landscape, .sunset, .forest]
        case .fujiSlideProvia100F: return [.sunny, .landscape, .travel]
        case .kodakKodachrome64: return [.travel, .street, .sunny]
        case .kodakTriX400: return [.street, .portrait, .night]
        case .ilfordHP5Plus400: return [.street, .cloudy, .portrait]
        case .kodakTMax100: return [.architecture, .sunny, .street]
        }
    }

    func sceneSubtitle(locale: Locale) -> String {
        sceneTags.map { $0.localizedTitle(locale: locale) }.joined(separator: " · ")
    }
}
