import CoreImage
import ImageIO
import UIKit

struct CapturePreview: Identifiable, Sendable {
    let id: UUID
    let filterName: String
    let image: UIImage
}

/// A bounded, disposable preview. It never enters the photo index or final-image cache.
enum CapturePreviewRenderer {
    static let maximumPixel = 1_024
    private static let work = BlockingImageWork(maximumConcurrentOperations: 1,
        label: "com.justshoot.capture-preview")
    private static let context = CIContext(options: [
        .workingColorSpace: FilmImagePipeline.colorSpace,
        .outputColorSpace: FilmImagePipeline.colorSpace,
        .cacheIntermediates: false,
        .priorityRequestLow: true
    ])

    static func image(data: Data, lut: CubeLUT, recipe: CaptureRecipe? = nil) async -> UIImage? {
        await work.run {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            // RAW previews use the embedded processed thumbnail. Never start a full
            // RAW development just to update a 46pt camera badge.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: !RawFilmRenderer.isDNG(source),
                kCGImageSourceThumbnailMaxPixelSize: maximumPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let profile = recipe?.profile
            let chromatic = profile?.effectiveChromatic ?? .neutral
            guard let stages = FilmImagePipeline.stages(for: CIImage(cgImage: small), lut: lut,
                chromaticGain: chromatic.responseGain(sceneCCT: recipe?.chromaticSceneCCT),
                protectChromaticHighlights: chromatic.protectsHighlights,
                optics: profile?.optics ?? .disabled, grain: profile?.grain ?? .disabled,
                grainSeed: recipe?.grainSeed ?? 0),
                  let pixels = context.createCGImage(stages.final, from: stages.final.extent,
                    format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace) else { return nil }
            return UIImage(cgImage: pixels)
        }
    }
}
