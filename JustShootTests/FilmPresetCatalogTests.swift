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

    func testEveryCapturePresetHasFiveDistinctSceneRecommendations() {
        let vocabulary: Set<FilmSceneTag> = [.landscape, .portrait, .street, .documentary, .architecture,
            .wedding, .stillLife, .sunny, .cloudy, .rainy, .snow, .sunset, .night]
        XCTAssertEqual(vocabulary, Set(FilmSceneTag.allCases))
        XCTAssertEqual(vocabulary, Set(FilmPreset.allCases.flatMap { $0.recommendations.map(\.tag) }))
        for preset in FilmPreset.allCases {
            let tags = preset.recommendations.map(\.tag)
            XCTAssertEqual(tags.count, 5, preset.rawValue)
            XCTAssertEqual(Set(tags).count, tags.count, preset.rawValue)
            for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans")] {
                XCTAssertEqual(Set(tags.map { $0.localizedTitle(locale: locale) }).count, 5, preset.id)
            }
        }
    }

    func testCoverDetailsMatchBundledPackaging() throws {
        struct Catalog: Decodable {
            struct Card: Decodable {
                let image: String
                let brand: String?
                let format: String?
                let process: String?
            }
            let cards: [Card]
        }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cards", withExtension: "json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        for preset in FilmPreset.allCases {
            let filename = try XCTUnwrap(preset.libraryCardImage, preset.id)
            XCTAssertNotNil(Bundle.main.url(forResource: filename, withExtension: nil), preset.id)
            let stock = catalog.cards.first { $0.image == filename }
            let details = preset.coverDetails
            if let brand = stock?.brand { XCTAssertEqual(details.brand, brand, preset.id) }
            XCTAssertEqual(details.format, stock?.format, preset.id)
            XCTAssertEqual(details.process, stock?.process, preset.id)
            XCTAssertTrue(preset.displayName.hasSuffix(preset.coverTitle), preset.id)
        }
    }

    func testEachFilmHasItsOwnIntroductionInBothLanguages() {
        var englishIntroductions = Set<String>()
        var chineseIntroductions = Set<String>()
        for preset in FilmPreset.allCases {
            var resource = preset.introduction
            resource.locale = Locale(identifier: "en")
            let english = String(localized: resource)
            resource.locale = Locale(identifier: "zh-Hans")
            let chinese = String(localized: resource)
            XCTAssertFalse([english, chinese].contains(""), preset.id)
            XCTAssertFalse([english, chinese].contains(preset.id), preset.id)
            XCTAssertNotEqual(english, chinese, preset.id)
            XCTAssertTrue(englishIntroductions.insert(english).inserted, preset.id)
            XCTAssertTrue(chineseIntroductions.insert(chinese).inserted, preset.id)
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
        XCTAssertEqual(FilmPreset.fujiRawVelvia.sceneSubtitles(locale: english).full, "Landscape · Sunset · Sunny")
        XCTAssertEqual(FilmPreset.fujiRawVelvia.sceneSubtitles(locale: chinese).full, "风光 · 日落 · 晴天")
        XCTAssertEqual(FilmPreset.kodakGold200.sceneSubtitles(locale: chinese).full, "晴天 · 人像 · 日落")
        XCTAssertEqual(FilmPreset.kodakGold200.sceneSubtitles(locale: english).compact, "Sunny · Portrait")
    }
}
