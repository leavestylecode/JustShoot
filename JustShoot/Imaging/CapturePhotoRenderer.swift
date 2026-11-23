import Foundation
import CoreGraphics
import ImageIO

/// The single still-render entry used by durable jobs and physical camera validation.
/// All resources belong to the capture, never to the currently selected UI preset.
enum CapturePhotoRenderer {
    static func render(source: Data, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?,
                       contentIdentifier: String? = nil, grainSeed: UInt32,
                       trace: DiagnosticTrace? = nil,
                       cancellation: CaptureRenderCancellation? = nil) -> Data? {
        guard cancellation?.isCancelled != true else { return nil }
        if let plan = recipe.plan {
            guard plan.accepts(rawRecipe: recipe.raw),
                  let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
                  RawFilmRenderer.isDNG(imageSource) == plan.capturesRAW else { return nil }
        }
        return FilmProcessor.shared.applyLUTPreservingMetadata(
            imageData: source, lutCacheKey: recipe.filterName, capturedLUT: lut,
            lutIntensity: recipe.resolvedLUTIntensity,
            rawRecipe: recipe.raw, rawLUT: rawLUT,
            grain: recipe.profile.grain, grainSeed: grainSeed, optics: recipe.profile.optics,
            chromatic: recipe.profile.effectiveChromatic, chromaticSceneCCT: recipe.chromaticSceneCCT,
            chromaticGainOverride: recipe.frozenChromaticGain,
            outputQuality: recipe.outputQuality.map { CGFloat($0) },
            encodingMode: recipe.plan == nil ? .automatic : .quality, location: recipe.location?.location,
            captureDate: recipe.captureDate, focalLengthIn35mm: recipe.metadataFocalLength,
            contentIdentifier: contentIdentifier, diagnosticCaptureID: recipe.id, trace: trace,
            cancellation: cancellation)
    }
}
