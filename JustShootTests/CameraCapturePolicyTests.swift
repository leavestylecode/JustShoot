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
        ], deferredDeliverySupported: true, photosAuthorized: true, mode: .quality)
        XCTAssertEqual(delivery.dimensions?.width, 8064)
        XCTAssertEqual(delivery.dimensions?.height, 6048)
        XCTAssertFalse(delivery.deferred)
    }

    func testStillModeUsesDeferred24MPWhenItIsTheLargestAvailableSize() {
        let delivery = CameraCapturePolicy.photoDelivery(from: [
            CMVideoDimensions(width: 4032, height: 3024),
            CMVideoDimensions(width: 5712, height: 4284)
        ], deferredDeliverySupported: true, photosAuthorized: true, mode: .quality)

        XCTAssertEqual(delivery.dimensions?.width, 5712)
        XCTAssertEqual(delivery.dimensions?.height, 4284)
        XCTAssertTrue(delivery.deferred)
    }

    func testDeferred24MPFallsBackWithoutCapabilityPhotosAccessOrStillMode() {
        let dimensions = [CMVideoDimensions(width: 4032, height: 3024), CMVideoDimensions(width: 5712, height: 4284)]
        let cases: [(Bool, Bool, PhotoCaptureMode)] = [
            (false, true, .quality), (true, false, .quality), (true, true, .livePhoto),
            (false, true, .hdr), (true, false, .hdr)
        ]
        for (supported, authorized, mode) in cases {
            let delivery = CameraCapturePolicy.photoDelivery(from: dimensions,
                deferredDeliverySupported: supported, photosAuthorized: authorized, mode: mode)
            XCTAssertEqual(delivery.dimensions?.width, 4032)
            XCTAssertEqual(delivery.dimensions?.height, 3024)
            XCTAssertFalse(delivery.deferred)
        }
    }

    func testLivePhotoUsesTheLargestDirectSize() {
        let delivery = CameraCapturePolicy.photoDelivery(from: [
            CMVideoDimensions(width: 8064, height: 6048),
            CMVideoDimensions(width: 4032, height: 3024)
        ], deferredDeliverySupported: true, photosAuthorized: true, mode: .livePhoto)
        XCTAssertEqual(delivery.dimensions?.width, 8064)
        XCTAssertEqual(delivery.dimensions?.height, 6048)
        XCTAssertFalse(delivery.deferred)
    }

    func testHDRPrefersDeferred24MPAndBoundsTheDirectRAWSize() {
        let native = CMVideoDimensions(width: 4032, height: 3024)
        let deferred = CMVideoDimensions(width: 5712, height: 4284)
        let full = CMVideoDimensions(width: 8064, height: 6048)
        let small = CMVideoDimensions(width: 2048, height: 1536)
        let dimensions = [deferred, full, small, native]
        let delivery = CameraCapturePolicy.photoDelivery(from: dimensions,
            deferredDeliverySupported: true, photosAuthorized: true, mode: .hdr)
        XCTAssertEqual(delivery.dimensions?.width, deferred.width)
        XCTAssertEqual(delivery.dimensions?.height, deferred.height)
        XCTAssertTrue(delivery.deferred)
        let direct = CameraCapturePolicy.photoDelivery(from: [full, small, native],
            deferredDeliverySupported: true, photosAuthorized: true, mode: .hdr)
        XCTAssertEqual(direct.dimensions?.width, full.width, "The direct output also serves SDR fallback")
        XCTAssertFalse(direct.deferred)
        XCTAssertEqual(CameraCapturePolicy.hdrPhotoDimensions(from: dimensions, outputMaximum: full)?.width, native.width)
        XCTAssertEqual(CameraCapturePolicy.hdrPhotoDimensions(from: dimensions, outputMaximum: small)?.width, small.width)
        XCTAssertNil(CameraCapturePolicy.hdrPhotoDimensions(from: [deferred, full], outputMaximum: full))
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
