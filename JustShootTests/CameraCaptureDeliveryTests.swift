import AVFoundation
import XCTest
@testable import JustShoot

final class CameraCaptureDeliveryTests: XCTestCase {
    func testMissingRequestedLiveMoviePreservesTheStillAndReportsWarning() {
        let image = Data([1, 2, 3])
        let result = CaptureResult(imageData: image, livePhotoMovieURL: nil,
            photoDisplayTime: .invalid, requestedLive: true)
        XCTAssertEqual(result.imageData, image)
        XCTAssertNil(result.livePhotoMovieURL)
        XCTAssertEqual(result.warning, .livePhotoMovieUnavailable)
    }

    func testOrdinaryStillAndSuccessfulLiveCaptureDoNotReportMovieFailure() {
        let image = Data([1])
        let still = CaptureResult(imageData: image, livePhotoMovieURL: nil, photoDisplayTime: .invalid)
        XCTAssertNil(still.warning)
        let movie = URL(fileURLWithPath: "/tmp/capture-delivery-test.mov")
        let live = CaptureResult(imageData: image, livePhotoMovieURL: movie,
            photoDisplayTime: CMTime(value: 1, timescale: 1), requestedLive: true)
        XCTAssertEqual(live.livePhotoMovieURL, movie)
        XCTAssertNil(live.warning)
    }
}
