import Foundation

/// Each scene names one sRGB photograph and its bundled LUT renderings.
enum FilmSampleScene: String, CaseIterable, Sendable {
    case quilter, ranch, roadside, fair, diner, motel
    case ballpark, fruitStand, pinkDiner, hats, boots, orchard
    case park, kimono, wedding, festival, ceremony, teaMaster
    case teaPortrait, wagashi, bamboo, seaSunset, hydrangea, fuji
    case shoppingStreet, asakusa, train, torii, fishMarket, foodStall
    case borough, pier, lambStreet, cullumStreet

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
        case .lambStreet: "beareye2010"
        case .cullumStreet: "Robert von Oliva (naruciakk)"
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
            [.init(.landscape, .fuji), .init(.forest, .bamboo), .init(.sunset, .seaSunset),
             .init(.flowers, .hydrangea), .init(.architecture, .torii)]
        case .fujiRawASTIA:
            [.init(.portrait, .park), .init(.fashion, .kimono), .init(.teaCeremony, .teaMaster),
             .init(.wedding, .wedding), .init(.childPortrait, .ceremony)]
        case .fujiRawClassicChrome:
            [.init(.documentary, .fishMarket), .init(.street, .shoppingStreet), .init(.trains, .train),
             .init(.architecture, .torii), .init(.portrait, .teaPortrait)]
        case .fujiRawClassicNeg:
            [.init(.trains, .train), .init(.festival, .festival), .init(.streetscape, .asakusa),
             .init(.documentary, .fishMarket), .init(.portrait, .park)]
        case .fujiRawACROS:
            [.init(.street, .asakusa), .init(.portrait, .teaPortrait), .init(.architecture, .torii),
             .init(.documentary, .fishMarket), .init(.teaCeremony, .teaMaster)]
        case .fujiC200:
            [.init(.streetscape, .asakusa), .init(.portrait, .park), .init(.landscape, .fuji),
             .init(.trains, .train), .init(.flowers, .hydrangea)]
        case .fujiPro400H:
            [.init(.portrait, .teaPortrait), .init(.wedding, .wedding), .init(.fashion, .kimono),
             .init(.childPortrait, .ceremony), .init(.flowers, .hydrangea)]
        case .fujiProvia100F:
            [.init(.trains, .train), .init(.portrait, .park), .init(.landscape, .torii),
             .init(.architecture, .asakusa), .init(.stillLife, .wagashi)]
        case .kodakPortra400:
            [.init(.portrait, .quilter), .init(.fashion, .hats), .init(.roadside, .roadside),
             .init(.familyPortrait, .fair), .init(.indoorPortrait, .diner)]
        case .kodakGold200:
            [.init(.familyPortrait, .fair), .init(.streetscape, .pinkDiner), .init(.roadside, .roadside),
             .init(.portrait, .quilter), .init(.landscape, .ranch)]
        case .kodakEktar100:
            [.init(.landscape, .ranch), .init(.streetscape, .pinkDiner), .init(.stillLife, .boots),
             .init(.architecture, .roadside), .init(.market, .fruitStand)]
        case .kodakPortra800:
            [.init(.portrait, .quilter), .init(.indoorPortrait, .diner), .init(.neon, .motel),
             .init(.documentary, .fruitStand), .init(.sports, .ballpark)]
        case .fujiSuperiaXTRA400:
            [.init(.street, .shoppingStreet), .init(.childPortrait, .ceremony), .init(.architecture, .torii),
             .init(.market, .fishMarket), .init(.documentary, .festival)]
        case .fujiVelvia50:
            [.init(.landscape, .fuji), .init(.flowers, .hydrangea), .init(.forest, .bamboo),
             .init(.sunset, .seaSunset), .init(.architecture, .torii)]
        case .fujiSlideProvia100F:
            [.init(.landscape, .seaSunset), .init(.portrait, .park), .init(.stillLife, .wagashi),
             .init(.architecture, .torii), .init(.flowers, .hydrangea)]
        case .kodakKodachrome64:
            [.init(.roadside, .roadside), .init(.market, .fruitStand), .init(.landscape, .ranch),
             .init(.streetscape, .pinkDiner), .init(.portrait, .quilter)]
        case .kodakTriX400:
            [.init(.market, .fruitStand), .init(.documentary, .fair), .init(.sports, .ballpark),
             .init(.portrait, .quilter), .init(.indoorPortrait, .diner)]
        case .ilfordHP5Plus400:
            [.init(.documentary, .foodStall), .init(.market, .borough), .init(.seascape, .pier),
             .init(.street, .lambStreet), .init(.architecture, .cullumStreet)]
        case .kodakTMax100:
            [.init(.architecture, .pinkDiner), .init(.stillLife, .boots), .init(.harvest, .orchard),
             .init(.landscape, .ranch), .init(.portrait, .quilter)]
        }
    }
}
