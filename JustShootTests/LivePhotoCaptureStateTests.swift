import XCTest
@testable import JustShoot

final class LivePhotoCaptureStateTests: XCTestCase {
    private final class Output: LivePhotoCaptureConfiguring {
        var isLivePhotoCaptureSupported = true
        var storedEnabled = false
        var enableAssignments = 0
        var acceptsEnablement = true
        var isLivePhotoCaptureEnabled: Bool {
            get { storedEnabled }
            set {
                enableAssignments += 1
                if acceptsEnablement { storedEnabled = newValue }
            }
        }
    }

    func testSupportIsNotInferredFromEnablement() {
        let state = LivePhotoCaptureState(supported: true, enabled: false)
        XCTAssertTrue(state.supported)
        XCTAssertFalse(state.canCapture)
    }

    func testFinalConfigurationEnablesSupportedOutput() {
        let output = Output()
        let state = LivePhotoCaptureState.prepare(output)
        XCTAssertTrue(state.canCapture)
        XCTAssertEqual(output.enableAssignments, 1)
    }

    func testAlreadyEnabledOutputAvoidsAnotherPipelineReconfiguration() {
        let output = Output()
        output.storedEnabled = true
        XCTAssertTrue(LivePhotoCaptureState.prepare(output).canCapture)
        XCTAssertEqual(output.enableAssignments, 0)
    }

    func testUnsupportedOutputNeverReceivesAnInvalidEnableAssignment() {
        let output = Output()
        output.isLivePhotoCaptureSupported = false
        XCTAssertFalse(LivePhotoCaptureState.prepare(output).canCapture)
        XCTAssertEqual(output.enableAssignments, 0)
    }

    func testConfigurationCanReenableAfterSupportTemporarilyDisappears() {
        let output = Output()
        XCTAssertTrue(LivePhotoCaptureState.prepare(output).canCapture)
        // Model AVFoundation resetting enablement during format/output negotiation.
        output.isLivePhotoCaptureSupported = false
        output.storedEnabled = false
        XCTAssertFalse(LivePhotoCaptureState.prepare(output).canCapture)
        output.isLivePhotoCaptureSupported = true
        XCTAssertTrue(LivePhotoCaptureState.prepare(output).canCapture)
        XCTAssertEqual(output.enableAssignments, 2)
    }

    func testStateReportsReadbackInsteadOfAssumingEnablementSucceeded() {
        let output = Output()
        output.acceptsEnablement = false
        let state = LivePhotoCaptureState.prepare(output)
        XCTAssertTrue(state.supported)
        XCTAssertFalse(state.enabled)
        XCTAssertFalse(state.canCapture)
    }

    @MainActor
    func testUnavailableLiveRequestFailsWithoutSilentlyTakingAStill() {
        let manager = CameraManager() // No session/input: Live Photo is unavailable.
        defer { manager.stopSession() }
        var readyCallbacks = 0
        var resultCallbacks = 0
        manager.capturePhoto(live: true, onShutterReady: { readyCallbacks += 1 }) { result in
            resultCallbacks += 1
            XCTAssertNil(result)
        }
        XCTAssertEqual(readyCallbacks, 1)
        XCTAssertEqual(resultCallbacks, 1)
    }
}
