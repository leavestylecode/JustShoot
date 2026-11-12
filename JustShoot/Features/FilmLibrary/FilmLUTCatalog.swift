import Foundation

/// Only capture-ready presets become library entries; packaging is presentation metadata.
/// Build once on the catalog worker, never while updating a view.
enum FilmLUTCatalog {
    static func availablePresets(in bundle: Bundle = .main) -> Set<FilmPreset> {
        Set(FilmPreset.allCases.filter {
            bundle.url(forResource: $0.lutResourceName, withExtension: "jslut") != nil
        })
    }

    static func cards(packaging: [FilmCard], availablePresets: Set<FilmPreset>) -> [FilmCard] {
        let byImage = Dictionary(packaging.map { ($0.image, $0) }, uniquingKeysWith: { first, _ in first })
        return FilmPagePreferences.catalogPresets.compactMap { preset in
            guard availablePresets.contains(preset), let image = preset.libraryCardImage else { return nil }
            let original = byImage[image]
            return FilmCard(id: preset.rawValue, image: image,
                brand: original?.brand ?? (preset == .kodakPortra400 ? "Kodak" : "Fujifilm"),
                product: preset.rawSimulation?.displayName ?? preset.tileTitle,
                format: original?.format, iso: preset.rawSimulation == nil ? Int(preset.iso) : nil,
                process: original?.process, expiry: nil, type: nil, subtype: nil,
                quantity: nil, notes: nil, author: original?.author, color: original?.color)
        }
    }

    static func preset(for card: FilmCard) -> FilmPreset? {
        FilmPreset(rawValue: card.id)
    }
}
