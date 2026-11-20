import XCTest
@testable import JustShoot

final class FilmLUTCatalogTests: XCTestCase {
    func testCatalogHasSeventeenSelectableLooksWithAvailableCovers() throws {
        let catalog = try XCTUnwrap(FilmLUTCatalog.availablePresets())
        XCTAssertEqual(catalog.count, 17)
        XCTAssertEqual(Set(catalog), Set(FilmPreset.allCases).subtracting([.fujiVelvia50, .fujiSlideProvia100F]))
        XCTAssertEqual(catalog.prefix(9), FilmPagePreferences.defaultPresets[...])
        for preset in catalog {
            let filename = try XCTUnwrap(preset.libraryCardImage)
            XCTAssertNotNil(Bundle.main.url(forResource: filename, withExtension: nil), filename)
        }
    }

    func testPackagingAndMissingLUTsNeverBecomeSelectableFilms() {
        let looks = FilmLUTCatalog.presets(withLUTs: ["00001_000", "KodakPortra400", "FujiRawVelvia"])
        XCTAssertEqual(looks, [.kodakPortra400, .fujiRawVelvia])
        XCTAssertTrue(FilmLUTCatalog.presets(withLUTs: []).isEmpty)
    }

    func testOnlySelectedVelviaAndProviaAppearEvenWithLegacyTablesBundled() {
        let films = FilmLUTCatalog.presets(withLUTs: ["FujiRawVelvia", "FujiVelvia50", "FujiRawPROVIA", "FujiProvia100F"])
        XCTAssertEqual(films, [.fujiRawVelvia, .fujiProvia100F])
        XCTAssertTrue(FilmLUTCatalog.presets(withLUTs: ["FujiVelvia50", "FujiProvia100F"]).isEmpty)
    }
}
