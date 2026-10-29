import XCTest
@testable import JustShoot

final class CameraExposurePolicyTests: XCTestCase {
    @MainActor
    func testContinuousMeteringAndAdjustmentEndPreserveUserEV() {
        let manager = CameraManager()
        manager.exposureBias = 0.8
        manager.beginExposureAdjustment()
        manager.restoreContinuousFocus()
        XCTAssertEqual(manager.exposureBias, 0.8)
        manager.endExposureAdjustment()
        manager.restoreContinuousFocus()
        XCTAssertEqual(manager.exposureBias, 0.8)
    }

    func testRecommendedRangeIsSharedAndBoundedByHardware() {
        let range = CameraExposureRange(minimum: -3, maximum: 2, recommended: -2...3)
        XCTAssertEqual(range.bounds, -2...2)
        XCTAssertEqual(range.clamp(3), 2)
        XCTAssertNil(range.clamp(.nan))
    }

    func testAsymmetricRangeKeepsZeroCenteredAndEndpointsVisible() {
        let range = CameraExposureRange(minimum: -2, maximum: 1)
        XCTAssertEqual(range.fraction(-2), -1)
        XCTAssertEqual(range.fraction(1), 1)
        XCTAssertEqual(range.fraction(0), 0)
        XCTAssertEqual(range.fraction(-1), -0.5)
    }

    func testCoalescingKeepsLatestValueAndStaleCompletionDoesNotReleaseCapture() throws {
        var state = CameraExposureApplication()
        XCTAssertTrue(state.request(0.3))
        let first = try XCTUnwrap(state.takePending())
        XCTAssertTrue(state.request(0.5))
        XCTAssertFalse(state.request(0.8))
        let latest = try XCTUnwrap(state.takePending())
        XCTAssertEqual(latest.bias, 0.8)
        state.acknowledge(first)
        XCTAssertFalse(state.isReady)
        state.acknowledge(latest)
        XCTAssertTrue(state.isReady)
        state.acknowledge(first)
        XCTAssertTrue(state.isReady)
    }

    func testSessionResetRejectsLateAcknowledgementsAndQueuedValues() throws {
        var state = CameraExposureApplication()
        _ = state.request(1)
        let old = try XCTUnwrap(state.takePending())
        state.reset()
        _ = state.request(-1)
        let current = try XCTUnwrap(state.takePending())
        state.acknowledge(old)
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.permits(old))
        state.acknowledge(current)
        XCTAssertTrue(state.isReady)
    }

    func testFailureDoesNotSilentlyAllowOldExposureAndNewRequestCanRecover() throws {
        var state = CameraExposureApplication()
        _ = state.request(1)
        state.fail(try XCTUnwrap(state.takePending()))
        XCTAssertTrue(state.hasFailed)
        XCTAssertFalse(state.isReady)
        _ = state.request(0)
        state.acknowledge(try XCTUnwrap(state.takePending()))
        XCTAssertTrue(state.isReady)
    }
}
