import XCTest
@testable import JustShoot

final class PageLayoutTests: XCTestCase {
    func testHomeKeepsFourReadableColumnsOnBothPortraitIPadSizes() {
        for width in [CGFloat(834), 1032] {
            let contentWidth = min(width, PageLayout.browseWidth) - 48
            XCTAssertEqual(PageLayout.gridColumns(width: contentWidth, minimum: 176, spacing: 14, maximum: 4), 4)
            XCTAssertEqual(PageLayout.gridColumns(width: contentWidth, minimum: 352, spacing: 14, maximum: 4), 2)
        }
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
