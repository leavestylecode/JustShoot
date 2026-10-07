import Foundation
import CoreGraphics

// MARK: - 变焦过渡合成器（预览显示源的底层设计）
//
// 目标（以用户体验为唯一验收标准）：
//   1. 焦段切换的取景平滑、单调、无回摆；
//   2. 主帧流停顿时预览不冻结——必须有别的源在动；
//   3. 稳态回到纯主源渲染（胶片分级所见即所得）；
//   4. 任何一层失效都优雅退化为现状，绝不允许黑屏或冻结加深。
//
// 显示模型（2026-10-06 两轮真机迭代后的最终形态）：
//   - **变焦显示直接跟随硬件 videoZoomFactor ramp。** AVF 的 ramp 本身单调平滑
//     （zoom_samples 真机可证），这就是系统相机向用户展示的内容。
//   - 主源：虚拟设备自动切换流（Metal 胶片渲染）。
//   - 底衬源：系统 AVCaptureVideoPreviewLayer（AVFoundation 自行合成）。镜头切换时它拿到
//     系统 crossfade 合成流而非停帧，且不参与会话连接结构、不改 sessionPreset、对照片采集
//     链路零影响。主帧龄超过阈值时把主源淡出、露出底衬的实时画面，恢复后淡回。
//
// 设计决策记录（为什么没有「合成裁切动画」）：
// 曾实现「拉近方向在已渲染帧上叠加居中数字裁切，让取景 ~280ms 先到位」。该方案的裁切倍率
// k = 显示zoom / 当前帧烘焙zoom——分母无法从元数据获得，只能用 zoom KVO 估计，而真机日志
// 显示 KVO 以 ~100ms 批次到达（zoom_samples 成对同时间戳），估计值在帧之间抖动：
//   - 第一版用实时设备 zoom 作分母：重复帧重绘被拉远、新帧被拉近，±7% 回摆；
//   - 第二版分母冻结在帧到达时刻：批次抖动仍使倍率在 7-15Hz 来回缩放。
// 耦合噪声不可根除（除非拿到逐帧精确 zoom，公开 API 没有），而「错误的丝滑比诚实的硬件
// 节奏糟糕得多」——整体移除。切换速度由 ramp 速率（8/16/24）与 settle maxWait 管理，
// 停顿窗口由底衬混合覆盖。
//
// 第二级方案（已设计、待真机验证后再启用）：AVCaptureMultiCamSession + 虚拟设备
// constituent port（WWDC19 249「Introducing Multi-Camera Capture」的同步流路径）把超广
// 帧流直接送进 previewLUT 的第二输入纹理（texture(4)，参数位已预留），实现分级连续的
// 真双流 crossfade。不默认启用的原因：MultiCam 会话的 sessionPreset 固定为 .inputPriority，
// 不能设 .photo——48MP 照片管线（format 选择 / Deep Fusion / ZSL）必须在 inputPriority 下
// 重新真机验证后才能切换，盲切有静默画质回归风险。
//
// 本文件只放纯逻辑（无 AVFoundation 依赖），全部可单测；副作用（图层透明度）由
// MetalPreview.Coordinator 与 CameraManager 承担。

/// 超过**当前活跃镜头归属区间上限**后的扩展数字变焦（渲染器侧裁切）。
///
/// 真机实锤（2026-10-07，iPhone 17 Pro Max / iOS 27，两轮取证）：成片管线对
/// videoZoomFactor 完整缩放（100/200mm 照片正确），而 VideoDataOutput 预览代理流
/// **只按活跃 constituent 的 virtualZoomRange 区间执行裁切**——低光下系统拒绝切
/// 长焦、主摄（区间 [2.0, 8.0]）被钉在 zoom 16 时，交付帧的取景钳在区间上限 8.0
/// （= 100mm），于是 200mm 预览与 100mm 相同。format 级
/// `videoZoomFactorUpscaleThreshold` 在该设备返回无效值（≤1），不是钳制点。
/// 白天长焦启用时（长焦区间直达 maxZoom）预测预览原生缩放正常，无需补偿。
///
/// 修法：k = zoom / 活跃镜头区间上限（由 activePrimaryConstituent KVO 跟踪，
/// focalInfo 提供各 constituent 的区间）。分母是**随镜头切换离散变化的准常量**，
/// ramp 期间不变——与已移除合成动画的本质区别：那时的分母是逐帧抖动的 KVO
/// 估计（回摆之源），这里 k 只随 zoom 单调、随镜头切换阶跃，无回摆。
enum ExtendedPreviewZoom {
    static func cropFactor(zoom: CGFloat, streamCeiling: CGFloat) -> CGFloat {
        guard streamCeiling > 1, streamCeiling.isFinite else { return 1 }
        return max(1, max(1, zoom) / streamCeiling)
    }
}

/// 主源（Metal 胶片渲染视图）与底衬源（系统预览层）之间的透明度混合状态机。
///
/// 输入是主帧龄：正常 30fps 下帧龄在 0–33ms 抖动；跨镜头切换时升到数百 ms～2.5s；
/// 照片后处理负载峰值（连拍）也会饿死主源帧流。规则：
///   - 帧龄 > 停顿阈值 → 目标透明度 0（淡出主源，露出底衬的实时画面）；
///   - 帧龄 < `resumeThreshold`（50ms，连续两帧到达）→ 目标透明度 1（淡回主源）；
///   - 中间带保持当前值（滞回，避免在阈值附近抖动）；
///   - 底衬不可用（未挂载 / 未配置）→ 恒为 1，行为与单流现状完全一致。
///
/// 两档停顿阈值：常规 150ms（安全高于最慢节流帧率 15fps 的 66ms 节距，避免误触发）；
/// **采集忙碌档 66ms**（captureBusy = 有排队/处理中的照片任务）——连拍时后处理负载
/// 会周期性饿死主源帧流（真机日志：watchdog 级停顿 + 帧龄 1.5s），底衬由系统进程
/// 合成、不受本进程负载影响，更低阈值让系统画面更快接管。底衬是未分级画面，
/// 只在停顿窗口可见——比冻结好。
struct PreviewUnderlayBlender: Sendable, Equatable {
    /// 主源当前透明度 [0,1]。1 = 纯主源（稳态），0 = 纯底衬（停顿窗口中段）。
    private(set) var metalOpacity: CGFloat = 1

    private var lastUpdate: CFTimeInterval = 0

    static let staleThreshold: TimeInterval = 0.15
    static let busyStaleThreshold: TimeInterval = 0.066
    static let resumeThreshold: TimeInterval = 0.05
    /// 淡入底衬比淡回更快——停顿要尽快被遮住；淡回稍慢让双源重叠期更长、切换更柔。
    static let revealDuration: CFTimeInterval = 0.12
    static let busyRevealDuration: CFTimeInterval = 0.10
    static let concealDuration: CFTimeInterval = 0.20

    /// 每个渲染帧调用一次（MetalPreview.Coordinator.draw → CameraManager）。
    /// - Returns: 主源应使用的透明度。
    mutating func update(mainFrameAge: TimeInterval, underlayAvailable: Bool,
                         captureBusy: Bool = false, now: CFTimeInterval) -> CGFloat {
        guard underlayAvailable else {
            metalOpacity = 1
            lastUpdate = now
            return 1
        }
        let staleThreshold = captureBusy ? Self.busyStaleThreshold : Self.staleThreshold
        let target: CGFloat
        if mainFrameAge > staleThreshold {
            target = 0
        } else if mainFrameAge < Self.resumeThreshold {
            target = 1
        } else {
            target = metalOpacity   // 滞回带：保持
        }
        let elapsed = max(0, now - lastUpdate)
        let reveal = captureBusy ? Self.busyRevealDuration : Self.revealDuration
        let duration = target < metalOpacity ? reveal : Self.concealDuration
        let step = duration > 0 ? CGFloat(min(1, elapsed / duration)) : 1
        if target > metalOpacity {
            metalOpacity = min(target, metalOpacity + step)
        } else if target < metalOpacity {
            metalOpacity = max(target, metalOpacity - step)
        }
        lastUpdate = now
        return metalOpacity
    }
}
