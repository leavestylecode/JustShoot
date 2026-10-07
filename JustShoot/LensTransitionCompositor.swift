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
// 显示模型（2026-10-07 用户拍板采用 Apple 官方推荐路径落地）：
//   - **变焦显示直接跟随硬件 videoZoomFactor ramp。** AVF 的 ramp 本身单调平滑
//     （zoom_samples 真机可证），这就是系统相机向用户展示的内容。
//   - 主源：虚拟设备自动切换流（Metal 胶片渲染）——实时视觉效果的官方推荐路径
//     （AVCaptureVideoDataOutput + 自渲染）。
//   - 底衬源：系统 AVCaptureVideoPreviewLayer——Apple 官方文档推荐的标准预览显示层，
//     由 AVFoundation 在服务进程自行合成。虚拟设备切镜头时它拿到系统的 crossfade
//     合成流而非停帧（系统相机同款显示路径），且不参与会话连接结构、不改
//     sessionPreset、对照片采集链路零影响。主帧龄超过阈值时把主源淡出、露出底衬的
//     实时画面，恢复后淡回。
//   - 已否决的替代路径：AVCaptureMultiCamSession 双流自做 alpha 混合（2026-10-07
//     用户决定不采用——它是社区逆向系统行为的推断手法而非 Apple 推荐：MultiCam 的
//     sessionPreset 固定 .inputPriority 不能设 .photo，48MP 照片管线有静默回归风险，
//     且功耗发热代价大）。官方 preview layer 底衬即本架构的第一级。
//
// 设计决策记录（为什么没有「合成裁切动画」）：
// 曾实现「拉近方向在已渲染帧上叠加居中数字裁切，让取景 ~280ms 先到位」。该方案的裁切倍率
// k = 显示zoom / 当前帧烘焙zoom——分母无法从元数据获得，只能用 zoom KVO 估计，而真机日志
// 显示 KVO 以 ~100ms 批次到达（zoom_samples 成对同时间戳），估计值在帧之间抖动：
//   - 第一版用实时设备 zoom 作分母：重复帧重绘被拉远、新帧被拉近，±7% 回摆；
//   - 第二版分母冻结在帧到达时刻：批次抖动仍使倍率在 7-15Hz 来回缩放。
// 耦合噪声不可根除（除非拿到逐帧精确 zoom，公开 API 没有），而「错误的丝滑比诚实的硬件
// 节奏糟糕得多」——整体移除。停顿窗口由本文件的底衬混合覆盖。
//
// 本文件只放纯逻辑（无 AVFoundation 依赖），全部可单测；副作用（图层透明度/变换）由
// MetalPreview 与 CameraManager 承担。

/// 主源（Metal 胶片渲染视图）与底衬源（系统预览层）之间的透明度混合状态机。
///
/// 输入是主帧龄：正常 30fps 下帧龄在 0–33ms 抖动；跨镜头切换时升到数百 ms～2.5s；
/// 照片后处理负载峰值也会饿死主源帧流。规则：
///   - 帧龄 > `staleThreshold`（150ms）→ 目标透明度 0（淡出主源，露出底衬的实时画面）；
///   - 帧龄 < `resumeThreshold`（50ms，连续两帧到达）→ 目标透明度 1（淡回主源）；
///   - 中间带保持当前值（滞回，避免在阈值附近抖动）；
///   - 底衬不可用（未挂载 / 未配置）→ 恒为 1，行为与单流现状完全一致。
///
/// 停顿阈值必须高于「压力节流帧率的节距」：后处理负载恰恰会把预览流节流到
/// 15fps（66ms 节距）——阈值一旦踩在节距上，每个帧间隙都判停顿，分级层与未分级
/// 底衬会按帧率节拍反复脉动（66ms 版本的真实观感回归）。底衬由系统进程合成、
/// 不受本进程负载影响，是第三方能拿到的「半个系统相机路径」；未分级画面只在
/// 停顿窗口可见——比冻结好。
struct PreviewUnderlayBlender: Sendable, Equatable {
    /// 主源当前透明度 [0,1]。1 = 纯主源（稳态），0 = 纯底衬（停顿窗口中段）。
    private(set) var metalOpacity: CGFloat = 1

    private var lastUpdate: CFTimeInterval = 0

    static let staleThreshold: TimeInterval = 0.15
    static let resumeThreshold: TimeInterval = 0.05
    /// 淡入底衬比淡回更快——停顿要尽快被遮住；淡回稍慢让双源重叠期更长、切换更柔。
    static let revealDuration: CFTimeInterval = 0.12
    static let concealDuration: CFTimeInterval = 0.20

    /// 每个渲染帧调用一次（MetalPreview.Coordinator.draw → CameraManager）。
    /// - Returns: 主源应使用的透明度。
    mutating func update(mainFrameAge: TimeInterval, underlayAvailable: Bool, now: CFTimeInterval) -> CGFloat {
        guard underlayAvailable else {
            metalOpacity = 1
            lastUpdate = now
            return 1
        }
        let target: CGFloat
        if mainFrameAge > Self.staleThreshold {
            target = 0
        } else if mainFrameAge < Self.resumeThreshold {
            target = 1
        } else {
            target = metalOpacity   // 滞回带：保持
        }
        let elapsed = max(0, now - lastUpdate)
        let duration = target < metalOpacity ? Self.revealDuration : Self.concealDuration
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
