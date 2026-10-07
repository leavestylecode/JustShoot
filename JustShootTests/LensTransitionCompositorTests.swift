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
        // 系统压力节流到 15fps（66ms 节距）仍在停顿阈值（150ms）之下，稳态不误露底衬——
        // 阈值一旦踩在节距上，分级层与未分级底衬会按帧率节拍反复脉动（66ms 版本的观感回归）。
        var blender = PreviewUnderlayBlender()
        for tick in stride(from: 0.0, through: 2.0, by: 1.0) {
            let opacity = blender.update(mainFrameAge: 0.066, underlayAvailable: true, now: tick)
            XCTAssertEqual(opacity, 1, accuracy: 0.0001)
        }
    }
}
