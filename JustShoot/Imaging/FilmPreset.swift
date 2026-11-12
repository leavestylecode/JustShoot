import Foundation

enum FilmPreset: String, CaseIterable, Identifiable, Sendable {
    case fujiRawVelvia, fujiRawASTIA, fujiRawClassicChrome, fujiRawClassicNeg, fujiRawACROS
    case fujiC200
    case fujiPro400H
    case fujiProvia100F
    case kodakPortra400
    case kodakGold200, kodakEktar100, kodakPortra800
    case fujiSuperiaXTRA400, fujiVelvia50, fujiSlideProvia100F
    case kodakKodachrome64, kodakTriX400, ilfordHP5Plus400, kodakTMax100

    var id: String { rawValue }

    var displayName: String {
        if let simulation = rawSimulation { return "FUJIFILM " + simulation.displayName }
        switch self {
        case .fujiC200: return "Fuji C200"
        case .fujiPro400H: return "Fuji Pro 400H"
        case .fujiProvia100F: return "Fuji Provia 100F"
        case .kodakPortra400: return "Kodak Portra 400"
        case .kodakGold200: return "Kodak Gold 200"
        case .kodakEktar100: return "Kodak Ektar 100"
        case .kodakPortra800: return "Kodak Portra 800"
        case .fujiSuperiaXTRA400: return "Fuji Superia X-TRA 400"
        case .fujiVelvia50: return "Fuji Velvia 50"
        case .fujiSlideProvia100F: return "Fuji Provia 100F"
        case .kodakKodachrome64: return "Kodak Kodachrome 64"
        case .kodakTriX400: return "Kodak Tri-X 400"
        case .ilfordHP5Plus400: return "Ilford HP5 Plus 400"
        case .kodakTMax100: return "Kodak T-Max 100"
        default: return rawValue
        }
    }

    var iso: Float {
        switch self {
        case .fujiC200: return 200
        case .fujiPro400H: return 400
        case .fujiProvia100F: return 100
        case .kodakPortra400: return 400
        case .kodakGold200: return 200
        case .kodakEktar100, .fujiSlideProvia100F, .kodakTMax100: return 100
        case .kodakPortra800: return 800
        case .fujiSuperiaXTRA400, .kodakTriX400, .ilfordHP5Plus400: return 400
        case .fujiVelvia50: return 50
        case .kodakKodachrome64: return 64
        default: return 100 // Simulation presets have no physical film ISO rating.
        }
    }

    /// Compact packaging labels; VoiceOver and capture metadata keep the full name.
    var tileTitle: String {
        if let simulation = rawSimulation { return simulation.displayName }
        switch self {
        case .kodakGold200: return "Gold 200"
        case .kodakEktar100: return "Ektar 100"
        case .kodakPortra800: return "Portra 800"
        case .fujiSuperiaXTRA400: return "Superia X-TRA 400"
        case .fujiVelvia50: return "Velvia 50"
        case .fujiSlideProvia100F: return "Provia 100F"
        case .kodakKodachrome64: return "Kodachrome 64"
        case .kodakTriX400: return "Tri-X 400"
        case .ilfordHP5Plus400: return "HP5 Plus 400"
        case .kodakTMax100: return "T-Max 100"
        default: return displayName
        }
    }

    var lutResourceName: String {
        if let simulation = rawSimulation { return simulation.resourceName }
        switch self {
        case .fujiC200: return "FujiC200"
        case .fujiPro400H: return "FujiPro400H"
        case .fujiProvia100F: return "FujiProvia100F"
        case .kodakPortra400: return "KodakPortra400"
        case .kodakGold200: return "KodakGold200"
        case .kodakEktar100: return "KodakEktar100"
        case .kodakPortra800: return "KodakPortra800"
        case .fujiSuperiaXTRA400: return "FujiSuperiaXTRA400"
        case .fujiVelvia50: return "FujiVelvia50"
        case .fujiSlideProvia100F: return "FujiProvia100F"
        case .kodakKodachrome64: return "KodakKodachrome64"
        case .kodakTriX400: return "KodakTriX400"
        case .ilfordHP5Plus400: return "IlfordHP5Plus400"
        case .kodakTMax100: return "KodakTMax100"
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
        case .kodakGold200: return "00021_000.heic"
        case .kodakEktar100: return "00081_000.heic"
        case .kodakPortra800: return "00088_000.heic"
        case .fujiSuperiaXTRA400: return "00165_000.heic"
        case .fujiVelvia50: return "00044_000.heic"
        case .fujiSlideProvia100F: return "00055_000.heic"
        case .kodakKodachrome64: return "00060_000.heic"
        case .kodakTriX400: return "00135_000.heic"
        case .ilfordHP5Plus400: return "00083_000.heic"
        case .kodakTMax100: return "00069_000.heic"
        default: return nil
        }
    }

    var isMonochrome: Bool {
        switch self {
        case .fujiRawACROS, .kodakTriX400, .ilfordHP5Plus400, .kodakTMax100: return true
        default: return false
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
