import AVFoundation
import XCTest
@testable import JustShoot

final class CameraCapturePolicyTests: XCTestCase {
    func testAutomaticCaptureRespectsOutputCapability() {
        XCTAssertEqual(CameraCapturePolicy.qualityPrioritization, .quality)
        XCTAssertEqual(CameraCapturePolicy.qualityPrioritization(supportedMax: .quality), .quality)
        XCTAssertEqual(CameraCapturePolicy.qualityPrioritization(supportedMax: .balanced), .balanced)
        XCTAssertEqual(CameraCapturePolicy.qualityPrioritization(supportedMax: .speed), .speed)
    }

    func testStillModeRequests48MPWhenItIsTheLargestAvailableSize() {
        let delivery = CameraCapturePolicy.photoDelivery(from: [
            CMVideoDimensions(width: 4032, height: 3024),
            CMVideoDimensions(width: 8064, height: 6048),
            CMVideoDimensions(width: 5712, height: 4284)
        ], deferredDeliverySupported: true, photosAuthorized: true, livePhoto: false)
        XCTAssertEqual(delivery.dimensions?.width, 8064)
        XCTAssertEqual(delivery.dimensions?.height, 6048)
        XCTAssertFalse(delivery.deferred)
    }

    func testStillModeUsesDeferred24MPWhenItIsTheLargestAvailableSize() {
        let delivery = CameraCapturePolicy.photoDelivery(from: [
            CMVideoDimensions(width: 4032, height: 3024),
            CMVideoDimensions(width: 5712, height: 4284)
        ], deferredDeliverySupported: true, photosAuthorized: true, livePhoto: false)

        XCTAssertEqual(delivery.dimensions?.width, 5712)
        XCTAssertEqual(delivery.dimensions?.height, 4284)
        XCTAssertTrue(delivery.deferred)
    }

    func testDeferred24MPFallsBackWithoutCapabilityPhotosAccessOrStillMode() {
        let dimensions = [CMVideoDimensions(width: 4032, height: 3024), CMVideoDimensions(width: 5712, height: 4284)]
        for (supported, authorized, live) in [(false, true, false), (true, false, false), (true, true, true)] {
            let delivery = CameraCapturePolicy.photoDelivery(from: dimensions,
                deferredDeliverySupported: supported, photosAuthorized: authorized, livePhoto: live)
            XCTAssertEqual(delivery.dimensions?.width, 4032)
            XCTAssertEqual(delivery.dimensions?.height, 3024)
            XCTAssertFalse(delivery.deferred)
        }
    }

    func testLivePhotoUsesTheLargestDirectSize() {
        let delivery = CameraCapturePolicy.photoDelivery(from: [
            CMVideoDimensions(width: 8064, height: 6048),
            CMVideoDimensions(width: 4032, height: 3024)
        ], deferredDeliverySupported: true, photosAuthorized: true, livePhoto: true)
        XCTAssertEqual(delivery.dimensions?.width, 8064)
        XCTAssertEqual(delivery.dimensions?.height, 6048)
        XCTAssertFalse(delivery.deferred)
    }

    func testPhotoSizeSelectionRejectsInvalidAndNonPhotoAspectRatios() {
        XCTAssertNil(CameraCapturePolicy.automaticPhotoDimensions(from: [
            CMVideoDimensions(width: 0, height: 0), CMVideoDimensions(width: -1, height: 3024),
            CMVideoDimensions(width: 3840, height: 2160)
        ], allowsDeferredDelivery: false))
    }

    func testFormatRankingUsesTheLargestDeliverableSize() {
        let fusionOnly = [CMVideoDimensions(width: 5712, height: 4284)]
        let direct = [CMVideoDimensions(width: 4032, height: 3024)]
        let directScore = CameraCapturePolicy.automaticPhotoFormatScore(from: direct, allowsDeferredDelivery: false)
        let maxScore = CameraCapturePolicy.automaticPhotoFormatScore(
            from: [CMVideoDimensions(width: 8064, height: 6048)], allowsDeferredDelivery: false)
        let fusionScore = CameraCapturePolicy.automaticPhotoFormatScore(from: fusionOnly, allowsDeferredDelivery: true)
        XCTAssertGreaterThan(maxScore, fusionScore)
        XCTAssertGreaterThan(fusionScore, directScore)
        XCTAssertGreaterThan(directScore,
            CameraCapturePolicy.automaticPhotoFormatScore(from: fusionOnly, allowsDeferredDelivery: false))
    }

    func testSafeShutterUsesFocalLengthWithA24mmFloor() {
        let minimum = CMTime(value: 1, timescale: 1_000)
        let maximum = CMTime(value: 1, timescale: 10)
        XCTAssertEqual(CameraCapturePolicy.exposureDurationCap(focalMm: 200, minimum: minimum, maximum: maximum),
            CMTime(value: 1, timescale: 200))
        XCTAssertEqual(CameraCapturePolicy.exposureDurationCap(focalMm: 13, minimum: minimum, maximum: maximum),
            CMTime(value: 1, timescale: 24))
    }

    func testSafeShutterDoesNotExceedTheFormatsExposureRange() {
        let minimum = CMTime(value: 1, timescale: 1_000)
        let maximum = CMTime(value: 1, timescale: 10)
        XCTAssertEqual(CameraCapturePolicy.exposureDurationCap(focalMm: 10_000, minimum: minimum, maximum: maximum), minimum)
        let shortMaximum = CMTime(value: 1, timescale: 100)
        XCTAssertEqual(CameraCapturePolicy.exposureDurationCap(focalMm: 24, minimum: minimum, maximum: shortMaximum), shortMaximum)
    }
}
