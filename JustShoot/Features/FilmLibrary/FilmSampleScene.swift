import Foundation

/// Each scene names one sRGB photograph and its bundled LUT renderings.
enum FilmSampleScene: String, CaseIterable, Sendable {
    case quilter, ranch, roadside, fair, diner, motel
    case ballpark, fruitStand, pinkDiner, hats, boots, orchard
    case park, kimono, wedding, festival, ceremony, teaMaster
    case teaPortrait, wagashi, bamboo, seaSunset, hydrangea, fuji
    case shoppingStreet, asakusa, train, torii, fishMarket, foodStall
    case borough, pier

    var title: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(stringLiteral: rawValue), table: "FilmIntroductions")
    }

    var credit: String {
        switch self {
        case .quilter, .ranch, .roadside, .fair, .diner, .motel,
             .ballpark, .fruitStand, .pinkDiner, .hats, .boots, .orchard:
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
        case .hydrangea: "Man On Mission · CC BY-SA 3.0"
        case .fuji: "DimiTalen"
        case .shoppingStreet, .asakusa: "Asanagi"
        case .train: "James..g · CC BY-SA 4.0"
        case .torii: "Daderot"
        case .fishMarket: "WorldContributor · CC BY-SA 4.0"
        case .foodStall, .pier: "Andy Li"
        case .borough: "Jeong seolah"
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
            [.init(.landscape, .fuji), .init(.forest, .bamboo), .init(.sunset, .seaSunset)]
        case .fujiRawASTIA:
            [.init(.portrait, .park), .init(.fashion, .kimono), .init(.indoor, .teaMaster)]
        case .fujiRawClassicChrome:
            [.init(.documentary, .fishMarket), .init(.street, .shoppingStreet), .init(.travel, .train)]
        case .fujiRawClassicNeg:
            [.init(.street, .train), .init(.family, .festival), .init(.travel, .asakusa)]
        case .fujiRawACROS:
            [.init(.street, .asakusa), .init(.portrait, .teaPortrait), .init(.architecture, .torii)]
        case .fujiC200:
            [.init(.sunny, .asakusa), .init(.portrait, .park), .init(.landscape, .fuji)]
        case .fujiPro400H:
            [.init(.portrait, .teaPortrait), .init(.wedding, .wedding), .init(.fashion, .kimono)]
        case .fujiProvia100F:
            [.init(.travel, .train), .init(.portrait, .park), .init(.landscape, .torii)]
        case .kodakPortra400:
            [.init(.portrait, .quilter), .init(.fashion, .hats), .init(.travel, .roadside)]
        case .kodakGold200:
            [.init(.family, .fair), .init(.sunny, .pinkDiner), .init(.travel, .roadside)]
        case .kodakEktar100:
            [.init(.landscape, .ranch), .init(.travel, .pinkDiner), .init(.stillLife, .boots)]
        case .kodakPortra800:
            [.init(.portrait, .quilter), .init(.indoor, .diner), .init(.night, .motel)]
        case .fujiSuperiaXTRA400:
            [.init(.street, .shoppingStreet), .init(.family, .ceremony), .init(.travel, .torii)]
        case .fujiVelvia50:
            [.init(.landscape, .fuji), .init(.flowers, .hydrangea), .init(.forest, .bamboo)]
        case .fujiSlideProvia100F:
            [.init(.landscape, .seaSunset), .init(.portrait, .park), .init(.stillLife, .wagashi)]
        case .kodakKodachrome64:
            [.init(.travel, .roadside), .init(.street, .fruitStand), .init(.landscape, .ranch)]
        case .kodakTriX400:
            [.init(.street, .fruitStand), .init(.documentary, .fair), .init(.sports, .ballpark)]
        case .ilfordHP5Plus400:
            [.init(.documentary, .foodStall), .init(.indoor, .borough), .init(.travel, .pier)]
        case .kodakTMax100:
            [.init(.architecture, .pinkDiner), .init(.stillLife, .boots), .init(.sunny, .orchard)]
        }
    }
}
