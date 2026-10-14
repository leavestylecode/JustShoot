import XCTest
@testable import JustShoot

final class CameraLensCaptureGateTests: XCTestCase {
    func testElapsedGraceDoesNotBypassCompletionAndTelephotoLock() {
        var gate = CameraLensCaptureGate()
        gate.begin(zoom: 8.05, graceMs: 150)
        XCTAssertFalse(gate.evaluate(zoom: 8.05, isRamping: false, now: 0))
        XCTAssertFalse(gate.isReady(zoom: 8.05, isRamping: false))
        XCTAssertTrue(gate.evaluate(zoom: 8.05, isRamping: false, now: 0.2))
        // The manager schedules the physical lock synchronously in this completion callback.
        gate.begin(zoom: 8.05, graceMs: 150, hardwarePending: true)
        XCTAssertFalse(gate.isReady(zoom: 8.05, isRamping: false))
        gate.hardwareApplied()
        XCTAssertFalse(gate.evaluate(zoom: 8.05, isRamping: false, now: 1))
        XCTAssertTrue(gate.evaluate(zoom: 8.05, isRamping: false, now: 1.2))
        XCTAssertTrue(gate.isReady(zoom: 8.05, isRamping: false))
    }
    func testTimeoutNeverPermitsOldFocalLengthOrLateHardwareCompletion() {
        var gate = CameraLensCaptureGate()
        gate.begin(zoom: 4.17, graceMs: 150, hardwarePending: true)
        gate.fail()
        gate.hardwareApplied()
        XCTAssertFalse(gate.isReady(zoom: 2.92, isRamping: false))
        XCTAssertFalse(gate.evaluate(zoom: 4.17, isRamping: false, now: 11))
        XCTAssertFalse(gate.isReady(zoom: 4.17, isRamping: false))
        XCTAssertEqual(gate.targetZoom, 4.17)
    }

    func testSameZoomWaitsForHardwareAcknowledgementAndFullGrace() {
        var gate = CameraLensCaptureGate()
        gate.begin(zoom: 8.05, graceMs: 150, hardwarePending: true)
        XCTAssertFalse(gate.evaluate(zoom: 8.05, isRamping: false, now: 1))
        XCTAssertFalse(gate.isReady(zoom: 8.05, isRamping: false))
        gate.hardwareApplied()
        XCTAssertFalse(gate.evaluate(zoom: 8.05, isRamping: false, now: 10))
        XCTAssertFalse(gate.isReady(zoom: 8.05, isRamping: false))
        XCTAssertTrue(gate.evaluate(zoom: 8.05, isRamping: false, now: 10.2))
        XCTAssertTrue(gate.isReady(zoom: 8.05, isRamping: false))
    }

    func testMovementRestartsGraceAndDriftAfterSettleIsRejected() {
        var gate = CameraLensCaptureGate()
        gate.begin(zoom: 4, graceMs: 150)
        XCTAssertFalse(gate.evaluate(zoom: 4, isRamping: false, now: 0))
        XCTAssertFalse(gate.evaluate(zoom: 4, isRamping: true, now: 0.1))
        XCTAssertFalse(gate.evaluate(zoom: 4, isRamping: false, now: 0.2))
        XCTAssertFalse(gate.isReady(zoom: 4, isRamping: false))
        XCTAssertTrue(gate.evaluate(zoom: 4, isRamping: false, now: 0.4))
        XCTAssertFalse(gate.isReady(zoom: 3, isRamping: false))
    }

    func testRetryAndNewSessionDoNotKeepFailedState() {
        var gate = CameraLensCaptureGate()
        gate.begin(zoom: 4, graceMs: 150)
        gate.fail()
        gate.begin(zoom: 3, graceMs: 150)
        XCTAssertFalse(gate.hasFailed)
        XCTAssertFalse(gate.evaluate(zoom: 3, isRamping: false, now: 0))
        XCTAssertTrue(gate.evaluate(zoom: 3, isRamping: false, now: 1))
        gate.reset()
        XCTAssertTrue(gate.isReady(zoom: 1, isRamping: false))
        XCTAssertFalse(gate.isReady(zoom: 1, isRamping: true))
    }
}
