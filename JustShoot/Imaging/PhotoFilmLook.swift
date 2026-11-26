import Foundation

/// The film and curve recorded for one exposure or editing pass.
struct PhotoFilmLook: Codable, Equatable, Sendable {
    var filmID: String?
    var filmName: String?
    var curve: PhotoEditCurve?
    var intensity: Double?

    init(filmID: String?, filmName: String?, curve: PhotoEditCurve?, intensity: Double? = nil) {
        self.filmID = filmID
        self.filmName = filmName
        self.curve = curve
        self.intensity = intensity
    }

    init(capture: CaptureRecipe) {
        self.init(filmID: capture.filterName, filmName: capture.displayLabel, curve: capture.curve)
    }

    var preset: FilmPreset? { filmID.flatMap(FilmPreset.init(rawValue:)) }

    var customID: UUID? {
        guard let filmID else { return nil }
        return UUID(uuidString: filmID.hasPrefix("custom:") ? String(filmID.dropFirst(7)) : filmID)
    }

    var hasRecord: Bool { filmID != nil || filmName != nil || curve != nil }
}
