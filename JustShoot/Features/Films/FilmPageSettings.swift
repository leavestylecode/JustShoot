import Foundation
import Combine

/// Membership and ordering use stable IDs, independently of packaging-card variants.
struct FilmPagePreferences: Codable, Equatable, Sendable {
    // Keep the original preset IDs and LUTs readable for photos and frozen capture recipes.
    private static let replacements: [String: FilmPreset] = [
        FilmPreset.fujiVelvia50.id: .fujiRawVelvia,
        FilmPreset.fujiSlideProvia100F.id: .fujiProvia100F
    ]
    static let defaultPresets: [FilmPreset] = [
        .kodakPortra400, .kodakGold200, .fujiPro400H, .fujiC200, .kodakEktar100,
        .fujiRawVelvia, .ilfordHP5Plus400, .kodakTriX400, .fujiRawClassicChrome
    ]
    static let catalogPresets = defaultPresets + FilmPreset.allCases.filter {
        replacements[$0.id] == nil && !defaultPresets.contains($0)
    }
    private static let legacyPresets: [FilmPreset] = [
        .fujiRawVelvia, .fujiRawASTIA, .fujiRawClassicChrome, .fujiRawClassicNeg,
        .fujiRawACROS, .fujiC200, .fujiPro400H, .fujiProvia100F, .kodakPortra400
    ]

    var showsTitle = true
    var showsSubtitle = true
    var addedPresetIDs = Set(defaultPresets.map(\.rawValue))
    var orderedFilmIDs: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case showsTitle, showsSubtitle, addedPresetIDs, hiddenPresetIDs, orderedFilmIDs
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsTitle = try values.decodeIfPresent(Bool.self, forKey: .showsTitle) ?? true
        showsSubtitle = try values.decodeIfPresent(Bool.self, forKey: .showsSubtitle) ?? true
        orderedFilmIDs = try values.decodeIfPresent([String].self, forKey: .orderedFilmIDs) ?? []
        if let added = try values.decodeIfPresent(Set<String>.self, forKey: .addedPresetIDs) {
            addedPresetIDs = added
        } else {
            // Existing installations keep their individually visible films, including an
            // intentionally empty library. The nine-film default only seeds a new library.
            let hidden = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenPresetIDs) ?? []
            addedPresetIDs = Set(Self.legacyPresets.map(\.rawValue)).subtracting(hidden)
            let savedOrder = Set(orderedFilmIDs)
            orderedFilmIDs += Self.legacyPresets.map(\.rawValue).filter { !savedOrder.contains($0) }
        }
        // A hidden variant can still have a saved position. Prefer the first visible
        // variant's position so merging the pair preserves the order the user saw.
        let orderedSelections = Set(orderedFilmIDs.filter(addedPresetIDs.contains).map(Self.catalogID))
        var seen = Set<String>()
        orderedFilmIDs = orderedFilmIDs.compactMap { id in
            let retained = Self.catalogID(id)
            guard addedPresetIDs.contains(id) || !orderedSelections.contains(retained),
                  seen.insert(retained).inserted else { return nil }
            return retained
        }
        addedPresetIDs = Set(addedPresetIDs.map(Self.catalogID))
    }

    fileprivate static func catalogID(_ id: String) -> String { replacements[id]?.id ?? id }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(showsTitle, forKey: .showsTitle)
        try values.encode(showsSubtitle, forKey: .showsSubtitle)
        try values.encode(addedPresetIDs, forKey: .addedPresetIDs)
        try values.encode(orderedFilmIDs, forKey: .orderedFilmIDs)
    }

    func ordered(_ sources: [FilmSource]) -> [FilmSource] {
        var byID: [String: FilmSource] = [:]
        for source in sources { byID[source.id] = source }
        var seen = Set<String>()
        // Saved items keep their relative order; newly available films append in catalog order.
        return (orderedFilmIDs + Self.defaultPresets.map(\.rawValue) + sources.map(\.id)).compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
    }

    func isVisible(_ source: FilmSource) -> Bool {
        if case .preset(let preset) = source {
            return addedPresetIDs.contains(preset.rawValue)
        }
        return true
    }

    var addedPresets: [FilmPreset] {
        Self.catalogPresets.filter { addedPresetIDs.contains($0.rawValue) }
    }

    func cameraSources(_ sources: [FilmSource], current: FilmSource) -> [FilmSource] {
        let visible = ordered(sources).filter(isVisible)
        // A film opened directly from the catalog remains selectable for this camera visit.
        let selection = Self.replacements[current.id].map(FilmSource.preset) ?? current
        return visible.contains(where: { $0.id == selection.id }) ? visible : visible + [selection]
    }
}

@MainActor
final class FilmPageSettings: ObservableObject {
    static let shared = FilmPageSettings()
    @Published var preferences: FilmPagePreferences {
        didSet {
            guard preferences != oldValue,
                  let data = try? JSONEncoder().encode(preferences) else { return }
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    static let storageKey = "films.page.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(FilmPagePreferences.self, from: $0) } ?? FilmPagePreferences()
        // Freeze the initial selection and upgrade the old visibility payload once.
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.storageKey) }
    }

    var textVisibility: FilmTileTextVisibility {
        FilmTileTextVisibility(showsTitle: preferences.showsTitle, showsSubtitle: preferences.showsSubtitle)
    }

    func setVisible(_ preset: FilmPreset, _ visible: Bool) {
        let id = FilmPagePreferences.catalogID(preset.id)
        if visible { preferences.addedPresetIDs.insert(id) }
        else { preferences.addedPresetIDs.remove(id) }
    }

    func move(from offsets: IndexSet, to destination: Int, in sources: [FilmSource]) {
        var ids = preferences.ordered(sources).map(\.id)
        // Keep the ordering policy independent of SwiftUI's collection helpers.
        let moving = offsets.sorted().filter { ids.indices.contains($0) }
        guard !moving.isEmpty, (0...ids.count).contains(destination) else { return }
        let movedIDs = moving.map { ids[$0] }
        for index in moving.reversed() { ids.remove(at: index) }
        ids.insert(contentsOf: movedIDs, at: destination - moving.filter { $0 < destination }.count)
        preferences.orderedFilmIDs = ids
    }

    func removeCustomFilm(id: UUID) {
        preferences.orderedFilmIDs.removeAll { $0 == id.uuidString }
    }

    func resetOrder() {
        preferences.orderedFilmIDs = []
    }
}

extension FilmSource {
    var filmPageTitle: String {
        if case .preset(let preset) = self { return preset.rawSimulation?.displayName ?? preset.displayName }
        return displayName
    }
}
