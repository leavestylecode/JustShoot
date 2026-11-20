import Foundation

/// Shared scene vocabulary. Keep identifiers independent of translated display names.
enum FilmSceneTag: String, CaseIterable, Identifiable, Sendable {
    case cloudy, rainy
    case sunrise, sunset, night
    case backlight, neon
    case portrait, street, landscape, architecture, stillLife, flowers, food
    case forest, beach, snow

    case documentary, fashion, wedding, sports
    case familyPortrait, childPortrait, indoorPortrait, festival, teaCeremony
    case trains, roadside, seascape, streetscape, market, harvest

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
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
        case .forest: return "Forest"
        case .beach: return "Beach"
        case .snow: return "Snow"
        case .documentary: return "Documentary"
        case .fashion: return "Fashion"
        case .wedding: return "Wedding"
        case .sports: return "Sports"
        case .familyPortrait: return .init("Family portrait", table: "FilmIntroductions")
        case .childPortrait: return .init("Child portrait", table: "FilmIntroductions")
        case .indoorPortrait: return .init("Indoor portrait", table: "FilmIntroductions")
        case .festival: return .init("Festivals", table: "FilmIntroductions")
        case .teaCeremony: return .init("Tea ceremony", table: "FilmIntroductions")
        case .trains: return .init("Trains", table: "FilmIntroductions")
        case .roadside: return .init("Roadside", table: "FilmIntroductions")
        case .seascape: return .init("Seascape", table: "FilmIntroductions")
        case .streetscape: return .init("Streetscape", table: "FilmIntroductions")
        case .market: return .init("Market", table: "FilmIntroductions")
        case .harvest: return .init("Harvest", table: "FilmIntroductions")
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
