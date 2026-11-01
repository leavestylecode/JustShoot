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

    func testCatalogContainsOnlyTheNineRemainingLooks() {
        XCTAssertEqual(Set(FilmPreset.allCases.map(\.rawValue)), [
            "fujiRawVelvia", "fujiRawASTIA", "fujiRawClassicChrome", "fujiRawClassicNeg",
            "fujiRawACROS", "fujiC200", "fujiPro400H", "fujiProvia100F", "kodakPortra400"
        ])
        XCTAssertEqual(Set(FilmPreset.allCases.compactMap(\.rawSimulation)), Set(FujifilmSimulation.allCases))
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
