import CoreImage
import UIKit

struct CapturePreview: Identifiable, Sendable {
    let id: UUID
    let filterName: String
    let image: UIImage
}

/// A bounded, disposable preview. It never enters the photo index or final-image cache.
enum CapturePreviewRenderer {
    static let badgePixel = 192
    static let maximumPixel = 1_024
    private static let work = BlockingImageWork(maximumConcurrentOperations: 1,
        label: "com.justshoot.capture-preview")
    private static let context = CIContext(options: [
        .workingColorSpace: FilmImagePipeline.colorSpace,
        .outputColorSpace: FilmImagePipeline.colorSpace,
        .cacheIntermediates: false
    ])

    static func image(frame: CameraPreviewFrame, lut: CubeLUT, recipe: CaptureRecipe? = nil,
                      maxPixel: Int = maximumPixel, recordsDiagnostics: Bool = true) async -> UIImage? {
        await work.run {
            let input = frame.inputImage(maximumPixel: CGFloat(maxPixel))
            let profile = recipe?.profile
            let chromatic = profile?.effectiveChromatic ?? .neutral
            guard let stages = FilmImagePipeline.stages(for: input, lut: lut,
                lutIntensity: frame.lutIntensity,
                chromaticGain: frame.chromaticGain,
                protectChromaticHighlights: chromatic.protectsHighlights,
                optics: profile?.optics ?? .disabled, grain: profile?.grain ?? .disabled,
                grainSeed: frame.grainSeed),
                  let pixels = context.createCGImage(stages.final, from: stages.final.extent,
                    format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace) else { return nil }
            if recordsDiagnostics, maxPixel == maximumPixel, let recipe, FilmProcessor.stageDiagnosticsEnabled {
                CaptureComparisonDiagnostics.writePreview(frame: frame, input: input,
                    output: stages.final, recipe: recipe, context: context)
            }
            return UIImage(cgImage: pixels)
        }
    }
}
