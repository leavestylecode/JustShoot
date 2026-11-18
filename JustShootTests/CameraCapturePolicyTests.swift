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

    func testOrdinaryPhotoModePrefersSupported24MPOver48MP() {
        let selected = CameraCapturePolicy.automaticPhotoDimensions(from: [
            CMVideoDimensions(width: 4032, height: 3024),
            CMVideoDimensions(width: 8064, height: 6048),
            CMVideoDimensions(width: 5712, height: 4284)
        ])
        XCTAssertEqual(selected?.width, 5712)
        XCTAssertEqual(selected?.height, 4284)
    }

    func test24MPIsNotRequestedWhenDeferredDeliveryIsUnavailable() {
        let selected = CameraCapturePolicy.automaticPhotoDimensions(from: [
            CMVideoDimensions(width: 4032, height: 3024), CMVideoDimensions(width: 5712, height: 4284)
        ], deferredDeliveryEnabled: false)
        XCTAssertEqual(selected?.width, 4032)
        XCTAssertEqual(selected?.height, 3024)
        XCTAssertGreaterThan(CameraCapturePolicy.automaticPhotoFormatScore(from: [CMVideoDimensions(width: 4032, height: 3024)], deferredDeliveryEnabled: false),
            CameraCapturePolicy.automaticPhotoFormatScore(from: [CMVideoDimensions(width: 5712, height: 4284)], deferredDeliveryEnabled: false))
        XCTAssertTrue(CameraCapturePolicy.requiresDeferredDelivery(CMVideoDimensions(width: 5712, height: 4284)))
        XCTAssertFalse(CameraCapturePolicy.requiresDeferredDelivery(CMVideoDimensions(width: 4032, height: 3024)))
    }

    func testDeferredDeliveryRequiresCapabilityPhotosAccessAndStillMode() {
        XCTAssertFalse(CameraCapturePolicy.usesDeferredDelivery(supported: true, photosAuthorized: true, livePhoto: false, highDetailRequested: false))
        XCTAssertTrue(CameraCapturePolicy.usesDeferredDelivery(supported: true, photosAuthorized: true, livePhoto: false, highDetailRequested: true))
        XCTAssertFalse(CameraCapturePolicy.usesDeferredDelivery(supported: false, photosAuthorized: true, livePhoto: false, highDetailRequested: true))
        XCTAssertFalse(CameraCapturePolicy.usesDeferredDelivery(supported: true, photosAuthorized: false, livePhoto: false, highDetailRequested: true))
        XCTAssertFalse(CameraCapturePolicy.usesDeferredDelivery(supported: true, photosAuthorized: true, livePhoto: true, highDetailRequested: true))
    }

    func testAFormatWithOnly12And48MPUsesItsSupportedOrdinarySize() {
        let selected = CameraCapturePolicy.automaticPhotoDimensions(from: [
            CMVideoDimensions(width: 8064, height: 6048), CMVideoDimensions(width: 4032, height: 3024)
        ])
        XCTAssertEqual(selected?.width, 4032)
        XCTAssertEqual(selected?.height, 3024)
    }

    func testOnlyHighResolutionFormatKeepsASupportedSizeInsteadOfInventing24MP() {
        let selected = CameraCapturePolicy.automaticPhotoDimensions(from: [CMVideoDimensions(width: 8064, height: 6048)])
        XCTAssertEqual(selected?.width, 8064)
        XCTAssertEqual(selected?.height, 6048)
    }

    func testPhotoSizeSelectionRejectsInvalidAndNonPhotoAspectRatios() {
        XCTAssertNil(CameraCapturePolicy.automaticPhotoDimensions(from: [
            CMVideoDimensions(width: 0, height: 0), CMVideoDimensions(width: -1, height: 3024),
            CMVideoDimensions(width: 3840, height: 2160)
        ]))
    }

    func testFormatRankingPrefersAnOrdinarySizeOverAMaxOnlyFormat() {
        let ordinary = CameraCapturePolicy.automaticPhotoFormatScore(from: [CMVideoDimensions(width: 5712, height: 4284)])
        let maxOnly = CameraCapturePolicy.automaticPhotoFormatScore(from: [CMVideoDimensions(width: 8064, height: 6048)])
        let invalid = CameraCapturePolicy.automaticPhotoFormatScore(from: [])
        XCTAssertGreaterThan(ordinary, maxOnly)
        XCTAssertGreaterThan(maxOnly, invalid)
        XCTAssertGreaterThan(CameraCapturePolicy.automaticPhotoFormatScore(from: [CMVideoDimensions(width: 8000, height: 6000)]), maxOnly)
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
