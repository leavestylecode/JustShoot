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

    // MARK: - ExtendedPreviewZoom（活跃镜头区间上限之上的扩展裁切）

    /// 真机实锤场景：低光下主摄被钉在超出自身区间 [2.0, 8.0] 的 zoom 上，预览代理流
    /// 取景钳在区间上限 8.0（100mm）。区间内不裁（预览流自身已缩放），超过后按
    /// zoom/上限补足——200mm(16.0) 恰好 2×，恢复与成片一致的取景。
    func testExtendedCropMatchesPreviewClampBehavior() {
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 1.0, streamCeiling: 8.0), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 4.17, streamCeiling: 8.0), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 8.05, streamCeiling: 8.0), 1.00625, accuracy: 0.0001)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: 8.0), 2)
        // ramp 跨越上限：倍率随 zoom 单调连续（ramp 期间上限恒定）
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 12.0, streamCeiling: 8.0), 1.5, accuracy: 0.0001)
    }

    /// 白天长焦场景：长焦区间直达 maxZoom，zoom 永不超过上限 → 不裁。
    func testExtendedCropInactiveWhenConstituentCoversZoom() {
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: 189.0), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 100.0, streamCeiling: 189.0), 1)
    }

    func testExtendedCropDegenerateInputsDisabled() {
        // 上限未知（无界）或 ≤1 时禁用扩展裁切，行为与原始流完全一致
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: .greatestFiniteMagnitude), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: 0), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: 1), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: -3, streamCeiling: 8.0), 1)
    }
}
