import SwiftUI
import XCTest
@testable import JustShoot

final class PageLayoutTests: XCTestCase {
    @MainActor
    func testLongCurveNameExpandsItsRowInANarrowList() async throws {
        let suite = "curve-row-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = FilmCurveLibrary(defaults: defaults)
        for preset in CurvePreset.allCases where preset != .none {
            library.setBuiltIn(preset, isVisible: false)
        }
        XCTAssertTrue(library.add(CustomFilmCurve(name: String(repeating: "山间晨光", count: 10))))

        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        let host = UIHostingController(rootView: NavigationStack { FilmCurveLibraryView() }
            .environmentObject(library).appVisualDesign().frame(width: 320))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        func collection(in view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let list = try XCTUnwrap(collection(in: host.view))
        let section = try XCTUnwrap((0..<list.numberOfSections).first { list.numberOfItems(inSection: $0) == 2 })
        let short = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 0, section: section)))
        let long = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 1, section: section)))
        XCTAssertGreaterThanOrEqual(short.bounds.height, 44)
        XCTAssertGreaterThan(long.bounds.height, short.bounds.height)
    }

    func testHomeAddsReadableColumnsAsIPadWindowWidens() {
        for (width, expected) in [(CGFloat(744), 3), (768, 3), (834, 4), (1032, 5), (1194, 6), (1376, 6)] {
            let columns = PageLayout.homeColumns(width: width, isRegular: true)
            XCTAssertEqual(columns, expected)
            let tileWidth = (width - 48 - CGFloat(columns - 1) * 14) / CGFloat(columns)
            XCTAssertGreaterThanOrEqual(tileWidth, 176)
        }
        XCTAssertEqual(PageLayout.homeColumns(width: 393, isRegular: false), 3)
        XCTAssertEqual(PageLayout.homeColumns(width: 320, isRegular: false), 2)
        XCTAssertEqual(PageLayout.homeColumns(width: 834, isRegular: true, scale: 2), 2)
    }

    func testHomeUsesWidthBeyondTheReadingGridLimit() {
        let cappedColumns = PageLayout.homeColumns(width: PageLayout.browseWidth, isRegular: true)
        let fullWidthColumns = PageLayout.homeColumns(width: 1194, isRegular: true)
        XCTAssertGreaterThan(fullWidthColumns, cappedColumns)
        XCTAssertEqual(fullWidthColumns, 6)
    }

    func testLandscapeDetailsRequireRoomForBothColumns() {
        XCTAssertTrue(PageLayout.usesLandscapeColumns(in: CGSize(width: 1194, height: 744), isRegular: true))
        for size in [CGSize(width: 834, height: 1094), CGSize(width: 1032, height: 1276), CGSize(width: 600, height: 450)] {
            XCTAssertFalse(PageLayout.usesLandscapeColumns(in: size, isRegular: true))
        }
        XCTAssertFalse(PageLayout.usesLandscapeColumns(in: CGSize(width: 1194, height: 744), isRegular: false))
    }

    @MainActor
    func testPhotoGridDefaultAdaptsToWidth() {
        for (width, columns) in [(CGFloat(600), 3), (834, 5), (1194, 7)] {
            XCTAssertEqual(SquareGridLayout.defaultColumns(forWidth: width, isRegular: true), columns)
        }
        XCTAssertEqual(SquareGridLayout.defaultColumns(forWidth: 393, isRegular: false), 4)
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
