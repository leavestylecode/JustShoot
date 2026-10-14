import XCTest
@testable import JustShoot

final class CameraCaptureAdmissionTests: XCTestCase {
    private func begin(_ state: inout CameraCaptureAdmission, generation: UInt64 = 1,
                       focalLength: Int = 35) throws -> CameraCaptureAdmission.Token {
        try XCTUnwrap(state.begin(sessionGeneration: generation, focalSequence: 7,
            focalLength: focalLength, exposureBias: 0.7, flashEnabled: true, rotationAngle: 90))
    }

    func testReservationAlreadyOwnsTheHardwareSlotAndFrozenParameters() throws {
        var state = CameraCaptureAdmission()
        let token = try begin(&state)
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.begin(sessionGeneration: 1, focalSequence: 8, focalLength: 100,
            exposureBias: -1, flashEnabled: false, rotationAngle: 0))
        XCTAssertEqual(state.active?.focalLength, 35)
        XCTAssertEqual(state.active?.exposureBias, 0.7)
        XCTAssertEqual(state.active?.rotationAngle, 90)
        XCTAssertTrue(state.beginPreparation(token, generation: 1))
        XCTAssertFalse(state.beginPreparation(token, generation: 1))
        XCTAssertTrue(state.markIssued(token, generation: 1))
        XCTAssertFalse(state.markIssued(token, generation: 1))
    }

    func testBackgroundingDuringReservationOrFlashDelayRejectsTheOldCapture() throws {
        for preparing in [false, true] {
            var state = CameraCaptureAdmission()
            let token = try begin(&state)
            if preparing { XCTAssertTrue(state.beginPreparation(token, generation: 1)) }
            XCTAssertEqual(state.cancelUnissued(), token)
            XCTAssertFalse(state.permits(token, generation: 2))
            XCTAssertFalse(state.beginPreparation(token, generation: 2))
            XCTAssertFalse(state.markIssued(token, generation: 1))
            let next = try begin(&state, generation: 2, focalLength: 100)
            XCTAssertFalse(state.release(token))
            XCTAssertEqual(state.active, next)
        }
    }

    func testGenerationChangeAloneCannotReviveAWaitingShutterPress() throws {
        var state = CameraCaptureAdmission()
        let token = try begin(&state)
        XCTAssertFalse(state.beginPreparation(token, generation: 2))
        XCTAssertTrue(state.beginPreparation(token, generation: 1))
        XCTAssertFalse(state.markIssued(token, generation: 2))
    }

    func testAnExposedCaptureKeepsItsSlotUntilStillCheckpointCompletes() throws {
        var state = CameraCaptureAdmission()
        let token = try begin(&state)
        XCTAssertTrue(state.beginPreparation(token, generation: 1))
        XCTAssertTrue(state.markIssued(token, generation: 1))
        XCTAssertNil(state.cancelUnissued())
        XCTAssertFalse(state.cancel(token))
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.release(token))
        XCTAssertFalse(state.isBusy)
        _ = try begin(&state, generation: 2)
    }

    @MainActor
    func testInvalidAdmissionFailsSynchronouslyWithoutStartingNativeCapture() throws {
        var state = CameraCaptureAdmission()
        let token = try begin(&state)
        _ = state.cancelUnissued()
        let manager = CameraManager()
        defer { manager.stopSession() }
        var shutterCallbacks = 0
        var resultCallbacks = 0
        manager.capturePhoto(admission: token, onShutterReady: { shutterCallbacks += 1 }) { result in
            resultCallbacks += 1
            XCTAssertNil(result)
        }
        XCTAssertEqual(shutterCallbacks, 1)
        XCTAssertEqual(resultCallbacks, 1)
    }
}
