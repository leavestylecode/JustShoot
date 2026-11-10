import XCTest
@testable import JustShoot

final class LivePhotoCaptureStateTests: XCTestCase {
    func testSupportIsNotInferredFromEnablement() {
        let state = LivePhotoCaptureState(supported: true, enabled: false)
        XCTAssertTrue(state.supported)
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
            guard case .failure(.livePhotoUnavailable) = result else { return XCTFail("Unexpected capture outcome") }
        }
        XCTAssertEqual(readyCallbacks, 1)
        XCTAssertEqual(resultCallbacks, 1)
    }
}
