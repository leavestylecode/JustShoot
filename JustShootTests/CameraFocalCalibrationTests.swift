import XCTest
@testable import JustShoot

final class CameraFocalCalibrationTests: XCTestCase {
    func testInvalidNominalAndUnknownFieldOfViewDoNotInventMillimeters() {
        for value: Float in [0, -1, .nan, .infinity] {
            XCTAssertNil(CameraFocalCalibration.nominal(value))
            XCTAssertNil(CameraFocalCalibration.estimate(horizontalFieldOfView: value, width: 4_000, height: 3_000))
        }
        XCTAssertNil(CameraFocalCalibration.estimate(horizontalFieldOfView: 180, width: 4_000, height: 3_000))
        XCTAssertNil(CameraFocalCalibration.estimate(horizontalFieldOfView: 70, width: 0, height: 3_000))
    }

    func testFormatEstimateUsesDiagonalAndPreservesItsProvenance() throws {
        // Invert the projection for unlike lenses; a single hard-coded main-camera
        // value would collapse all of these anchors and corrupt telephoto zoom.
        for mm: Float in [13, 24, 26, 28, 52, 77, 100, 120] {
            let diagonal = sqrt(36.0 * 36 + 24.0 * 24)
            let fov = Float(2 * atan(diagonal / (2 * Double(mm) * 1.25)) * 180 / .pi)
            let result = try XCTUnwrap(CameraFocalCalibration.estimate(horizontalFieldOfView: fov,
                width: 4_000, height: 3_000))
            XCTAssertEqual(result.millimeters, mm, accuracy: 0.001)
            XCTAssertEqual(result.source, .fieldOfView)
            XCTAssertEqual(CameraFocalCalibration.nominal(mm)?.source, .systemNominal)
        }
    }

    func testSwitchOverOrderingAndBoundsStayAttachedToTheirLens() {
        XCTAssertTrue(DeviceFocalInfo.validAnchors([13, 24, 100], switchOvers: [2, 8], maxZoom: 40))
        XCTAssertTrue(DeviceFocalInfo.validAnchors([26], switchOvers: [], maxZoom: 8))
        XCTAssertTrue(DeviceFocalInfo.validAnchors([28, 52], switchOvers: [2], maxZoom: 10))
        XCTAssertFalse(DeviceFocalInfo.validAnchors([24, 13, 100], switchOvers: [2, 8], maxZoom: 40))
        XCTAssertFalse(DeviceFocalInfo.validAnchors([13, 24, 100], switchOvers: [8, 2], maxZoom: 40))
        XCTAssertFalse(DeviceFocalInfo.validAnchors([13, 24, 100], switchOvers: [2], maxZoom: 40))
        XCTAssertFalse(DeviceFocalInfo.validAnchors([13, 24], switchOvers: [8], maxZoom: 4))
        XCTAssertFalse(DeviceFocalInfo.validAnchors([.nan], switchOvers: [], maxZoom: 4))
    }

    func testEstimatedOptionKeepsProvenanceWithPlainLabelAndStableSelectionIdentity() {
        let estimate = FocalLengthOption(26, isNative: true, isApproximate: true)
        XCTAssertEqual(estimate.label, "26")
        XCTAssertTrue(estimate.isApproximate)
        XCTAssertEqual(estimate, FocalLengthOption(26))
        XCTAssertEqual(Set([estimate, FocalLengthOption(26)]).count, 1)
        XCTAssertEqual(FocalLengthOption(24).label, "24")
    }
}
