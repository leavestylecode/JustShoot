import XCTest
import UIKit
@testable import JustShoot

final class FilmPresetCoverPreparationTests: XCTestCase {
    func testAwaitedHomePreparationReturnsEveryBundledCoverAtDisplaySize() async throws {
        let covers = try await FilmPresetCoverPreparation.prepareHome(displayScale: 2)
        XCTAssertEqual(Set(covers.keys), Set(FilmPreset.allCases))
        let maximum = FilmCardImageCache.pixelSize(for: FilmPresetCoverPreparation.homePixel(displayScale: 2))
        for preset in FilmPreset.allCases {
            guard let imageName = preset.libraryCardImage else { continue }
            let image = try XCTUnwrap(covers[preset])
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertGreaterThan(cg.width, 0)
            XCTAssertGreaterThan(cg.height, 0)
            XCTAssertLessThanOrEqual(max(cg.width, cg.height), maximum)
            XCTAssertTrue(FilmCardImageCache.shared.cachedImage(imageName: imageName, maxPixel: maximum) === image)
        }
    }

    func testPickerPreparationReturnsItsActualDisplayImages() async throws {
        let covers = try await FilmPresetCoverPreparation.preparePicker(displayScale: 3)
        XCTAssertEqual(Set(covers.keys), Set(FilmPreset.allCases))
        let maximum = FilmCardImageCache.pixelSize(for: FilmPresetCoverPreparation.pickerPixel(displayScale: 3))
        for preset in FilmPreset.allCases {
            guard let imageName = preset.libraryCardImage else { continue }
            let image = try XCTUnwrap(covers[preset])
            XCTAssertTrue(FilmCardImageCache.shared.cachedImage(imageName: imageName, maxPixel: maximum) === image)
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertLessThanOrEqual(max(cg.width, cg.height), maximum)
        }
    }

    func testEveryPresetHasItsOwnCoverInsteadOfBorrowingAnotherLooksArtwork() {
        let names = FilmPreset.allCases.compactMap(\.libraryCardImage)
        XCTAssertEqual(names.count, FilmPreset.allCases.count)
        XCTAssertEqual(Set(names).count, FilmPreset.allCases.count)
    }

    func testCancelledPreparationDoesNotReportAnEmptyReadySnapshot() async {
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await FilmPresetCoverPreparation.prepareHome(displayScale: 2)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(result)
    }

    func testInvalidDisplayScaleCannotOverflowThumbnailDimensions() {
        for scale in [CGFloat.nan, .infinity, -.infinity, 0, -2] {
            XCTAssertEqual(FilmPresetCoverPreparation.homePixel(displayScale: scale), 300)
            XCTAssertEqual(FilmPresetCoverPreparation.pickerPixel(displayScale: scale), 108)
        }
        XCTAssertEqual(FilmPresetCoverPreparation.homePixel(displayScale: 100), 880)
        XCTAssertEqual(FilmPresetCoverPreparation.pickerPixel(displayScale: 100), 432)
    }

    func testCancelledCaptureWarmUpCannotReportResourcesReady() async {
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await FilmProcessor.shared.warmUpForCapture()
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(result)
    }
}
