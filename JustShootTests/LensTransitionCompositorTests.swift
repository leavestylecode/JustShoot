import XCTest
@testable import JustShoot

/// LensTransitionCompositor（主源↔底衬混合状态机）的纯逻辑单测。
/// 覆盖：底衬不可用退化、停顿淡出、恢复淡回、滞回带保持、正常帧节距不误触发。
final class LensTransitionCompositorTests: XCTestCase {

    func testUnderlayUnavailablePinsMainSourceOpaque() {
        var blender = PreviewUnderlayBlender()
        let opacity = blender.update(mainFrameAge: 2.0, underlayAvailable: false, now: 10)
        XCTAssertEqual(opacity, 1)
        XCTAssertEqual(blender.metalOpacity, 1)
    }

    func testStaleMainStreamRevealsUnderlayAndSaturates() {
        var blender = PreviewUnderlayBlender()
        // 正常帧节距（30fps，帧龄 ≤ 33ms）不触发
        XCTAssertEqual(blender.update(mainFrameAge: 0.02, underlayAvailable: true, now: 0), 1)
        // 停顿：帧龄超阈值，开始淡出
        let fading = blender.update(mainFrameAge: 0.3, underlayAvailable: true, now: 0.05)
        XCTAssertLessThan(fading, 1)
        XCTAssertGreaterThan(fading, 0)
        // 淡入时长远小于跨镜头停顿时长（数百 ms～2.5s），充分到达纯底衬
        let revealed = blender.update(mainFrameAge: 0.6, underlayAvailable: true, now: 0.5)
        XCTAssertEqual(revealed, 0, accuracy: 0.0001)
    }

    func testResumedMainStreamConcealsUnderlay() {
        var blender = PreviewUnderlayBlender()
        _ = blender.update(mainFrameAge: 0.5, underlayAvailable: true, now: 2.0)
        XCTAssertEqual(blender.update(mainFrameAge: 0.5, underlayAvailable: true, now: 2.2), 0, accuracy: 0.0001)
        // 主帧流恢复（连续新帧，帧龄回常态）
        let rising = blender.update(mainFrameAge: 0.03, underlayAvailable: true, now: 2.4)
        XCTAssertGreaterThan(rising, 0)
        XCTAssertLessThan(rising, 1)
        let restored = blender.update(mainFrameAge: 0.03, underlayAvailable: true, now: 3.0)
        XCTAssertEqual(restored, 1, accuracy: 0.0001)
    }

    func testHysteresisBandHoldsCurrentOpacity() {
        var blender = PreviewUnderlayBlender()
        _ = blender.update(mainFrameAge: 0.02, underlayAvailable: true, now: 0)
        // 滞回带（50ms–150ms）：既不算停顿也不算恢复，保持当前值，阈值附近不抖动
        XCTAssertEqual(blender.update(mainFrameAge: 0.08, underlayAvailable: true, now: 0.5), 1, accuracy: 0.0001)

        var blended = PreviewUnderlayBlender()
        _ = blended.update(mainFrameAge: 0.4, underlayAvailable: true, now: 1.0)
        _ = blended.update(mainFrameAge: 0.4, underlayAvailable: true, now: 1.2)
        XCTAssertEqual(blended.metalOpacity, 0, accuracy: 0.0001)
        // 停顿末尾帧龄开始回落但未过恢复线：仍保持纯底衬
        XCTAssertEqual(blended.update(mainFrameAge: 0.1, underlayAvailable: true, now: 1.3), 0, accuracy: 0.0001)
    }

    func testThrottledFrameRatesDoNotTrigger() {
        var blender = PreviewUnderlayBlender()
        // 系统压力节流到 15fps（66ms 节距）仍在阈值之下，稳态不误露底衬
        for tick in stride(from: 0.0, through: 2.0, by: 1.0) {
            let opacity = blender.update(mainFrameAge: 0.066, underlayAvailable: true, now: tick)
            XCTAssertEqual(opacity, 1, accuracy: 0.0001)
        }
    }

    /// 采集忙碌档：停顿阈值降到 66ms——后处理负载刚开始饿帧（80ms）就让系统底衬
    /// 接管；常规档同帧龄在滞回带内保持主源。
    func testCaptureBusyModeRevealsUnderlayAtLowerThreshold() {
        var idle = PreviewUnderlayBlender()
        _ = idle.update(mainFrameAge: 0.02, underlayAvailable: true, now: 0)
        XCTAssertEqual(idle.update(mainFrameAge: 0.08, underlayAvailable: true, now: 0.05), 1, accuracy: 0.0001)

        var busy = PreviewUnderlayBlender()
        _ = busy.update(mainFrameAge: 0.02, underlayAvailable: true, now: 0)
        XCTAssertLessThan(busy.update(mainFrameAge: 0.08, underlayAvailable: true, captureBusy: true, now: 0.05), 1)
        // 充分推进后到达纯底衬，恢复帧流后淡回
        XCTAssertEqual(busy.update(mainFrameAge: 0.4, underlayAvailable: true, captureBusy: true, now: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(busy.update(mainFrameAge: 0.02, underlayAvailable: true, captureBusy: true, now: 1.0), 1, accuracy: 0.0001)
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
        // ramp 跨越上限：倍率随 zoom 单调连续（ramp 期间上限恒定——与已移除合成动画的本质区别）
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 12.0, streamCeiling: 8.0), 1.5, accuracy: 0.0001)
    }

    /// 白天长焦场景：长焦区间直达 maxZoom（189），zoom 永不超过上限 → 不裁
    /// （预览流原生缩放正常，预测无需补偿）。
    func testExtendedCropInactiveWhenConstituentCoversZoom() {
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: 189.0), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 100.0, streamCeiling: 189.0), 1)
    }

    func testExtendedCropDegenerateInputsDisabled() {
        // 上限未知（.infinity）或 ≤1 时禁用扩展裁切，行为与原始流完全一致
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: .greatestFiniteMagnitude), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: 0), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: 16.0, streamCeiling: 1), 1)
        XCTAssertEqual(ExtendedPreviewZoom.cropFactor(zoom: -3, streamCeiling: 8.0), 1)
    }
}
