import Foundation

/// Shared scene vocabulary. Keep identifiers independent of translated display names.
enum FilmSceneTag: String, CaseIterable, Identifiable, Sendable {
    case sunny, cloudy, rainy
    case sunrise, sunset, night
    case backlight, neon
    case portrait, street, landscape, architecture, stillLife, flowers, food, travel
    case indoor, forest, beach, snow

    case documentary, family, fashion, wedding, sports

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
        case .documentary: return "Documentary"
        case .family: return "Family"
        case .fashion: return "Fashion"
        case .wedding: return "Wedding"
        case .sports: return "Sports"
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
        case .fujiRawVelvia: return [.landscape, .forest, .sunset]
        case .fujiRawASTIA: return [.portrait, .fashion, .indoor]
        case .fujiRawClassicChrome: return [.documentary, .street, .travel]
        case .fujiRawClassicNeg: return [.street, .family, .travel]
        case .fujiRawACROS: return [.street, .portrait, .architecture]
        case .fujiC200: return [.sunny, .portrait, .landscape]
        case .fujiPro400H: return [.portrait, .wedding, .fashion]
        case .fujiProvia100F: return [.travel, .portrait, .landscape]
        case .kodakPortra400: return [.portrait, .fashion, .travel]
        case .kodakGold200: return [.family, .sunny, .travel]
        case .kodakEktar100: return [.landscape, .travel, .stillLife]
        case .kodakPortra800: return [.portrait, .indoor, .night]
        case .fujiSuperiaXTRA400: return [.street, .family, .travel]
        case .fujiVelvia50: return [.landscape, .flowers, .forest]
        case .fujiSlideProvia100F: return [.landscape, .portrait, .stillLife]
        case .kodakKodachrome64: return [.travel, .street, .landscape]
        case .kodakTriX400: return [.street, .documentary, .sports]
        case .ilfordHP5Plus400: return [.documentary, .indoor, .travel]
        case .kodakTMax100: return [.architecture, .stillLife, .sunny]
        }
    }

    func sceneSubtitle(locale: Locale) -> String {
        sceneTags.map { $0.localizedTitle(locale: locale) }.joined(separator: " · ")
    }
}
