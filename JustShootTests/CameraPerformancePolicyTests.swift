import XCTest
import AVFoundation
@testable import JustShoot

final class CameraPerformancePolicyTests: XCTestCase {
    func testStopInvalidatesQueuedStart() {
        var intent = CameraSessionIntent()
        let start = intent.request(running: true)
        XCTAssertTrue(intent.permitsStart(start))
        _ = intent.request(running: false)
        XCTAssertFalse(intent.wantsRunning)
        XCTAssertFalse(intent.permitsStart(start))
    }

    func testRapidReentryCannotRevivePreviousStartup() {
        var intent = CameraSessionIntent()
        let oldStart = intent.request(running: true)
        _ = intent.request(running: false)
        let newStart = intent.request(running: true)
        XCTAssertFalse(intent.permitsStart(oldStart))
        XCTAssertTrue(intent.permitsStart(newStart))
    }

    func testPreviewRestoresAutomaticBufferNegotiation() {
        let output = AVCaptureVideoDataOutput()
        CameraPerformancePolicy.configurePreviewOutput(output)
        XCTAssertTrue(output.automaticallyConfiguresOutputBufferDimensions)
        XCTAssertTrue(output.alwaysDiscardsLateVideoFrames)
        XCTAssertEqual(output.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? UInt32, kCVPixelFormatType_32BGRA)
    }

    func testLargeWindowCannotCreateUnboundedPreviewTextures() {
        let size = CameraPerformancePolicy.drawableSize(bounds: CGSize(width: 1024, height: 1366), scale: 3)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1280)
        XCTAssertEqual(size.width / size.height, 1024.0 / 1366.0, accuracy: 0.001)
        XCTAssertEqual(CameraPerformancePolicy.drawableSize(bounds: .zero, scale: 3), .zero)
    }

    func testDiffusionPreservesOddSizedEdgesWithQuarterPixelCount() {
        let size = CameraPerformancePolicy.diffusionSize(width: 751, height: 1001)
        XCTAssertEqual(size.width, 376)
        XCTAssertEqual(size.height, 501)
        XCTAssertLessThan(size.width * size.height, 751 * 1001 / 3)
    }

    func testFrameRateDoesNotSelectAnUnsupportedGap() {
        XCTAssertEqual(CameraPerformancePolicy.frameRate(in: [30...30, 120...120]), 30)
        XCTAssertEqual(CameraPerformancePolicy.frameRate(in: [24...60]), 60)
        XCTAssertNil(CameraPerformancePolicy.frameRate(in: [30...60], ceiling: 24))
    }

    func testReversingAnActiveRampAnchorsAtActualZoomInsteadOfTheNewTarget() throws {
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 13.321, targetZoom: 4.1667,
            isRamping: true, animated: true))
        XCTAssertEqual(transition.anchorZoom, 13.321)
        XCTAssertEqual(transition.targetZoom, 4.1667)
        XCTAssertTrue(transition.usesRamp)
        XCTAssertEqual(transition.rate, 16)
    }

    func testRetargetingUsesActualZoomForRateInsteadOfThePreviousUISelection() throws {
        // Hardware is at 12x even though the previous button requested 8.05x.
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 12, targetZoom: 16,
            isRamping: true, animated: true))
        XCTAssertEqual(transition.anchorZoom, 12)
        XCTAssertEqual(transition.rate, 4)
    }

    func testSettledZoomDoesNotGetAnExtraImmediateAssignment() throws {
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 8.05, targetZoom: 16,
            isRamping: false, animated: true))
        XCTAssertNil(transition.anchorZoom)
        XCTAssertTrue(transition.usesRamp)
        XCTAssertEqual(transition.rate, 8)
    }

    func testSelectingCurrentPositionStopsAnOldRampWithoutStartingAnother() throws {
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 8.05, targetZoom: 8.05,
            isRamping: true, animated: true))
        XCTAssertEqual(transition.anchorZoom, 8.05)
        XCTAssertFalse(transition.usesRamp)
    }

    func testNonAnimatedChangeHasOnlyTheRequestedDestination() throws {
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 8.05, targetZoom: 16,
            isRamping: true, animated: false))
        XCTAssertNil(transition.anchorZoom)
        XCTAssertFalse(transition.usesRamp)
        XCTAssertEqual(transition.targetZoom, 16)
    }

    func testInvalidZoomDoesNotReachHardware() {
        XCTAssertNil(CameraZoomTransition(currentZoom: .nan, targetZoom: 16, isRamping: true, animated: true))
        XCTAssertNil(CameraZoomTransition(currentZoom: 8.05, targetZoom: .infinity, isRamping: true, animated: true))
        XCTAssertNil(CameraZoomTransition(currentZoom: 0, targetZoom: 16, isRamping: true, animated: true))
    }
}
