import Foundation
import Combine

/// Film-page preferences use stable source IDs; importing or hiding a film never resets its position.
struct FilmPagePreferences: Codable, Equatable, Sendable {
    var showsTitle = true
    var showsSubtitle = true
    var hiddenPresetIDs: Set<String> = []
    var orderedFilmIDs: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case showsTitle, showsSubtitle, hiddenPresetIDs, orderedFilmIDs
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsTitle = try values.decodeIfPresent(Bool.self, forKey: .showsTitle) ?? true
        showsSubtitle = try values.decodeIfPresent(Bool.self, forKey: .showsSubtitle) ?? true
        hiddenPresetIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenPresetIDs) ?? []
        orderedFilmIDs = try values.decodeIfPresent([String].self, forKey: .orderedFilmIDs) ?? []
    }

    func ordered(_ sources: [FilmSource]) -> [FilmSource] {
        var byID: [String: FilmSource] = [:]
        for source in sources { byID[source.id] = source }
        var seen = Set<String>()
        // Saved items keep their relative order; newly available films append in catalog order.
        return (orderedFilmIDs + sources.map(\.id)).compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
    }

    func isVisible(_ source: FilmSource) -> Bool {
        if case .preset(let preset) = source {
            return !hiddenPresetIDs.contains(preset.rawValue)
        }
        return true
    }
}

@MainActor
final class FilmPageSettings: ObservableObject {
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
    }

    var textVisibility: FilmTileTextVisibility {
        FilmTileTextVisibility(showsTitle: preferences.showsTitle, showsSubtitle: preferences.showsSubtitle)
    }

    func setVisible(_ preset: FilmPreset, _ visible: Bool) {
        if visible { preferences.hiddenPresetIDs.remove(preset.rawValue) }
        else { preferences.hiddenPresetIDs.insert(preset.rawValue) }
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
