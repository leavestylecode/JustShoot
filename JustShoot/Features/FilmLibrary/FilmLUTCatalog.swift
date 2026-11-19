import Foundation

/// Packaging metadata is unnecessary for browsing capture-ready looks. Read only
/// the bundled LUT filenames, on the catalog worker, and preserve the curated order.
enum FilmLUTCatalog {
    static func availablePresets(in bundle: Bundle = .main) -> [FilmPreset]? {
        guard let urls = bundle.urls(forResourcesWithExtension: "jslut", subdirectory: nil) else { return nil }
        return presets(withLUTs: Set(urls.map { $0.deletingPathExtension().lastPathComponent }))
    }

    static func presets(withLUTs names: Set<String>) -> [FilmPreset] {
        FilmPagePreferences.catalogPresets.filter { names.contains($0.lutResourceName) }
    }
}
