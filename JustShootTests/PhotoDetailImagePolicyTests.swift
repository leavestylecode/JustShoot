import XCTest
@testable import JustShoot

final class PhotoDetailImagePolicyTests: XCTestCase {
    func testPreviewUsesNativeScreenPixelsInsteadOfOversizingSmallScreens() {
        XCTAssertEqual(PhotoDetailImagePolicy.previewMaxPixel(bounds: CGRect(x: 0, y: 0, width: 375, height: 667), scale: 2), 1334)
        XCTAssertEqual(PhotoDetailImagePolicy.previewMaxPixel(bounds: CGRect(x: 0, y: 0, width: 402, height: 874), scale: 3), 2622)
        XCTAssertEqual(PhotoDetailImagePolicy.previewMaxPixel(bounds: .zero, scale: 3), 2556)
    }

    func testFastJumpKeepsOnlyTheNewCurrentAndAdjacentPreviews() {
        XCTAssertEqual(PhotoDetailImagePolicy.previewRange(count: 100, currentIndex: 0), 0..<2)
        XCTAssertEqual(PhotoDetailImagePolicy.previewRange(count: 100, currentIndex: 50), 49..<52)
        XCTAssertEqual(PhotoDetailImagePolicy.previewRange(count: 100, currentIndex: 99), 98..<100)
        XCTAssertEqual(PhotoDetailImagePolicy.previewRange(count: 100, currentIndex: 100), 0..<0)
        XCTAssertEqual(PhotoDetailImagePolicy.previewRange(count: 0, currentIndex: 0), 0..<0)
        XCTAssertEqual(PhotoDetailImagePolicy.previewRange(count: 1, currentIndex: 0), 0..<1)
    }
}
