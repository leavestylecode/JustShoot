import Foundation

/// OOO's neutral, AI-created SDR comparison scenes, shared with its LUT comparison site.
/// Each finished sample is graded offline with the app's FilmImagePipeline.
enum FilmSampleScene: String, Identifiable, Sendable {
    case windowPortrait = "portrait-neutral-v2"
    case outdoorPortrait = "portrait-deep"
    case forest, coast, street, architecture, stilllife, neon, interior

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .windowPortrait: "Window portrait"
        case .outdoorPortrait: "Outdoor portrait"
        case .forest: "Forest"
        case .coast: "Coast"
        case .street: "Blue hour"
        case .architecture: "Architecture"
        case .stilllife: "Still life"
        case .neon: "Neon"
        case .interior: "Café"
        }
    }

    func filename(gradedWith preset: FilmPreset? = nil) -> String {
        if let preset { return "vault-\(rawValue)-\(preset.rawValue).heic" }
        return "vault-\(rawValue).jpg"
    }
}

extension FilmPreset {
    /// The first photograph opens the detail page. Shared source scenes also make
    /// the response of different stocks comparable.
    var sampleScenes: [FilmSampleScene] {
        switch self {
        case .kodakPortra400: [.windowPortrait, .outdoorPortrait, .interior]
        case .kodakGold200: [.coast, .interior, .street]
        case .fujiPro400H: [.outdoorPortrait, .windowPortrait, .forest]
        case .fujiC200: [.street, .coast, .stilllife]
        case .kodakEktar100: [.coast, .architecture, .stilllife]
        case .fujiVelvia50: [.forest, .coast, .architecture]
        case .ilfordHP5Plus400: [.outdoorPortrait, .street, .architecture]
        case .kodakTriX400: [.street, .neon, .windowPortrait]
        case .fujiRawClassicChrome: [.architecture, .street, .outdoorPortrait]
        case .fujiRawVelvia: [.coast, .forest, .stilllife]
        case .fujiRawASTIA: [.windowPortrait, .stilllife, .outdoorPortrait]
        case .fujiRawClassicNeg: [.street, .interior, .architecture]
        case .fujiRawACROS: [.architecture, .outdoorPortrait, .neon]
        case .fujiProvia100F: [.architecture, .forest, .coast]
        case .kodakPortra800: [.interior, .windowPortrait, .neon]
        case .fujiSuperiaXTRA400: [.neon, .street, .forest]
        case .fujiSlideProvia100F: [.forest, .coast, .architecture]
        case .kodakKodachrome64: [.architecture, .coast, .street]
        case .kodakTMax100: [.architecture, .windowPortrait, .stilllife]
        }
    }
}
