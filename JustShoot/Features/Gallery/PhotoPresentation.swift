import Foundation

extension Photo {
    var filmPreset: FilmPreset? {
        guard let name = filmPresetName else { return nil }
        return FilmPreset(rawValue: name)
    }

    var filmDisplayName: String {
        filmPreset?.displayName ?? filmDisplayLabel ?? String(localized: "Default")
    }
}

extension PhotoFilmLook {
    /// The information sheet shows the most recent choice for each control.
    /// A baked exposure still supplies any color controls the editor left untouched.
    func displayed(over capture: PhotoFilmLook?) -> PhotoFilmLook {
        guard let capture else { return self }
        var result = self
        if filmID == nil {
            result.filmID = capture.filmID
            result.filmName = capture.filmName
            result.intensity = capture.intensity
        }
        if curve == .preset(.none) { result.curve = capture.curve }
        return result
    }
}

struct PhotoEditorSelection: Identifiable {
    let id: String
}

@MainActor @Observable
final class PhotoEditChanges {
    static let shared = PhotoEditChanges()
    private var revisions: [String: Int] = [:]

    subscript(photo: Photo) -> Int {
        guard !photo.isDeleted, let id = photo.assetLocalIdentifier else { return 0 }
        return revisions[id, default: 0]
    }

    func didSave(assetID: String) {
        AssetImageLoader.shared.invalidate(id: assetID)
        revisions[assetID, default: 0] += 1
    }
}
