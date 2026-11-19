import Foundation

/// Three shared Library of Congress photographs. Each preview is graded offline
/// with the app's FilmImagePipeline. See research/film-vault/sources.md for credits.
enum FilmSampleScene: String, CaseIterable, Identifiable, Sendable {
    case quilter, ranch, roadside

    var id: Self { self }

    var archiveURL: URL {
        switch self {
        case .quilter: URL(string: "https://www.loc.gov/resource/highsm.07201/")!
        case .ranch: URL(string: "https://www.loc.gov/item/2017685457/")!
        case .roadside: URL(string: "https://www.loc.gov/item/2010630157/")!
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .quilter: "Quilter on a porch"
        case .ranch: "Mountain pasture"
        case .roadside: "Roadside gas station"
        }
    }

    func filename(gradedWith preset: FilmPreset? = nil) -> String {
        if let preset { return "vault-\(rawValue)-\(preset.rawValue).heic" }
        return "vault-\(rawValue).jpg"
    }
}

extension FilmPreset {
    /// Lead with a representative subject. All three originals are shared across looks.
    var sampleScenes: [FilmSampleScene] {
        switch self {
        case .fujiRawASTIA, .fujiPro400H, .kodakPortra400, .kodakPortra800:
            [.quilter, .ranch, .roadside]
        case .fujiRawVelvia, .fujiVelvia50, .fujiSlideProvia100F, .kodakEktar100:
            [.ranch, .roadside, .quilter]
        case .fujiProvia100F, .fujiRawClassicChrome, .fujiRawClassicNeg, .fujiRawACROS,
             .fujiC200, .fujiSuperiaXTRA400, .kodakGold200, .kodakKodachrome64,
             .ilfordHP5Plus400, .kodakTriX400, .kodakTMax100:
            [.roadside, .quilter, .ranch]
        }
    }
}
