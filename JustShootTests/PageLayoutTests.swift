import XCTest
@testable import JustShoot

final class PageLayoutTests: XCTestCase {
    func testHomeAddsReadableColumnsAsIPadWindowWidens() {
        for (width, expected) in [(CGFloat(834), 4), (1032, 5), (1194, 5), (1376, 5)] {
            let columns = PageLayout.homeColumns(width: width, isRegular: true)
            XCTAssertEqual(columns, expected)
            let tileWidth = (min(width, PageLayout.browseWidth) - 48 - CGFloat(columns - 1) * 14) / CGFloat(columns)
            XCTAssertGreaterThanOrEqual(tileWidth, 176)
        }
        XCTAssertEqual(PageLayout.homeColumns(width: 393, isRegular: false), 3)
        XCTAssertEqual(PageLayout.homeColumns(width: 320, isRegular: false), 2)
        XCTAssertEqual(PageLayout.homeColumns(width: 834, isRegular: true, scale: 2), 2)
    }

    func testLandscapeDetailsRequireRoomForBothColumns() {
        XCTAssertTrue(PageLayout.usesLandscapeColumns(in: CGSize(width: 1194, height: 744), isRegular: true))
        for size in [CGSize(width: 834, height: 1094), CGSize(width: 1032, height: 1276), CGSize(width: 600, height: 450)] {
            XCTAssertFalse(PageLayout.usesLandscapeColumns(in: size, isRegular: true))
        }
        XCTAssertFalse(PageLayout.usesLandscapeColumns(in: CGSize(width: 1194, height: 744), isRegular: false))
    }

    func testPhotoDensityUsesAvailableWidthAndStaysMonotonic() {
        for width in [CGFloat(600), 834, 880] {
            let large = GalleryDensity.large.columns(forWidth: width, isRegular: true, accessibilitySize: false)
            let standard = GalleryDensity.standard.columns(forWidth: width, isRegular: true, accessibilitySize: false)
            let small = GalleryDensity.small.columns(forWidth: width, isRegular: true, accessibilitySize: false)
            XCTAssertLessThanOrEqual(large, standard)
            XCTAssertLessThanOrEqual(standard, small)
            XCTAssertLessThanOrEqual(GalleryDensity.small.columns(forWidth: width, isRegular: true, accessibilitySize: true), 2)
        }
        XCTAssertEqual(GalleryDensity.standard.columns(forWidth: 393, isRegular: false, accessibilitySize: false), 4)
        XCTAssertEqual(PageLayout.gridColumns(width: 0, minimum: 100, spacing: 10, maximum: 4), 1)
        XCTAssertEqual(PageLayout.gridColumns(width: .nan, minimum: 100, spacing: 10, maximum: 4), 1)
    }

    func testAccessibilityGridFallsBackToOneFlexibleColumnInNarrowContainers() {
        for width in [CGFloat(292), 345, 552] {
            XCTAssertEqual(PageLayout.gridColumns(width: width, minimum: 624, spacing: 14, maximum: 8), 1)
        }
        XCTAssertEqual(PageLayout.gridColumns(width: 832, minimum: 352, spacing: 14, maximum: 4), 2)
    }
}
