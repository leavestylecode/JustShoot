import Foundation

/// Each scene names one sRGB photograph and its bundled LUT renderings.
enum FilmSampleScene: String, CaseIterable, Sendable {
    case quilter, ranch, roadside, fair, diner, motel
    case ballpark, fruitStand, pinkDiner, boots, orchard
    case park, kimono, wedding, festival, ceremony, teaMaster
    case teaPortrait, wagashi, bamboo, seaSunset, fuji
    case shoppingStreet, asakusa, train, torii, fishMarket, foodStall
    case pier, lambStreet, cullumStreet
    case rainCyclist, shirakawaSnow, asakusaClouds
    case haydenSnow, trinidadSunset, timesSquareWedding, yorkvilleClouds
    case suttonRain

    var title: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(stringLiteral: rawValue), table: "FilmIntroductions")
    }

    var credit: String {
        switch self {
        case .quilter, .ranch, .roadside, .fair, .diner, .motel,
             .ballpark, .fruitStand, .pinkDiner, .boots, .orchard:
            "Carol M. Highsmith"
        case .park: "HAGAT hOMSZE"
        case .kimono: "Redd Angelo"
        case .wedding: "Jon Connell · CC BY 2.0"
        case .festival: "Torsodog · CC BY-SA 3.0"
        case .ceremony: "MIKI Yoshihito · CC BY 2.0"
        case .teaMaster: "KuboBella · CC BY-SA 4.0"
        case .teaPortrait: "Olivier Lejade · CC BY-SA 2.0"
        case .wagashi: "rhosoi · CC BY 2.0"
        case .bamboo: "Ståle Grut"
        case .seaSunset: "Maarten Heerlien · CC BY 2.0"
        case .fuji: "DimiTalen"
        case .shoppingStreet, .asakusa: "Asanagi"
        case .train: "James..g · CC BY-SA 4.0"
        case .torii: "Daderot"
        case .fishMarket: "WorldContributor · CC BY-SA 4.0"
        case .foodStall, .pier: "Andy Li"
        case .lambStreet: "beareye2010"
        case .cullumStreet: "Robert von Oliva (naruciakk)"
        case .rainCyclist: "Nesnad"
        case .shirakawaSnow: "雷太 · CC BY 2.0"
        case .suttonRain: "A P Monblat · CC BY-SA 4.0"
        case .haydenSnow: "Jacob W. Frank"
        case .trinidadSunset: "Alexey Komarov · CC BY-SA 4.0"
        case .timesSquareWedding: "Cpt. Angela Webb, U.S. Air Force"
        case .yorkvilleClouds: "Leif Knutsen · CC BY-SA 3.0"
        case .asakusaClouds: "Daniel L. Lu · CC BY-SA 4.0"
        }
    }

    func filename(gradedWith preset: FilmPreset? = nil) -> String {
        if let preset { return "vault-\(rawValue)-\(preset.rawValue).heic" }
        return "vault-\(rawValue).jpg"
    }
}

struct FilmRecommendation: Identifiable {
    let tag: FilmSceneTag
    let scene: FilmSampleScene
    var id: FilmSceneTag { tag }

    init(_ tag: FilmSceneTag, _ scene: FilmSampleScene) {
        self.tag = tag
        self.scene = scene
    }
}

extension FilmPreset {
    var recommendations: [FilmRecommendation] {
        switch self {
        case .fujiRawVelvia:
            [.init(.landscape, .fuji), .init(.sunset, .seaSunset), .init(.sunny, .asakusa),
             .init(.architecture, .torii), .init(.snow, .shirakawaSnow)]
        case .fujiRawASTIA:
            [.init(.portrait, .park), .init(.wedding, .wedding), .init(.cloudy, .asakusaClouds),
             .init(.documentary, .teaMaster), .init(.street, .kimono)]
        case .fujiRawClassicChrome:
            [.init(.documentary, .fishMarket), .init(.street, .shoppingStreet), .init(.cloudy, .asakusaClouds),
             .init(.architecture, .torii), .init(.portrait, .teaPortrait)]
        case .fujiRawClassicNeg:
            [.init(.street, .kimono), .init(.sunny, .train), .init(.documentary, .festival),
             .init(.portrait, .park), .init(.stillLife, .wagashi)]
        case .fujiRawACROS:
            [.init(.street, .asakusa), .init(.architecture, .torii), .init(.portrait, .teaPortrait),
             .init(.documentary, .fishMarket), .init(.landscape, .fuji)]
        case .fujiC200:
            [.init(.sunny, .asakusa), .init(.portrait, .ceremony), .init(.street, .shoppingStreet),
             .init(.landscape, .fuji), .init(.architecture, .torii)]
        case .fujiPro400H:
            [.init(.wedding, .wedding), .init(.portrait, .teaPortrait), .init(.cloudy, .asakusaClouds),
             .init(.documentary, .teaMaster), .init(.landscape, .bamboo)]
        case .fujiProvia100F:
            [.init(.landscape, .fuji), .init(.portrait, .park), .init(.sunny, .train),
             .init(.architecture, .torii), .init(.stillLife, .wagashi)]
        case .kodakPortra400:
            [.init(.portrait, .quilter), .init(.wedding, .timesSquareWedding), .init(.cloudy, .yorkvilleClouds),
             .init(.documentary, .diner), .init(.landscape, .ranch)]
        case .kodakGold200:
            [.init(.sunny, .pinkDiner), .init(.portrait, .fair), .init(.sunset, .trinidadSunset),
             .init(.street, .fruitStand), .init(.landscape, .ranch)]
        case .kodakEktar100:
            [.init(.landscape, .ranch), .init(.sunset, .trinidadSunset), .init(.sunny, .pinkDiner),
             .init(.architecture, .roadside), .init(.stillLife, .boots)]
        case .kodakPortra800:
            [.init(.portrait, .diner), .init(.night, .motel), .init(.wedding, .timesSquareWedding),
             .init(.documentary, .ballpark), .init(.street, .fruitStand)]
        case .fujiSuperiaXTRA400:
            [.init(.street, .shoppingStreet), .init(.documentary, .festival), .init(.portrait, .ceremony),
             .init(.rainy, .rainCyclist), .init(.cloudy, .asakusaClouds)]
        case .fujiVelvia50:
            [.init(.landscape, .bamboo), .init(.sunset, .seaSunset), .init(.sunny, .asakusa),
             .init(.stillLife, .wagashi), .init(.architecture, .torii)]
        case .fujiSlideProvia100F:
            [.init(.landscape, .fuji), .init(.snow, .shirakawaSnow), .init(.portrait, .park),
             .init(.sunset, .seaSunset), .init(.stillLife, .wagashi)]
        case .kodakKodachrome64:
            [.init(.documentary, .fruitStand), .init(.sunny, .orchard), .init(.landscape, .ranch),
             .init(.architecture, .pinkDiner), .init(.sunset, .trinidadSunset)]
        case .kodakTriX400:
            [.init(.documentary, .ballpark), .init(.street, .fruitStand), .init(.portrait, .quilter),
             .init(.cloudy, .fair), .init(.architecture, .pinkDiner)]
        case .ilfordHP5Plus400:
            [.init(.documentary, .foodStall), .init(.street, .lambStreet), .init(.rainy, .suttonRain),
             .init(.architecture, .cullumStreet), .init(.landscape, .pier)]
        case .kodakTMax100:
            [.init(.architecture, .pinkDiner), .init(.landscape, .ranch), .init(.snow, .haydenSnow),
             .init(.stillLife, .boots), .init(.portrait, .quilter)]
        }
    }
}
