import XCTest
@testable import JustShoot

final class FilmLUTCatalogTests: XCTestCase {
    func testEveryBundledCaptureLUTHasOneEntryAndAnAvailableCover() throws {
        let catalog = try XCTUnwrap(FilmLUTCatalog.availablePresets())
        XCTAssertEqual(catalog.count, 19)
        XCTAssertEqual(Set(catalog), Set(FilmPreset.allCases))
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

    func testCameraSimulationsKeepDistinctCoversFromPhysicalFilms() {
        XCTAssertNotEqual(FilmPreset.fujiVelvia50.libraryCardImage, FilmPreset.fujiRawVelvia.libraryCardImage)
        XCTAssertNotEqual(FilmPreset.fujiSlideProvia100F.libraryCardImage, FilmPreset.fujiProvia100F.libraryCardImage)
    }
}
