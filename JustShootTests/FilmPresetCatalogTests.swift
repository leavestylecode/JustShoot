import XCTest
@testable import JustShoot

final class FilmPresetCatalogTests: XCTestCase {
    private let retired = [
        "fujiRawRealaAce": "FujiRawREALAACE",
        "fujiRawProNegStd": "FujiRawPRONegStd",
        "fujiRawETERNA": "FujiRawETERNA",
        "fujiRawEternaBB": "FujiRawETERNABB",
        "kodakVision5219": "KodakVision5219",
        "kodakVision5203": "KodakVision5203",
        "kodak5207": "Kodak5207",
        "harmanPhoenix200": "HarmanPhoenix200"
    ]

    func testCatalogPreservesExistingLooksAndAddsMainstreamFilmStocks() {
        XCTAssertEqual(Set(FilmPreset.allCases.map(\.rawValue)), [
            "fujiRawVelvia", "fujiRawASTIA", "fujiRawClassicChrome", "fujiRawClassicNeg",
            "fujiRawACROS", "fujiC200", "fujiPro400H", "fujiProvia100F", "kodakPortra400",
            "kodakGold200", "kodakEktar100", "kodakPortra800", "fujiSuperiaXTRA400",
            "fujiVelvia50", "fujiSlideProvia100F", "kodakKodachrome64", "kodakTriX400",
            "ilfordHP5Plus400", "kodakTMax100"
        ])
        XCTAssertEqual(Set(FilmPreset.allCases.compactMap(\.rawSimulation)), Set(FujifilmSimulation.allCases))
    }

    func testPhysicalSlidesKeepSeparateResourcesFromCameraSimulations() {
        XCTAssertNil(FilmPreset.fujiVelvia50.rawSimulation)
        XCTAssertNil(FilmPreset.fujiSlideProvia100F.rawSimulation)
        XCTAssertNotEqual(FilmPreset.fujiVelvia50.lutResourceName, FilmPreset.fujiRawVelvia.lutResourceName)
        XCTAssertNotEqual(FilmPreset.fujiSlideProvia100F.lutResourceName, FilmPreset.fujiProvia100F.lutResourceName)
    }

    func testBlackAndWhiteStocksNeverAddColoredGrainOrHalation() {
        for preset in FilmPreset.allCases where preset.isMonochrome {
            XCTAssertEqual(preset.renderProfile.grain.chroma, 0, preset.rawValue)
            XCTAssertFalse(preset.renderProfile.optics.isEnabled, preset.rawValue)
            XCTAssertTrue(preset.renderProfile.effectiveChromatic.isNeutral, preset.rawValue)
        }
    }

    func testRetiredLooksHaveNoBundledTablesOrCapturePreset() {
        for (identifier, resource) in retired {
            XCTAssertNil(FilmPreset(rawValue: identifier))
            for suffix in ["cube", "jslut", "jsraw"] {
                XCTAssertNil(Bundle.main.url(forResource: resource, withExtension: suffix), "\(resource).\(suffix)")
            }
        }
    }

    func testEveryCapturePresetHasThreeDistinctSceneRecommendations() {
        let vocabulary = Set(FilmSceneTag.allCases)
        for preset in FilmPreset.allCases {
            XCTAssertEqual(preset.sceneTags.count, 3, preset.rawValue)
            XCTAssertEqual(Set(preset.sceneTags).count, preset.sceneTags.count, preset.rawValue)
            XCTAssertTrue(Set(preset.sceneTags).isSubset(of: vocabulary), preset.rawValue)
        }
    }

    func testSceneVocabularyAndSubtitlesFollowTheRequestedLanguage() {
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")
        for tag in FilmSceneTag.allCases {
            let englishTitle = tag.localizedTitle(locale: english)
            let chineseTitle = tag.localizedTitle(locale: chinese)
            XCTAssertFalse(englishTitle.isEmpty, tag.rawValue)
            XCTAssertFalse(chineseTitle.isEmpty, tag.rawValue)
            XCTAssertNotEqual(englishTitle, chineseTitle, tag.rawValue)
        }
        XCTAssertEqual(FilmPreset.fujiRawVelvia.sceneSubtitle(locale: english), "Sunset · Landscape · Forest")
        XCTAssertEqual(FilmPreset.fujiRawVelvia.sceneSubtitle(locale: chinese), "日落 · 风光 · 森林")
        XCTAssertEqual(FilmPreset.kodakPortra400.sceneSubtitle(locale: chinese), "人像 · 逆光 · 日落")
    }
}
