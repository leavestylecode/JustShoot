import UIKit

/// Size bundled covers and await the snapshot needed by the camera picker.
/// The returned snapshot owns its images even if NSCache evicts an entry before first display.
enum FilmPresetCoverPreparation {
    enum PreparationError: Error { case missingCover(FilmPreset) }

    static func homePixel(displayScale: CGFloat) -> Int {
        max(Int(220 * scale(displayScale)), 300)
    }

    static func pickerPixel(displayScale: CGFloat) -> Int {
        max(Int(72 * scale(displayScale) * 1.5), 100)
    }

    static func preparePicker(presets: [FilmPreset] = FilmPreset.allCases, displayScale: CGFloat) async throws -> [FilmPreset: UIImage] {
        try await prepare(presets: presets, maxPixel: pickerPixel(displayScale: displayScale))
    }

    private static func scale(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 1), 4) : 1
    }

    private static func prepare(presets: [FilmPreset], maxPixel: Int) async throws -> [FilmPreset: UIImage] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (FilmPreset, UIImage).self) { group in
            for preset in Set(presets) {
                guard let imageName = preset.libraryCardImage else { continue }
                group.addTask {
                    guard let image = await FilmCardImageCache.shared.loadImage(imageName: imageName,
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
