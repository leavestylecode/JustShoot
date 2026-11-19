import SwiftUI

/// Packaging specs and swatches sampled from the bundled artwork with the original
/// detail page's corner-color sampler. Opening a film requires no palette extraction.
struct FilmCoverDetails {
    let brand: String
    let swatch: UInt32
    var format: String?
    var process: String?

    private var red: Double { Double((swatch >> 16) & 255) / 255 }
    private var green: Double { Double((swatch >> 8) & 255) / 255 }
    private var blue: Double { Double(swatch & 255) / 255 }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension FilmPreset {
    var introduction: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(stringLiteral: id), table: "FilmIntroductions")
    }

    var coverDetails: FilmCoverDetails {
        switch self {
        case .fujiRawVelvia: .init(brand: "Fujifilm", swatch: 0x089138)
        case .fujiVelvia50: .init(brand: "Fujifilm", swatch: 0x089138, format: "35mm", process: "E-6")
        case .fujiProvia100F: .init(brand: "Fujifilm", swatch: 0x068B3B)
        case .fujiSlideProvia100F: .init(brand: "Fujifilm", swatch: 0x068B3B, format: "35mm", process: "E-6")
        case .fujiRawASTIA: .init(brand: "Fujifilm", swatch: 0x0D8D3D)
        case .fujiRawClassicChrome: .init(brand: "Fujifilm", swatch: 0xF5B315)
        case .fujiRawClassicNeg: .init(brand: "Fujifilm", swatch: 0x0F882E)
        case .fujiRawACROS: .init(brand: "Fujifilm", swatch: 0x0C9141)
        case .fujiC200: .init(brand: "Fujifilm", swatch: 0xAC1753)
        case .fujiPro400H: .init(brand: "Fujifilm", swatch: 0x079037)
        case .kodakPortra400: .init(brand: "Kodak", swatch: 0x603A9B)
        case .kodakGold200: .init(brand: "Kodak", swatch: 0xF5B409, format: "120", process: "C-41")
        case .kodakEktar100: .init(brand: "Kodak", swatch: 0xF5AD05, format: "35mm", process: "C-41")
        case .kodakPortra800: .init(brand: "Kodak", swatch: 0xF5B703, format: "35mm", process: "C-41")
        case .fujiSuperiaXTRA400: .init(brand: "Fujifilm", swatch: 0x049F2D, format: "35mm", process: "C-41")
        case .kodakKodachrome64: .init(brand: "Kodak", swatch: 0xDA0F0F, format: "35mm", process: "K-14")
        case .kodakTriX400: .init(brand: "Kodak", swatch: 0xF5BB06, format: "35mm", process: "BW")
        case .ilfordHP5Plus400: .init(brand: "Ilford", swatch: 0x247339, format: "35mm", process: "BW")
        case .kodakTMax100: .init(brand: "Kodak", swatch: 0xF5BD05, format: "120", process: "BW")
        }
    }

    var coverTitle: String {
        switch self {
        case .fujiC200: "C200"
        case .fujiPro400H: "Pro 400H"
        case .kodakPortra400: "Portra 400"
        default: tileTitle
        }
    }
}
