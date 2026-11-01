import Foundation
import CoreGraphics

// MARK: - 变焦过渡合成器（预览显示源的底层设计）
//
// 目标（以用户体验为唯一验收标准）：
//   1. 焦段切换的取景平滑、单调、无回摆；
//   2. 镜头切换停顿时由系统底衬覆盖过渡；普通拍照停顿保留最后的胶片帧；
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
//     sessionPreset、对照片采集链路零影响。镜头切换中主帧龄超过阈值时把主源淡出、露出底衬的
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
/// 镜头切换期间，帧龄 > 150ms 淡出、< 50ms 淡回，中间带保持当前值。
/// 底衬不可用或没有镜头切换时，主源恒为 1；拍照/后处理引起的停帧不得露出未调色画面。
/// 150ms 阈值高于压力节流到 15fps 的 66ms 帧距，避免在切换窗口内按帧率反复脉动。
struct PreviewUnderlayBlender: Sendable, Equatable {
    /// 主源当前透明度 [0,1]。1 = 纯主源（稳态），0 = 纯底衬（停顿窗口中段）。
    private(set) var metalOpacity: CGFloat = 1

    /// 镜头切换过渡期的最小透明度(「染色层」)。底衬是系统进程合成的画面、拿不到
    /// LUT——纯淡出会让分级↔未分级在切换窗口跳变两次(用户感知的「LUT 有无闪烁」)。
    /// 过渡期把冻结的分级帧保留为半透明层叠在实时底衬上,色调全程连续;代价是过渡
    /// 期轻微重影(运动中的变焦画面会掩盖大半)。0 = 纯底衬(旧行为);由
    /// CameraManager 在切换进行中(遮罩窗口或 ramp 未 settle)时抬高。
    var transitionFloor: CGFloat = 0

    private var lastUpdate: CFTimeInterval = 0

    static let staleThreshold: TimeInterval = 0.15
    static let resumeThreshold: TimeInterval = 0.05
    /// 淡入底衬比淡回更快——停顿要尽快被遮住；淡回稍慢让双源重叠期更长、切换更柔。
    static let revealDuration: CFTimeInterval = 0.12
    static let concealDuration: CFTimeInterval = 0.20

    /// 每个渲染帧调用一次（MetalPreview.Coordinator.draw → CameraManager）。
    /// - Returns: 主源应使用的透明度。
    mutating func update(mainFrameAge: TimeInterval, underlayAvailable: Bool,
                         lensTransitionActive: Bool, now: CFTimeInterval) -> CGFloat {
        guard underlayAvailable, lensTransitionActive else {
            metalOpacity = 1
            lastUpdate = now
            return 1
        }
        let target: CGFloat
        if mainFrameAge > Self.staleThreshold {
            target = transitionFloor
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

// MARK: - 跨镜头预遮罩决策

/// 主动跨镜头切换的底衬预遮罩决策(纯逻辑,可单测)。
///
/// 拉远方向的跨镜头切换必停帧(→超广实测 2.1–2.5s、长焦→主摄 0.5–0.7s),现状要等
/// 主帧龄超过 `PreviewUnderlayBlender.staleThreshold` 才淡出——开头先冻结 150ms、再
/// 120ms 双源重影,底衬才接管。`applyFocalLength` 在按下焦距键时已算出
/// `crossesConstituent`,拉远可以**从第 0ms 把主源视作过期**(与静止期翻转遮罩共用
/// `underlayFlipMaskUntil`),让系统底衬的 crossfade 直接接管切换开头。
///
/// 拉近方向**不预遮**:`.restricted` 策略下拉近切换可能无缝(帧流不断裂,
/// `PreviewCropCeilingSynchronizer.seamlessAcceptTimeoutSeconds` 即为此设),预遮会给
/// 无缝切换引入不必要的未分级闪现——保持帧龄驱动的现状。
///
/// 窗口只负责开头:停顿中段由帧龄阈值(>150ms)自然维持淡出,窗口过后衔接无缝;若切换
/// 意外快速完成,窗口结束且帧流新鲜即淡回,代价被限制在窗口时长内。
enum LensTransitionPremask {
    /// 预遮罩窗口:覆盖主源淡出(120ms)与停顿早期;中段交还帧龄机制。
    static let windowSeconds: CFTimeInterval = 0.6

    /// 切换过渡染色层的透明度下限(`PreviewUnderlayBlender.transitionFloor` 的过渡值):
    /// 底衬拿不到 LUT,切换窗口保留 35% 冻结分级帧压住「LUT 有无」的色调跳变,
    /// 代价是过渡期轻微重影。0 = 退回纯底衬(旧行为);真机观感可调。
    static let tintFloor: CGFloat = 0.35

    /// - Parameters:
    ///   - crossesConstituent: 本次切换是否跨越 constituent 边界(switchover)。
    ///   - fromZoom: 设备当前 zoom(非乐观 UI 目标值)。
    ///   - toZoom: 本次切换的目标 zoom。
    static func shouldMask(crossesConstituent: Bool, fromZoom: CGFloat, toZoom: CGFloat) -> Bool {
        crossesConstituent && toZoom < fromZoom
    }
}
