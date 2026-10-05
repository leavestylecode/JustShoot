import XCTest
import UIKit
@testable import JustShoot

final class CameraAdjustmentPolicyTests: XCTestCase {
    func testLUTPreparationStartsImmediatelyAfterIdle() {
        var cadence = CameraLUTPreparationCadence()
        XCTAssertEqual(cadence.delay(at: 0), 0)
        cadence.started(at: 0)
        XCTAssertEqual(cadence.delay(at: 1), 0)
    }

    func testReplacingPendingColorRequestDoesNotPostponeItsDeadline() {
        var cadence = CameraLUTPreparationCadence()
        cadence.started(at: 10)
        let deadline = 10 + CameraLUTPreparationCadence.minimumInterval
        // Three cancelled tasks are replaced by newer slider positions before the next frame.
        for arrival in [10.005, 10.015, 10.030] {
            XCTAssertEqual(arrival + cadence.delay(at: arrival), deadline, accuracy: 0.000_001)
        }
        XCTAssertEqual(cadence.delay(at: deadline), 0, accuracy: 0.000_001)
    }

    func testFastDragCoalescesToThirtyPreparationsAndAppliesFinalPosition() {
        var cadence = CameraLUTPreparationCadence()
        var preparedPositions: [Int] = []
        // Simulate 120 Hz touch updates for one second. Only the latest position is prepared.
        for position in 0..<120 {
            let now = Double(position) / 120
            if cadence.delay(at: now) < 0.000_001 {
                cadence.started(at: now)
                preparedPositions.append(position)
            }
        }
        XCTAssertEqual(preparedPositions.count, 30)
        XCTAssertEqual(preparedPositions.last, 116)
        let endedAt = 119.0 / 120
        let finalWait = cadence.delay(at: endedAt)
        XCTAssertLessThanOrEqual(finalWait, CameraLUTPreparationCadence.minimumInterval)
        XCTAssertEqual(cadence.delay(at: endedAt + finalWait), 0, accuracy: 0.000_001)
    }

    func testOpenFilmPickerStillRoutesVerticalDragToExposure() {
        var routing = PreviewGestureRouting()
        XCTAssertEqual(routing.update(horizontal: 3, vertical: 30, allowsFilmSwipe: true), .exposure)
        XCTAssertEqual(routing.update(horizontal: 100, vertical: 40, allowsFilmSwipe: true), .exposure)
    }

    func testFilmSwipeCannotTurnIntoExposureDuringDiagonalTail() {
        var routing = PreviewGestureRouting()
        XCTAssertEqual(routing.update(horizontal: -30, vertical: 3, allowsFilmSwipe: true), .film)
        XCTAssertEqual(routing.update(horizontal: -35, vertical: 100, allowsFilmSwipe: true), .film)
    }

    func testTapJitterAndAmbiguousDiagonalDoNotSelectAnAdjustment() {
        var routing = PreviewGestureRouting()
        XCTAssertEqual(routing.update(horizontal: 4, vertical: 5, allowsFilmSwipe: true), .undecided)
        XCTAssertEqual(routing.update(horizontal: 20, vertical: 20, allowsFilmSwipe: true), .undecided)
        XCTAssertEqual(routing.update(horizontal: 20, vertical: 40, allowsFilmSwipe: true), .exposure)
    }

    func testClosedPickerDoesNotConsumeHorizontalGestureAsFilmSwipe() {
        var routing = PreviewGestureRouting()
        XCTAssertEqual(routing.update(horizontal: 80, vertical: 1, allowsFilmSwipe: false), .undecided)
    }

    func testLandscapeAxesKeepFilmAndExposureOrthogonal() {
        let up = PreviewGestureRouting.axes(for: CGSize(width: 30, height: 0), orientation: .landscapeLeft)
        let sideways = PreviewGestureRouting.axes(for: CGSize(width: 0, height: 30), orientation: .landscapeLeft)
        var exposure = PreviewGestureRouting()
        var film = PreviewGestureRouting()
        XCTAssertEqual(exposure.update(horizontal: up.horizontal, vertical: up.vertical, allowsFilmSwipe: true), .exposure)
        XCTAssertEqual(film.update(horizontal: sideways.horizontal, vertical: sideways.vertical, allowsFilmSwipe: true), .film)
        let opposite = PreviewGestureRouting.axes(for: CGSize(width: -30, height: 0), orientation: .landscapeRight)
        XCTAssertEqual(opposite.vertical, up.vertical)
    }

    func testTemperatureIsFiniteBoundedAndQuantized() {
        XCTAssertNil(CameraWhiteBalancePolicy.temperature(.nan))
        XCTAssertNil(CameraWhiteBalancePolicy.temperature(.infinity))
        XCTAssertEqual(CameraWhiteBalancePolicy.temperature(1_000), 3_000)
        XCTAssertEqual(CameraWhiteBalancePolicy.temperature(20_000), 8_000)
        XCTAssertEqual(CameraWhiteBalancePolicy.temperature(5_249), 5_200)
    }

    func testTintIsFiniteBoundedAndQuantized() {
        XCTAssertNil(CameraWhiteBalancePolicy.tint(.nan))
        XCTAssertNil(CameraWhiteBalancePolicy.tint(.infinity))
        XCTAssertEqual(CameraWhiteBalancePolicy.tint(-200), -30)
        XCTAssertEqual(CameraWhiteBalancePolicy.tint(200), 30)
        XCTAssertEqual(CameraWhiteBalancePolicy.tint(12.4), 12)
        XCTAssertEqual(CameraWhiteBalancePolicy.tint(-12.4), -12)
    }

    func testEachAutomaticAxisKeepsTheOtherManualValue() throws {
        let reading = try XCTUnwrap(CameraWhiteBalanceReading(temperature: 4_800, tint: 12))
        let autoTemperature = try XCTUnwrap(ResolvedCameraColorAdjustment.resolve(
            temperature: .automatic, tint: .value(-10), reading: reading))
        XCTAssertEqual(autoTemperature.temperature, 4_800)
        XCTAssertEqual(autoTemperature.tint, -10)
        let autoTint = try XCTUnwrap(ResolvedCameraColorAdjustment.resolve(
            temperature: .temperature(5_600), tint: .automatic, reading: reading))
        XCTAssertEqual(autoTint.temperature, 5_600)
        XCTAssertEqual(autoTint.tint, 12)
    }

    func testUnavailableReadingDoesNotInventManualReference() {
        XCTAssertNil(ResolvedCameraColorAdjustment.resolve(temperature: .temperature(5_100), tint: .automatic, reading: nil))
        XCTAssertNil(ResolvedCameraColorAdjustment.resolve(temperature: .automatic, tint: .value(10), reading: nil))
        XCTAssertTrue(ResolvedCameraColorAdjustment.resolve(temperature: .automatic, tint: .automatic, reading: nil)?.isNeutral == true)
    }

    func testAutomaticReadingsAreNotClampedToManualControlLimits() throws {
        let reading = try XCTUnwrap(CameraWhiteBalanceReading(temperature: 9_210, tint: 42.4))
        XCTAssertEqual(reading.temperature, 9_200)
        XCTAssertEqual(reading.tint, 42)
        XCTAssertTrue(ResolvedCameraColorAdjustment.resolve(temperature: .automatic, tint: .automatic, reading: reading)?.isNeutral == true)
    }

    func testInvalidStartupGainsAndReadingsAreRejected() {
        XCTAssertFalse(CameraWhiteBalancePolicy.canReadGains(red: 0, green: 0, blue: 0, maximum: 8))
        XCTAssertFalse(CameraWhiteBalancePolicy.canReadGains(red: .nan, green: 1, blue: 1, maximum: 8))
        XCTAssertFalse(CameraWhiteBalancePolicy.canReadGains(red: 9, green: 1, blue: 1, maximum: 8))
        XCTAssertFalse(CameraWhiteBalancePolicy.canReadGains(red: 1, green: 1, blue: 1, maximum: .infinity))
        XCTAssertTrue(CameraWhiteBalancePolicy.canReadGains(red: 2.5, green: 1, blue: 1.5, maximum: 8))
        XCTAssertNil(CameraWhiteBalanceReading(temperature: .nan, tint: 0))
        XCTAssertNil(CameraWhiteBalanceReading(temperature: 0, tint: 0))
        XCTAssertNil(CameraWhiteBalanceReading(temperature: 5_000, tint: .infinity))
    }

    func testReadingGateBoundsOutstandingWorkAndUpdateFrequency() {
        var gate = WhiteBalanceReadingGate()
        XCTAssertTrue(gate.begin(at: 0))
        XCTAssertFalse(gate.begin(at: 1))
        gate.finish()
        XCTAssertFalse(gate.begin(at: 0.2))
        XCTAssertTrue(gate.begin(at: 0.5))
        gate.finish()
        XCTAssertFalse(gate.begin(at: 0.6))
        XCTAssertTrue(gate.begin(at: 1))
    }

}
