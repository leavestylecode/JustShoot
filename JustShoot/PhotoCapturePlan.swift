import Foundation

/// Numeric contract at the look's input, independent of the camera's file format.
enum FilmInputSpace: String, Codable, Sendable {
    /// Legacy checkpointed jobs only. New looks all use displaySRGB.
    case sceneLinearRec2020
    case displaySRGB
}

enum PhotoCaptureMode: String, CaseIterable, Sendable {
    case quality
    case livePhoto
}

/// Resolved before exposure and persisted with the job. Hardware changes invalidate
/// the admission rather than silently delivering a different source format.
struct PhotoCapturePlan: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case appleProRAW, processed, livePhoto }
    let version: Int
    let format: Format
    let inputSpace: FilmInputSpace
    let approximateLook: Bool

    var capturesRAW: Bool { format == .appleProRAW }
    var capturesLivePhoto: Bool { format == .livePhoto }
    var isValid: Bool {
        (version == 2 && inputSpace == .displaySRGB && !approximateLook)
            || (version == 1 && (capturesRAW || inputSpace == .displaySRGB)
                && (!approximateLook || inputSpace == .displaySRGB))
    }

    func accepts(rawRecipe: RawCaptureRecipe?) -> Bool {
        guard isValid, capturesRAW == (rawRecipe != nil) else { return false }
        guard let rawRecipe else { return true }
        return rawRecipe.resolvedInputSpace == inputSpace && (version == 1 || rawRecipe.version == 4)
    }

    static func resolve(mode: PhotoCaptureMode) -> Self {
        // Camera capability and Photos authorization must not silently change the
        // image development behind the same look. Keep RAW support for frozen jobs
        // and explicit diagnostic captures; ordinary new captures use processed SDR.
        let format: Format = mode == .livePhoto ? .livePhoto : .processed
        // Every new look has one display-referred contract. Version 1 remains
        // decodable solely for jobs already checkpointed by older releases.
        return Self(version: 2, format: format, inputSpace: .displaySRGB, approximateLook: false)
    }
}

extension FilmSource {
    var inputSpace: FilmInputSpace { .displaySRGB }

    /// LUTs already define their color response. Retain film texture while removing
    /// the old, uncalibrated second illuminant-dependent color cast from new photos.
    var captureRenderProfile: FilmRenderProfile {
        let profile = renderProfile
        return FilmRenderProfile(grain: profile.grain.forUnifiedCapture, optics: profile.optics, chromatic: .neutral)
    }
}

/// Serial preparation outside UI updates. New captures use the same prepared
/// WB → look → curve cube as the viewfinder and Live Photo frames.
actor FilmCapturePreparation {
    static let shared = FilmCapturePreparation()

    func prepareRendering() throws {
        try Task.checkCancellation()
        try FilmMaterialRenderer.prepare()
        try Task.checkCancellation()
    }

    func displayLUT(source: FilmSource, curve: FilmCurve) throws -> CubeLUT {
        try Task.checkCancellation()
        let lut = try FilmProcessor.shared.loadLUT(source: source, curve: curve)
        try prepareRendering()
        try Task.checkCancellation()
        return lut
    }
}
