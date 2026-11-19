import Foundation

/// Background reading for the style description and scene recommendations.
struct FilmGuideSources {
    let manufacturer: URL
    let community: URL

    fileprivate init(manufacturer: StaticString, community: StaticString) {
        self.manufacturer = URL(string: manufacturer.description)!
        self.community = URL(string: community.description)!
    }
}

extension FilmPreset {
    var guideSources: FilmGuideSources {
        switch self {
        case .fujiProvia100F, .fujiRawVelvia, .fujiRawASTIA, .fujiRawClassicChrome, .fujiRawACROS:
            .init(manufacturer: "https://www.fujifilm-x.com/en-gb/learning-centre/get-to-grips-with-film-simulation-modes/",
                  community: "https://www.imaging-resource.com/news/fujifilm-film-simulations-definitive-guide/")
        case .fujiRawClassicNeg:
            .init(manufacturer: "https://www.fujifilm-x.com/en-gb/learning-centre/get-to-grips-with-film-simulation-modes/",
                  community: "https://measuringlight.com/2024/02/26/trips-23-taiwan-with-fuji-x-pro3-pro-photographers/")
        case .fujiC200:
            .init(manufacturer: "https://asset.fujifilm.com/www/sg/files/2020-06/7b2317bdbbac0be303f1939eef501ad5/films_c200_datasheet_01.pdf",
                  community: "https://thedarkroom.com/film/fujicolor-200/")
        case .fujiSuperiaXTRA400:
            .init(manufacturer: "https://asset.fujifilm.com/www/sg/files/2020-06/a3884e16b6de6f1b2f7672c978dcf2f6/films_superia-xtra400_datasheet_01.pdf",
                  community: "https://thedarkroom.com/film/superia-x-tra-400/")
        case .fujiPro400H:
            .init(manufacturer: "https://asset.fujifilm.com/www/sg/files/2020-06/69d42731a2b3b07ebf68191f791c2bca/films_pro-400h_datasheet_01.pdf",
                  community: "https://thedarkroom.com/film/pro400h/")
        case .fujiVelvia50:
            .init(manufacturer: "https://asset.fujifilm.com/www/sg/files/2020-06/0658ca00168258280c0cb6afe5df8754/films_velvia-50_datasheet_01.pdf",
                  community: "https://thedarkroom.com/film/velvia-50/")
        case .fujiSlideProvia100F:
            .init(manufacturer: "https://asset.fujifilm.com/www/sg/files/2020-06/900400ca1f8b7a728587153f75ba792f/films_provia-100f_datasheet_01.pdf",
                  community: "https://thedarkroom.com/film/provia-100f/")
        case .kodakPortra400:
            .init(manufacturer: "https://kodakprofessional.com/sites/default/files/2025-07/e4050.pdf",
                  community: "https://thedarkroom.com/film/portra-400/")
        case .kodakPortra800:
            .init(manufacturer: "https://kodakprofessional.com/sites/default/files/2025-07/e4040.pdf",
                  community: "https://thedarkroom.com/film/portra-800/")
        case .kodakEktar100:
            .init(manufacturer: "https://kodakprofessional.com/sites/default/files/2025-07/e4046.pdf",
                  community: "https://thedarkroom.com/film/ektar-100/")
        case .kodakTriX400:
            .init(manufacturer: "https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4017_TriX.pdf",
                  community: "https://www.35mmc.com/07/02/2020/kodak-tri-x-review/")
        case .kodakTMax100:
            .init(manufacturer: "https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4016_TMax_100.pdf",
                  community: "https://thedarkroom.com/film/tmax/")
        case .kodakGold200:
            .init(manufacturer: "https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/E7022_Gold_200.pdf",
                  community: "https://thedarkroom.com/film/gold-200/")
        case .kodakKodachrome64:
            .init(manufacturer: "https://125px.com/docs/film/kodak/e88-2009_06.pdf",
                  community: "https://casualphotophile.com/2017/10/04/kodachrome-retrospective-film-profile/")
        case .ilfordHP5Plus400:
            .init(manufacturer: "https://www.ilfordphoto.com/hp5-plus-35mm",
                  community: "https://www.35mmc.com/27/01/2026/ilford-hp5-plus-at-a-historical-engine-factory/")
        }
    }
}
