import Foundation

extension FilmPreset {
    var styleDescription: LocalizedStringResource {
        switch self {
        case .kodakPortra400: "Soft skin tones · Daylight portraits"
        case .kodakGold200: "Everyday warmth · Sunny days"
        case .fujiPro400H: "Soft colors · Green tones"
        case .fujiC200: "Light, everyday color · Street photography"
        case .kodakEktar100: "Bold colors · Landscapes"
        case .fujiVelvia50: "Vivid greens · Slide film"
        case .ilfordHP5Plus400: "Soft gray tones · Documentary"
        case .kodakTriX400: "Bold black and white · Street photography"
        case .fujiRawClassicChrome: "Muted colors · Documentary"
        case .kodakPortra800: "Warm portraits · Low light"
        case .fujiSuperiaXTRA400: "Everyday color · Mixed light"
        case .fujiSlideProvia100F: "Balanced colors · Slide film"
        case .kodakKodachrome64: "Rich colors · Classic look"
        case .kodakTMax100: "Fine gray tones · Black and white"
        case .fujiProvia100F: "Natural colors · Film simulation"
        case .fujiRawVelvia: "Vivid colors · Film simulation"
        case .fujiRawASTIA: "Soft portraits · Film simulation"
        case .fujiRawClassicNeg: "Bold colors · Film simulation"
        case .fujiRawACROS: "Delicate black and white · Film simulation"
        }
    }
}
