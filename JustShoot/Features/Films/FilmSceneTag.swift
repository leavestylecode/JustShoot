import Foundation

/// Shared scene vocabulary. Keep identifiers independent of translated display names.
enum FilmSceneTag: String, CaseIterable, Identifiable, Sendable {
    case landscape, portrait, street, documentary, architecture, wedding, stillLife
    case sunny, cloudy, rainy, snow, sunset, night

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        case .street: return "Street"
        case .documentary: return "Documentary"
        case .architecture: return "Architecture"
        case .wedding: return "Wedding"
        case .stillLife: return "Still life"
        case .sunny: return "Sunny"
        case .cloudy: return "Cloudy"
        case .rainy: return "Rainy"
        case .snow: return "Snow"
        case .sunset: return "Sunset"
        case .night: return "Night"
        }
    }

    func localizedTitle(locale: Locale) -> String {
        var resource = title
        resource.locale = locale
        return String(localized: resource)
    }
}

extension FilmPreset {
    func sceneSubtitles(locale: Locale) -> (full: String, compact: String) {
        let titles = recommendations.prefix(3).map { $0.tag.localizedTitle(locale: locale) }
        return (titles.joined(separator: " · "), titles.prefix(2).joined(separator: " · "))
    }
}
