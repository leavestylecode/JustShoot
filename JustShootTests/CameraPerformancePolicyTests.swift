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
        XCTAssertEqual(transition.rate, 24)
    }

    func testRetargetingUsesActualZoomForRateInsteadOfThePreviousUISelection() throws {
        // Hardware is at 12x even though the previous button requested 8.05x.
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 12, targetZoom: 16,
            isRamping: true, animated: true))
        XCTAssertEqual(transition.anchorZoom, 12)
        XCTAssertEqual(transition.rate, 8)
    }

    func testSettledZoomDoesNotGetAnExtraImmediateAssignment() throws {
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 8.05, targetZoom: 16,
            isRamping: false, animated: true))
        XCTAssertNil(transition.anchorZoom)
        XCTAssertTrue(transition.usesRamp)
        XCTAssertEqual(transition.rate, 16)
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

    /// 同 constituent 短跳（如 24↔35mm）走高速短 ramp：连续运动消除立即设置的「跳变
    /// 生硬」，高速率让名义速率不成为瓶颈（实际时长由 AVF 加速度上限决定，~200-300ms）。
    func testSameConstituentHopUsesFastRamp() throws {
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 2.05, targetZoom: 2.917,
            isRamping: false, animated: true, fastRamp: true))
        XCTAssertTrue(transition.usesRamp)
        XCTAssertEqual(transition.rate, 32)
        XCTAssertNil(transition.anchorZoom)
        // fastRamp 不改变 anchor/去重语义：ramp 中的重定向仍锚定实际 zoom
        let retarget = try XCTUnwrap(CameraZoomTransition(currentZoom: 2.4, targetZoom: 2.917,
            isRamping: true, animated: true, fastRamp: true))
        XCTAssertEqual(retarget.anchorZoom, 2.4)
        XCTAssertEqual(retarget.rate, 32)
    }

    /// 跨 switchover 维持速率阶梯：系统需要时间从容做 constituent crossfade，不吃高速档。
    func testCrossConstituentKeepsRateLadder() throws {
        let transition = try XCTUnwrap(CameraZoomTransition(currentZoom: 4.167, targetZoom: 8.10,
            isRamping: false, animated: true, fastRamp: false))
        XCTAssertTrue(transition.usesRamp)
        XCTAssertEqual(transition.rate, 16)
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

    // MARK: - PreviewCropCeilingSynchronizer（上限换轨的帧对齐）

    /// 低光 200mm 主摄钉 8.0、光线恢复切回长焦（上限 8.0→16.0）：KVO 触发后帧流仍在
    /// 交付旧镜头内容（33ms 正常节距）→ 裁切分母保持旧值；跨镜头停帧（≥200ms 断裂）
    /// 后的第一帧才换轨——旧内容帧绝不拿到新上限算出的取景。
    func testCeilingChangeHoldsUntilStreamDiscontinuity() {
        var sync = PreviewCropCeilingSynchronizer()
        // 帧流先流动起来（首帧本身视为断裂，不能混进本用例的断言窗口）
        var pts = 0.0
        for _ in 0..<3 {
            pts += 0.033
            XCTAssertNil(sync.frameArrived(pts: pts, at: pts))
        }
        sync.kvCeilingDidChange(to: 16.0, at: 10.0)
        // KVO 已登记新上限，旧镜头内容帧继续到达：分母不动
        for _ in 0..<6 {
            pts += 0.033
            XCTAssertNil(sync.frameArrived(pts: pts, at: 10.0 + pts))
            XCTAssertEqual(sync.renderCeiling, .greatestFiniteMagnitude)
        }
        // 停顿窗口内无帧到达：渲染侧维持旧上限（保持帧重绘不跳取景）
        XCTAssertEqual(sync.renderCeiling, .greatestFiniteMagnitude)
        // 新镜头第一帧：断裂 0.5s → 恰在此帧换轨
        pts += 0.5
        let latch = sync.frameArrived(pts: pts, at: 10.0 + pts)
        XCTAssertEqual(latch?.ceiling, 16.0)
        XCTAssertEqual(latch?.gapSeconds ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sync.renderCeiling, 16.0)
        // 换轨后帧流继续：无重复回执
        pts += 0.033
        XCTAssertNil(sync.frameArrived(pts: pts, at: 10.0 + pts))
        XCTAssertEqual(sync.renderCeiling, 16.0)
    }

    /// 断裂阈值边界：125ms 断裂（<200ms）不生效，375ms 断裂生效。PTS 用二进制
    /// 精确可表示的值（1.0/1.125/1.5），间隔差不带浮点噪声。
    func testFrameGapThresholdBoundary() {
        var sync = PreviewCropCeilingSynchronizer()
        _ = sync.frameArrived(pts: 1.0, at: 1.0)
        sync.kvCeilingDidChange(to: 8.0, at: 1.1)
        XCTAssertNil(sync.frameArrived(pts: 1.125, at: 1.3))
        XCTAssertEqual(sync.renderCeiling, .greatestFiniteMagnitude)
        let latch = sync.frameArrived(pts: 1.5, at: 1.6)
        XCTAssertEqual(latch?.ceiling, 8.0)
    }

    /// 帧流持续无断裂（假想的无缝切换）：按 600ms 年龄兜底接受，上限不会永久滞留。
    func testContinuousStreamAcceptsCeilingByTimeout() {
        var sync = PreviewCropCeilingSynchronizer()
        _ = sync.frameArrived(pts: 0.0, at: 0.0)
        sync.kvCeilingDidChange(to: 2.05, at: 1.0)
        var pts = 0.0
        var latch: PreviewCropCeilingSynchronizer.Latch?
        // 30fps 持续流动 0.6s：全程不换轨……
        for _ in 0..<18 {
            pts += 0.033
            latch = sync.frameArrived(pts: pts, at: 1.0 + pts)
        }
        XCTAssertNil(latch)
        XCTAssertEqual(sync.renderCeiling, .greatestFiniteMagnitude)
        // ……直到帧到达时刻距 KVO 变化 ≥0.6s
        pts += 0.033
        latch = sync.frameArrived(pts: pts, at: 1.0 + pts)
        XCTAssertEqual(latch?.ceiling, 2.05)
        XCTAssertEqual(latch?.gapSeconds ?? 0, 0.033, accuracy: 0.0001)
    }

    /// .restricted 无缝切换（真机日志：UW→Wide 帧流不断裂）：短超时（120ms）内完成换轨——
    /// 长超时会让渲染上限滞留旧值整个窗口，上限升向产生 zoom/旧上限 的虚假裁切
    /// （35mm 显示成 ~50mm、换轨后再跳回，「画面大小来回切换」的根因）。
    func testSeamlessSwitchAcceptsCeilingWithinShortWindow() {
        var sync = PreviewCropCeilingSynchronizer()
        _ = sync.frameArrived(pts: 1.0, at: 1.0)
        sync.kvCeilingDidChange(to: 8.0, at: 2.0, acceptTimeout: PreviewCropCeilingSynchronizer.seamlessAcceptTimeoutSeconds)
        // 在途帧（62.5ms 间隔 < 120ms）：保持旧上限
        XCTAssertNil(sync.frameArrived(pts: 1.0625, at: 2.0625))
        XCTAssertEqual(sync.renderCeiling, .greatestFiniteMagnitude)
        // 125ms ≥ 120ms：换轨生效
        let latch = sync.frameArrived(pts: 1.125, at: 2.125)
        XCTAssertEqual(latch?.ceiling, 8.0)
        XCTAssertEqual(sync.renderCeiling, 8.0)
    }

    /// 系统在边界附近来回切换 constituent（zoom=16 稳态实测超广↔长焦振荡）：
    /// 连续两次 KVO 变化后，断裂处取**最新**登记值。
    func testOscillatingConstituentTakesLatestCeiling() {
        var sync = PreviewCropCeilingSynchronizer()
        _ = sync.frameArrived(pts: 1.0, at: 1.0)
        sync.kvCeilingDidChange(to: 2.05, at: 5.0)
        sync.kvCeilingDidChange(to: 16.0, at: 5.02)
        let latch = sync.frameArrived(pts: 1.5, at: 5.5)
        XCTAssertEqual(latch?.ceiling, 16.0)
        XCTAssertEqual(sync.renderCeiling, 16.0)
    }

    /// 会话重启（reset）后的第一帧视为断裂：启动即低光 200mm 时扩展裁切从第一帧就正确。
    func testFirstFrameAfterResetLatchesImmediately() {
        var sync = PreviewCropCeilingSynchronizer()
        _ = sync.frameArrived(pts: 1.0, at: 1.0)
        sync.kvCeilingDidChange(to: 8.0, at: 1.0)
        // 停顿期间 KVO 已登记，但渲染侧等第一帧新内容
        XCTAssertEqual(sync.renderCeiling, .greatestFiniteMagnitude)
        let resume = sync.frameArrived(pts: 1.5, at: 1.5)
        XCTAssertEqual(resume?.ceiling, 8.0)
        sync.reset()
        XCTAssertEqual(sync.renderCeiling, .greatestFiniteMagnitude)
        sync.kvCeilingDidChange(to: 8.0, at: 2.0)
        // 重启后的第一帧（无历史 PTS）视为断裂，立即换轨
        let first = sync.frameArrived(pts: 5.0, at: 2.0)
        XCTAssertEqual(first?.ceiling, 8.0)
        XCTAssertNil(first?.gapSeconds)
    }

    /// 无 KVO 变化时帧流照常流动，零副作用。
    func testFramesWithoutCeilingChangeAreInert() {
        var sync = PreviewCropCeilingSynchronizer()
        var pts = 0.0
        for _ in 0..<10 {
            pts += 0.033
            XCTAssertNil(sync.frameArrived(pts: pts, at: pts))
        }
        XCTAssertEqual(sync.renderCeiling, .greatestFiniteMagnitude)
    }
}
