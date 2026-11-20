import SwiftUI

/// Packaging specs and swatches sampled from the bundled artwork with the original
/// detail page's corner-color sampler. Opening a film requires no palette extraction.
struct FilmCoverDetails {
    let brand: String
    let swatch: UInt32
    var format: String?
    var process: String?

    private var resolvedSwatch: Color.Resolved {
        Color.Resolved(red: Float((swatch >> 16) & 255) / 255,
                       green: Float((swatch >> 8) & 255) / 255,
                       blue: Float(swatch & 255) / 255)
    }

    var color: Color { Color(resolvedSwatch) }

    private var luminance: Float {
        let rgb = resolvedSwatch
        return 0.2126 * rgb.linearRed + 0.7152 * rgb.linearGreen + 0.0722 * rgb.linearBlue
    }

    var contentScheme: ColorScheme {
        // WCAG contrast of black and white against the unmodified cover color.
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? .light : .dark
    }

    /// The hidden navigation bar leaves the status icons in the app's appearance.
    func statusBarColor(in appScheme: ColorScheme) -> Color {
        let level = luminance
        let target = appScheme == .dark ? min(level, 0.15) : max(level, 0.22)
        guard target != level else { return color }
        let endpoint: Float = appScheme == .dark ? 0 : 1
        let amount = (target - level) / (endpoint - level)
        var rgb = resolvedSwatch
        rgb.linearRed += (endpoint - rgb.linearRed) * amount
        rgb.linearGreen += (endpoint - rgb.linearGreen) * amount
        rgb.linearBlue += (endpoint - rgb.linearBlue) * amount
        return Color(rgb)
    }
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
