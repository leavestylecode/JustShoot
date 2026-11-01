import Foundation

enum FilmPreset: String, CaseIterable, Identifiable, Sendable {
    case fujiRawVelvia, fujiRawASTIA, fujiRawClassicChrome, fujiRawClassicNeg, fujiRawACROS
    case fujiC200
    case fujiPro400H
    case fujiProvia100F
    case kodakPortra400

    var id: String { rawValue }

    var displayName: String {
        if let simulation = rawSimulation { return "FUJIFILM " + simulation.displayName }
        switch self {
        case .fujiC200: return "Fuji C200"
        case .fujiPro400H: return "Fuji Pro 400H"
        case .fujiProvia100F: return "Fuji Provia 100F"
        case .kodakPortra400: return "Kodak Portra 400"
        default: return rawValue
        }
    }

    var iso: Float {
        switch self {
        case .fujiC200: return 200
        case .fujiPro400H: return 400
        case .fujiProvia100F: return 100
        case .kodakPortra400: return 400
        default: return 100 // Simulation presets have no physical film ISO rating.
        }
    }

    var lutResourceName: String {
        if let simulation = rawSimulation { return simulation.resourceName }
        switch self {
        case .fujiC200: return "FujiC200"
        case .fujiPro400H: return "FujiPro400H"
        case .fujiProvia100F: return "FujiProvia100F"
        case .kodakPortra400: return "KodakPortra400"
        default: return rawValue
        }
    }

    /// Matching packaging or a dedicated cover based on the stock's researched identity.
    var libraryCardImage: String? {
        if let simulation = rawSimulation { return simulation.libraryCardImage }
        switch self {
        case .fujiC200: return "cover_fuji_c200.heic"
        case .fujiPro400H: return "cover_fuji_pro_400h.heic"
        case .kodakPortra400: return "cover_kodak_portra_400.heic"
        default: return nil
        }
    }

    var rawSimulation: FujifilmSimulation? {
        switch self {
        case .fujiProvia100F: return .provia
        case .fujiRawVelvia: return .velvia
        case .fujiRawASTIA: return .astia
        case .fujiRawClassicChrome: return .classicChrome
        case .fujiRawClassicNeg: return .classicNeg
        case .fujiRawACROS: return .acros
        default: return nil
        }
    }
}
