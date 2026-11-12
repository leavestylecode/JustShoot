import XCTest
@testable import JustShoot

final class FilmLUTCatalogTests: XCTestCase {
    private func packaging() throws -> [FilmCard] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cards", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FilmCardBundle.self, from: Data(contentsOf: url)).cards
    }

    func testLibraryHasOneEntryPerBundledCaptureLUTAndStartsWithDefaultNine() throws {
        let available = FilmLUTCatalog.availablePresets()
        XCTAssertEqual(available, Set(FilmPreset.allCases))
        let cards = FilmLUTCatalog.cards(packaging: try packaging(), availablePresets: available)
        XCTAssertEqual(cards.count, 19)
        XCTAssertEqual(Set(cards.map(\.id)).count, cards.count)
        XCTAssertEqual(Set(cards.compactMap(FilmLUTCatalog.preset)), available)
        XCTAssertEqual(cards.prefix(9).compactMap(FilmLUTCatalog.preset), FilmPagePreferences.defaultPresets)
        for card in cards {
            let preset = try XCTUnwrap(FilmLUTCatalog.preset(for: card))
            XCTAssertEqual(card.image, preset.libraryCardImage)
            XCTAssertNil(card.expiry, "Packaging expiry dates do not describe a digital look")
        }
    }

    func testPackagingVariantsAndMissingLUTsNeverBecomeSelectableFilms() throws {
        let cards = FilmLUTCatalog.cards(packaging: try packaging(), availablePresets: [.kodakPortra400, .fujiRawVelvia])
        XCTAssertEqual(cards.map(\.id), [FilmPreset.kodakPortra400.rawValue, FilmPreset.fujiRawVelvia.rawValue])
        XCTAssertTrue(FilmLUTCatalog.cards(packaging: try packaging(), availablePresets: []).isEmpty)
    }

    func testCameraSimulationsKeepDistinctIdentityAndDoNotClaimPhysicalISO() throws {
        let cards = FilmLUTCatalog.cards(packaging: try packaging(), availablePresets: Set(FilmPreset.allCases))
        for card in cards {
            let preset = try XCTUnwrap(FilmLUTCatalog.preset(for: card))
            if preset.rawSimulation != nil { XCTAssertNil(card.iso) }
            else { XCTAssertEqual(card.iso, Int(preset.iso)) }
        }
        let velvias = cards.filter { [FilmPreset.fujiRawVelvia.id, FilmPreset.fujiVelvia50.id].contains($0.id) }
        XCTAssertEqual(Set(velvias.map(\.image)).count, 2)
    }

    func testSmallLibraryFiltersKeepEveryBrandAndTheirCountsReachable() throws {
        let cards = FilmLUTCatalog.cards(packaging: try packaging(), availablePresets: Set(FilmPreset.allCases))
        let index = FilmCardCatalogIndex(cards: cards, includesSmallGroups: true)
        XCTAssertEqual(Set(index.brandChips.map(\.key)), ["Kodak", "Fujifilm", "Ilford"])
        XCTAssertEqual(index.brandChips.reduce(0) { $0 + $1.count }, cards.count)
        let ilford = index.filtered(using: .init(brands: ["Ilford"]))
        XCTAssertEqual(ilford.map(\.id), [FilmPreset.ilfordHP5Plus400.rawValue])
        XCTAssertEqual(index.filtered(using: .init(), query: "portra 800").map(\.id), [FilmPreset.kodakPortra800.rawValue])
    }
}
