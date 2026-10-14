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

    // MARK: - 切换过渡染色层

    func testTransitionFloorSaturatesToTintInsteadOfPureUnderlay() {
        // 切换过渡期(染色层):停顿淡出饱和到 floor 而非 0——底衬拿不到 LUT,
        // 保留的分级帧压住「有 LUT↔无 LUT」的色调跳变
        var blender = PreviewUnderlayBlender()
        blender.transitionFloor = 0.35
        XCTAssertEqual(blender.update(mainFrameAge: 0.02, underlayAvailable: true, now: 0), 1)
        let tinted = blender.update(mainFrameAge: 0.6, underlayAvailable: true, now: 0.5)
        XCTAssertEqual(tinted, 0.35, accuracy: 0.0001)
        // 帧流恢复后仍回到纯主源(floor 不影响恢复);间隔取 0.1s(增量步进 0.5,
        // 0.35+0.5 仍在过渡中,二进制精确值避开整比间隔)
        let restored = blender.update(mainFrameAge: 0.03, underlayAvailable: true, now: 0.6)
        XCTAssertGreaterThan(restored, 0.35)
        XCTAssertLessThan(restored, 1)
    }

    func testTransitionFloorOfZeroReproducesLegacyBehavior() {
        // floor=0(稳态)与旧版行为逐值一致——稳态停顿(拍照负载)仍走纯底衬
        var blender = PreviewUnderlayBlender()
        blender.transitionFloor = 0
        _ = blender.update(mainFrameAge: 0.02, underlayAvailable: true, now: 0)
        XCTAssertEqual(blender.update(mainFrameAge: 0.6, underlayAvailable: true, now: 0.5), 0, accuracy: 0.0001)
    }

    func testTransitionFloorInvalidatedWithoutUnderlay() {
        // 底衬不可用时无视 floor:主源恒 1(无染色层可言)
        var blender = PreviewUnderlayBlender()
        blender.transitionFloor = 0.35
        XCTAssertEqual(blender.update(mainFrameAge: 2.0, underlayAvailable: false, now: 1), 1)
    }

    // MARK: - 跨镜头预遮罩决策

    func testPremaskFiresForZoomOutAcrossConstituent() {
        // 35→13（主摄→超广,拉远必停帧 2.1–2.5s）与 200→50（长焦→主摄,停帧 0.5–0.7s）
        XCTAssertTrue(LensTransitionPremask.shouldMask(crossesConstituent: true, fromZoom: 2.917, toZoom: 1.0))
        XCTAssertTrue(LensTransitionPremask.shouldMask(crossesConstituent: true, fromZoom: 16.0, toZoom: 4.167))
    }

    func testPremaskSkipsZoomInAndSameConstituent() {
        // 13→35 拉近可能无缝（.restricted 帧流不断裂）——预遮会引入不必要的未分级闪现
        XCTAssertFalse(LensTransitionPremask.shouldMask(crossesConstituent: true, fromZoom: 1.0, toZoom: 2.917))
        // 35→50 同 constituent（fastRamp 短跳）与 100→200 同长焦,都不该遮
        XCTAssertFalse(LensTransitionPremask.shouldMask(crossesConstituent: false, fromZoom: 2.917, toZoom: 4.167))
        XCTAssertFalse(LensTransitionPremask.shouldMask(crossesConstituent: false, fromZoom: 8.05, toZoom: 16.0))
    }

    func testPremaskWindowCoversFadeOutPlusEarlyStall() {
        // 窗口须覆盖底衬淡出（120ms）并留停顿早期余量;中段交还帧龄阈值（150ms）维持。
        XCTAssertGreaterThan(LensTransitionPremask.windowSeconds, PreviewUnderlayBlender.revealDuration)
        XCTAssertGreaterThan(LensTransitionPremask.windowSeconds, PreviewUnderlayBlender.staleThreshold)
    }
}
