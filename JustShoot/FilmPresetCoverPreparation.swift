import UIKit

/// Await only the eight bundled presets needed by the home grid or camera picker.
/// The returned snapshot owns its images even if NSCache evicts an entry before first display.
enum FilmPresetCoverPreparation {
    enum PreparationError: Error { case missingCover(FilmPreset) }

    static func homePixel(displayScale: CGFloat) -> Int {
        max(Int(180 * scale(displayScale)), 300)
    }

    static func pickerPixel(displayScale: CGFloat) -> Int {
        max(Int(52 * scale(displayScale) * 1.5), 100)
    }

    static func prepareHome(displayScale: CGFloat) async throws -> [FilmPreset: UIImage] {
        try await prepare(maxPixel: homePixel(displayScale: displayScale))
    }

    static func preparePicker(displayScale: CGFloat) async throws -> [FilmPreset: UIImage] {
        try await prepare(maxPixel: pickerPixel(displayScale: displayScale))
    }

    private static func scale(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 1), 4) : 1
    }

    private static func prepare(maxPixel: Int) async throws -> [FilmPreset: UIImage] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (FilmPreset, UIImage).self) { group in
            for preset in FilmPreset.allCases {
                group.addTask {
                    guard let image = await FilmCardImageCache.shared.loadImage(imageName: preset.libraryCardImage,
                        maxPixel: maxPixel) else {
                        try Task.checkCancellation()
                        throw PreparationError.missingCover(preset)
                    }
                    try Task.checkCancellation()
                    return (preset, image)
                }
            }
            // The shared worker still limits decoding to two images at a time.
            var images: [FilmPreset: UIImage] = [:]
            for try await (preset, image) in group {
                try Task.checkCancellation()
                images[preset] = image
            }
            try Task.checkCancellation()
            return images
        }
    }
}
