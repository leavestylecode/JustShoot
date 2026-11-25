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
    case hdr

    static let hdrPreferenceKey = "photoCapture.hdrEnabled"
    static let hdrEnabledByDefault = true

    static var supportsHDR: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    static func preferred(livePhoto: Bool, hdrEnabled: Bool) -> Self {
        if livePhoto { return .livePhoto }
        return hdrEnabled && supportsHDR ? .hdr : .quality
    }
}

/// Resolved before exposure and persisted with the job. Hardware changes invalidate
/// the admission rather than silently delivering a different source format.
struct PhotoCapturePlan: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case appleProRAW, processed, livePhoto, hdrProRAW, processedHDR }
    let version: Int
    let format: Format
    let inputSpace: FilmInputSpace
    let approximateLook: Bool

    var capturesRAW: Bool { format == .appleProRAW || format == .hdrProRAW }
    var capturesLivePhoto: Bool { format == .livePhoto }
    var capturesHDR: Bool { format == .hdrProRAW || format == .processedHDR }
    var isValid: Bool {
        (version == 2 && inputSpace == .displaySRGB && !approximateLook)
            || (version == 1 && !capturesHDR && (capturesRAW || inputSpace == .displaySRGB)
                && (!approximateLook || inputSpace == .displaySRGB))
    }

    func accepts(rawRecipe: RawCaptureRecipe?) -> Bool {
        guard isValid, capturesRAW == (rawRecipe != nil) else { return false }
        guard let rawRecipe else { return true }
        return rawRecipe.resolvedInputSpace == inputSpace && (version == 1 || rawRecipe.version == 4)
    }

    static func resolve(mode: PhotoCaptureMode, deferredDelivery: Bool = false, directHDRAvailable: Bool = false) -> Self {
        let format: Format = switch mode {
        case .quality: .processed
        case .livePhoto: .livePhoto
        case .hdr where deferredDelivery: .processedHDR
        case .hdr where directHDRAvailable: .hdrProRAW
        case .hdr: .processed
        }
        // HDR also grades an SDR base with the same display-referred look.
        return Self(version: 2, format: format, inputSpace: .displaySRGB, approximateLook: false)
    }
}

extension FilmSource {
    var inputSpace: FilmInputSpace { .displaySRGB }

    /// LUTs already define their color response. Retain film texture while removing
    /// the old, uncalibrated second illuminant-dependent color cast from new photos.
    var captureRenderProfile: FilmRenderProfile {
        let profile = renderProfile
        var grain = profile.grain.forUnifiedCapture
        if case .preset(let preset) = self {
            if preset == .kodakPortra400 {
                // A broader density grain survives album downsampling at the same native amplitude.
                grain = FilmGrainParameters(amount: grain.amount, size: grain.size * 1.4,
                    chroma: grain.chroma, response: grain.response)
            } else if preset.rawSimulation != nil {
                grain = preset.isMonochrome
                    ? FilmGrainParameters(amount: 0.038, size: 1.45, chroma: 0, response: .fujifilmFineFiltered)
                    : FilmGrainParameters(amount: 0.042, size: 1.70, chroma: 0.025, response: .fujifilmFineFiltered)
            }
        }
        return FilmRenderProfile(grain: grain, optics: profile.optics, chromatic: .neutral)
    }
}
