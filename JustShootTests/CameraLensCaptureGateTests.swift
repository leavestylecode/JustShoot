import XCTest
@testable import JustShoot

final class CameraLensCaptureGateTests: XCTestCase {
    func testDuplicateSelectionKeepsItsHardwareRequestAndOriginalGrace() {
        var gate = CameraLensCaptureGate()
        let stamp = CameraLensCaptureGate.RequestStamp(generation: 1, focalSequence: 2)
        gate.begin(zoom: 4, graceMs: 150, hardwarePending: true, stamp: stamp)
        XCTAssertTrue(gate.canReuseSelection(generation: 1, zoom: 2, isRamping: true))
        gate.hardwareApplied()
        XCTAssertFalse(gate.evaluate(zoom: 4, isRamping: false, now: 10))
        XCTAssertTrue(gate.canReuseSelection(generation: 1, zoom: 4, isRamping: false))
        XCTAssertTrue(gate.evaluate(zoom: 4, isRamping: false, now: 10.151))
        XCTAssertTrue(gate.isReady(zoom: 4, isRamping: false))
        XCTAssertEqual(gate.requestStamp, stamp)
    }

    func testFailedStaleOrMovedSelectionsRemainEligibleForRetry() {
        var gate = CameraLensCaptureGate()
        XCTAssertFalse(gate.canReuseSelection(generation: 1, zoom: 4, isRamping: false))
        gate.begin(zoom: 4, graceMs: 150, stamp: .init(generation: 1, focalSequence: 1))
        XCTAssertFalse(gate.canReuseSelection(generation: 2, zoom: 4, isRamping: false))
        gate.fail()
        XCTAssertFalse(gate.canReuseSelection(generation: 1, zoom: 4, isRamping: false))
        gate.begin(zoom: 4, graceMs: 0, stamp: .init(generation: 1, focalSequence: 2))
        XCTAssertTrue(gate.evaluate(zoom: 4, isRamping: false, now: 10))
        XCTAssertFalse(gate.canReuseSelection(generation: 1, zoom: 2, isRamping: false))
        XCTAssertFalse(gate.canReuseSelection(generation: 1, zoom: 4, isRamping: true))
        gate.reset()
        XCTAssertFalse(gate.canReuseSelection(generation: 1, zoom: 4, isRamping: false))
    }

    func testPhysicalSourceChangeAfterZoomSettlesRequiresANewFullGrace() {
        let stamp = CameraLensCaptureGate.RequestStamp(generation: 1, focalSequence: 11)
        var gate = CameraLensCaptureGate()
        gate.begin(zoom: 2.05, graceMs: 150, stamp: stamp)
        XCTAssertFalse(gate.evaluate(zoom: 2.05, isRamping: false, now: 0))
        XCTAssertTrue(gate.evaluate(zoom: 2.05, isRamping: false, now: 0.2))
        // The logged late UW -> Wide change happened 80 ms after the original settle.
        XCTAssertTrue(gate.sourceDidChange(stamp: stamp))
        XCTAssertFalse(gate.isReady(zoom: 2.05, isRamping: false))
        XCTAssertFalse(gate.evaluate(zoom: 2.05, isRamping: false, now: 0.28))
        XCTAssertFalse(gate.evaluate(zoom: 2.05, isRamping: false, now: 0.38))
        XCTAssertTrue(gate.evaluate(zoom: 2.05, isRamping: false, now: 0.44))
        XCTAssertTrue(gate.isReady(zoom: 2.05, isRamping: false))
    }

    func testSourceChangeCannotReviveFailedOrSupersededFocalRequests() {
        let old = CameraLensCaptureGate.RequestStamp(generation: 1, focalSequence: 1)
        let next = CameraLensCaptureGate.RequestStamp(generation: 2, focalSequence: 2)
        var gate = CameraLensCaptureGate()
        gate.begin(zoom: 4, graceMs: 150, stamp: old)
        gate.fail()
        XCTAssertFalse(gate.sourceDidChange(stamp: old))
        XCTAssertTrue(gate.hasFailed)
        XCTAssertFalse(gate.isTransitioning)
        gate.begin(zoom: 8, graceMs: 150, hardwarePending: true, stamp: next)
        XCTAssertFalse(gate.sourceDidChange(stamp: old))
        XCTAssertTrue(gate.sourceDidChange(stamp: next))
        XCTAssertFalse(gate.evaluate(zoom: 8, isRamping: false, now: 1))
        gate.hardwareApplied()
        XCTAssertFalse(gate.evaluate(zoom: 8, isRamping: false, now: 2))
        XCTAssertTrue(gate.evaluate(zoom: 8, isRamping: false, now: 2.2))
    }

    func testNativeSourceBarrierClosesBeforeMainActorCallbackAndRejectsOldObservers() {
        let stamp = CameraLensCaptureGate.RequestStamp(generation: 1, focalSequence: 1)
        var source = CameraLensCaptureGate.SourceStability()
        let oldEpoch = source.invalidateObservations()
        let entryRevision = source.revision
        XCTAssertTrue(source.record(stamp: stamp, observationEpoch: oldEpoch, at: 10))
        XCTAssertNotEqual(source.revision, entryRevision)
        XCTAssertEqual(source.remainingGrace(stamp: stamp, at: 10.1), 0.05, accuracy: 0.000001)
        XCTAssertEqual(source.remainingGrace(stamp: stamp, at: 10.151), 0)
        // A second source change restarts the interval, before any main-actor task runs.
        XCTAssertTrue(source.record(stamp: stamp, observationEpoch: oldEpoch, at: 10.12))
        XCTAssertGreaterThan(source.remainingGrace(stamp: stamp, at: 10.2), 0)
        let newEpoch = source.invalidateObservations()
        let resumedRevision = source.revision
        XCTAssertFalse(source.record(stamp: stamp, observationEpoch: oldEpoch, at: 11))
        XCTAssertEqual(source.revision, resumedRevision)
        let resumed = CameraLensCaptureGate.RequestStamp(generation: 2, focalSequence: 1)
        XCTAssertTrue(source.record(stamp: resumed, observationEpoch: newEpoch, at: 11))
        XCTAssertFalse(source.record(stamp: stamp, observationEpoch: newEpoch, at: 11.01))
        XCTAssertEqual(source.remainingGrace(stamp: stamp, at: 11), 0)
        XCTAssertGreaterThan(source.remainingGrace(stamp: resumed, at: 11.1), 0)
    }

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
