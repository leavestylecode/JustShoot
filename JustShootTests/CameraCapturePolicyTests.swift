import AVFoundation
import XCTest
@testable import JustShoot

final class CameraCapturePolicyTests: XCTestCase {
    func testDefaultsAndExplicitlyDisabledSafeShutter() throws {
        let name = "capture-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let unset = CameraCapturePolicy(defaults: defaults)
        XCTAssertEqual(unset.photoQuality, .standard)
        XCTAssertTrue(unset.safeShutterEnabled)
        defaults.set(false, forKey: "safeShutterLimitEnabled")
        defaults.set(PhotoQuality.maximum.rawValue, forKey: "photoOutputQuality")
        let selected = CameraCapturePolicy(defaults: defaults)
        XCTAssertFalse(selected.safeShutterEnabled)
        XCTAssertEqual(selected.qualityPrioritization, .quality)
    }

    func testMaximumCaptureQualityRespectsOutputCapability() {
        let maximum = CameraCapturePolicy(photoQuality: .maximum, safeShutterEnabled: true)
        XCTAssertEqual(maximum.qualityPrioritization(supportedMax: .quality), .quality)
        XCTAssertEqual(maximum.qualityPrioritization(supportedMax: .balanced), .balanced)
        XCTAssertEqual(maximum.qualityPrioritization(supportedMax: .speed), .speed)
        for quality in [PhotoQuality.high, .standard, .compact] {
            XCTAssertEqual(CameraCapturePolicy(photoQuality: quality, safeShutterEnabled: true)
                .qualityPrioritization(supportedMax: .quality), .balanced)
        }
    }

    func testDisabledSafeShutterUsesFullExposureRangeAndEnabledPolicyClamps() {
        let minimum = CMTime(value: 1, timescale: 1_000)
        let maximum = CMTime(value: 1, timescale: 10)
        let disabled = CameraCapturePolicy(photoQuality: .standard, safeShutterEnabled: false)
        XCTAssertEqual(disabled.exposureDurationCap(focalMm: 200, minimum: minimum, maximum: maximum), maximum)
        let enabled = CameraCapturePolicy(photoQuality: .standard, safeShutterEnabled: true)
        XCTAssertEqual(enabled.exposureDurationCap(focalMm: 200, minimum: minimum, maximum: maximum).seconds, 1.0 / 200, accuracy: 0.000001)
        XCTAssertEqual(enabled.exposureDurationCap(focalMm: 10_000, minimum: minimum, maximum: maximum), minimum)
        XCTAssertEqual(enabled.exposureDurationCap(focalMm: 24, minimum: minimum, maximum: CMTime(value: 1, timescale: 100)), CMTime(value: 1, timescale: 100))
    }
}
