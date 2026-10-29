import AVFoundation
import XCTest
@testable import JustShoot

final class CameraCapturePolicyTests: XCTestCase {
    func testLegacyQualityPreferenceCannotRestoreMaximumCapture() throws {
        let name = "capture-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(CameraCapturePolicy(defaults: defaults).safeShutterEnabled)
        for oldQuality in ["maximum", "high", "standard", "compact"] {
            defaults.set(oldQuality, forKey: "photoOutputQuality")
            XCTAssertEqual(CameraCapturePolicy(defaults: defaults).qualityPrioritization, .quality)
        }
        defaults.set(false, forKey: "safeShutterLimitEnabled")
        XCTAssertFalse(CameraCapturePolicy(defaults: defaults).safeShutterEnabled)
    }

    func testAutomaticCaptureRespectsOutputCapability() {
        let policy = CameraCapturePolicy(safeShutterEnabled: true)
        XCTAssertEqual(policy.qualityPrioritization(supportedMax: .quality), .quality)
        XCTAssertEqual(policy.qualityPrioritization(supportedMax: .balanced), .balanced)
        XCTAssertEqual(policy.qualityPrioritization(supportedMax: .speed), .speed)
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
        XCTAssertTrue(CameraCapturePolicy.requiresDeferredDelivery(CMVideoDimensions(width: 5712, height: 4284)))
        XCTAssertFalse(CameraCapturePolicy.requiresDeferredDelivery(CMVideoDimensions(width: 4032, height: 3024)))
    }

    func testDeferredDeliveryRequiresCapabilityPhotosAccessAndStillMode() {
        XCTAssertTrue(CameraCapturePolicy.usesDeferredDelivery(supported: true, photosAuthorized: true, livePhoto: false))
        XCTAssertFalse(CameraCapturePolicy.usesDeferredDelivery(supported: false, photosAuthorized: true, livePhoto: false))
        XCTAssertFalse(CameraCapturePolicy.usesDeferredDelivery(supported: true, photosAuthorized: false, livePhoto: false))
        XCTAssertFalse(CameraCapturePolicy.usesDeferredDelivery(supported: true, photosAuthorized: true, livePhoto: true))
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

    func testDisabledSafeShutterUsesFullExposureRangeAndEnabledPolicyClamps() {
        let minimum = CMTime(value: 1, timescale: 1_000)
        let maximum = CMTime(value: 1, timescale: 10)
        let disabled = CameraCapturePolicy(safeShutterEnabled: false)
        XCTAssertEqual(disabled.exposureDurationCap(focalMm: 200, minimum: minimum, maximum: maximum), maximum)
        let enabled = CameraCapturePolicy(safeShutterEnabled: true)
        XCTAssertEqual(enabled.exposureDurationCap(focalMm: 200, minimum: minimum, maximum: maximum).seconds, 1.0 / 200, accuracy: 0.000001)
        XCTAssertEqual(enabled.exposureDurationCap(focalMm: 10_000, minimum: minimum, maximum: maximum), minimum)
        XCTAssertEqual(enabled.exposureDurationCap(focalMm: 24, minimum: minimum, maximum: CMTime(value: 1, timescale: 100)), CMTime(value: 1, timescale: 100))
    }
}
