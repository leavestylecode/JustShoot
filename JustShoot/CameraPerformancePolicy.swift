import AVFoundation
import CoreGraphics

/// Generation checks invalidate queued work after a navigation or background transition.
struct CameraSessionIntent: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var wantsRunning = false

    mutating func request(running: Bool) -> UInt64 {
        generation &+= 1
        wantsRunning = running
        return generation
    }

    func permitsStart(_ token: UInt64) -> Bool { wantsRunning && generation == token }
}

enum CameraPerformancePolicy {
    static let maximumPreviewLongEdge: CGFloat = 1280

    static func configurePreviewOutput(_ output: AVCaptureVideoDataOutput) {
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // Restore AVFoundation's default negotiation. Forcing the preview proxy was introduced
        // with the performance refactor; device traces now show zoom advancing while the user
        // reports an unchanged viewfinder. Keep drawable work bounded separately below.
        output.automaticallyConfiguresOutputBufferDimensions = true
    }

    static func drawableSize(bounds: CGSize, scale: CGFloat) -> CGSize {
        guard bounds.width.isFinite, bounds.height.isFinite, scale.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let factor = min(max(1, scale), maximumPreviewLongEdge / max(bounds.width, bounds.height))
        return CGSize(width: max(1, floor(bounds.width * factor)), height: max(1, floor(bounds.height * factor)))
    }

    static func diffusionSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(1, (width + 1) / 2), max(1, (height + 1) / 2))
    }

    static func frameRate(in ranges: [ClosedRange<Double>], ceiling: Double = 60) -> Double? {
        ranges.compactMap { range in
            let value = min(ceiling, range.upperBound)
            return value >= range.lowerBound && value > 0 ? value : nil
        }.max()
    }
}

/// AVFoundation smooths ramp-rate changes with an acceleration limit. Retargeting a ramp
/// while it is moving can carry its old velocity past the new destination. Assigning the
/// current zoom cancels that ramp without jumping to the requested destination, then the
/// new ramp starts from the device's actual position. cancelVideoZoomRamp() only eases out.
struct CameraZoomTransition: Sendable {
    let anchorZoom: CGFloat?
    let targetZoom: CGFloat
    let rate: Float
    let usesRamp: Bool

    /// `fastRamp`：同 constituent 内的短跳（≤1 档光变）用高速率——立即设置曾用来消除
    /// ramp 死启动的迟滞感，但真机观感反馈为「跳变生硬」；高速短 ramp（24↔35↔50 这类
    /// ~0.5 档的跳变 200-300ms 内完成）保留连续运动，名义速率不成为瓶颈。跨 switchover
    /// 维持速率阶梯——系统需要时间从容做 constituent crossfade，过快反而触发更重的重配。
    init?(currentZoom: CGFloat, targetZoom: CGFloat, isRamping: Bool, animated: Bool, fastRamp: Bool = false) {
        guard currentZoom.isFinite, targetZoom.isFinite, currentZoom > 0, targetZoom > 0 else { return nil }
        self.targetZoom = targetZoom
        anchorZoom = animated && isRamping ? currentZoom : nil
        let ratio = max(targetZoom / currentZoom, currentZoom / targetZoom)
        // 真机实测 AVFoundation 对 ramp 施加加速度上限，短跳（≤2 档）的有效速度 ~2-3 stops/s
        // 与指令速率关系不大，但低速率档（旧值 4）确实更慢；整体上调让长跳（200→35mm）明显收紧。
        rate = fastRamp ? 32 : (ratio < 1.5 ? 8 : ratio < 3 ? 16 : 24)
        usesRamp = animated && abs(targetZoom - currentZoom) > 0.0001
    }
}

/// 超过**当前活跃镜头归属区间上限**后的扩展数字变焦（渲染器侧居中裁切）。
///
/// 真机实锤（2026-10-07，iPhone 17 Pro Max / iOS 27，两轮取证）：成片管线对
/// videoZoomFactor 完整缩放（100/200mm 照片正确），而 VideoDataOutput 预览代理流
/// **只按活跃 constituent 的 virtualZoomRange 区间执行裁切**——低光下系统拒绝切
/// 长焦、主摄（区间 [2.0, 8.0]）被钉在 zoom 16 时，交付帧的取景钳在区间上限 8.0
/// （= 100mm），于是 200mm 预览与 100mm 相同。format 级
/// `videoZoomFactorUpscaleThreshold` 在该设备返回无效值（≤1），不是钳制点。
/// 白天长焦启用时（长焦区间直达 maxZoom）预览原生缩放正常，无需补偿。
///
/// 修法：k = zoom / 活跃镜头区间上限（由 activePrimaryConstituent KVO 跟踪，
/// focalInfo 提供各 constituent 的区间）。分母是**随镜头切换离散变化的准常量**，
/// ramp 期间不变——k 只随 zoom 单调、随镜头切换阶跃，无回摆。
enum ExtendedPreviewZoom {
    static func cropFactor(zoom: CGFloat, streamCeiling: CGFloat) -> CGFloat {
        guard streamCeiling > 1, streamCeiling.isFinite else { return 1 }
        return max(1, max(1, zoom) / streamCeiling)
    }
}

/// 把区间上限的离散变化**对齐到帧流的真实切换点**（`previewZoomCrop` 闪烁的修法）。
///
/// constituent KVO 在系统*提交*镜头切换的瞬间触发，而 VideoDataOutput 交付的帧内容
/// 要到切换完成后才换成新镜头。若 KVO 一到就换上限，窗口内仍在渲染的旧镜头帧会拿到
/// 按新上限算的裁切——取景瞬间跳宽/跳近再跳回（低光 200mm 上限 8.0↔16.0 时是整整
/// 2 倍），即用户可见的预览闪烁。
///
/// 对齐信号按切换策略二分（2026-10-08 真机日志实锤两界行为）：
/// - **`.restricted`（当前策略）**：镜头切换**无缝**——帧流不断裂（pts 节距恒 33ms），
///   只有 1-2 帧在途旧源帧。此时长超时兜底是灾难：渲染上限滞留旧值整个超时窗
///   （实测 622ms），上限升向（如 UW 2.0→Wide 8.0）会产生 zoom/旧上限 的虚假裁切
///   （35mm 被裁成 ~50mm 观感，随后的超时换轨再跳回——「画面大小来回切换」的根因）。
///   用短超时（120ms）把虚假窗口压到 ~4 帧，且靠近 switchover 时误差只有百分之几。
/// - **`.auto`（历史策略）**：切换伴随停帧（实测 ≥500ms，→超广 2.1–2.5s）。停顿期
///   无帧到达、超时不被评估，首帧新内容由 ≥200ms 的 PTS 断裂信号换轨；长超时（600ms）
///   只兜底「帧流持续无断裂」的假想情形。保持帧在停顿窗口沿用旧上限，取景连续。
struct PreviewCropCeilingSynchronizer: Sendable {
    /// 帧间断裂判定阈值：正常 30fps 节距 33ms、重负载 15fps 节距 66ms 都在下方，
    /// 真实跨镜头停帧（.auto 策略）≥500ms。
    static let frameGapThresholdSeconds: Double = 0.2
    /// `.restricted` 无缝切换的换轨超时：~4 帧容差，覆盖在途帧深度。
    static let seamlessAcceptTimeoutSeconds: Double = 0.12
    /// `.auto` 停帧切换的换轨超时：等断裂信号的兜底上限。
    static let stallingAcceptTimeoutSeconds: Double = 0.6

    /// 渲染侧当前应使用的上限（`previewZoomCrop` 的分母）。
    private(set) var renderCeiling: CGFloat = .greatestFiniteMagnitude
    private var kvCeiling: CGFloat = .greatestFiniteMagnitude
    private var kvCeilingChangedAt: Double = 0
    private var activeAcceptTimeout: Double = PreviewCropCeilingSynchronizer.stallingAcceptTimeoutSeconds
    private var lastFramePTS: Double?

    /// 上限换轨完成的回执（`frameArrived` 恰好在此帧生效），供日志取证。
    struct Latch: Equatable {
        let ceiling: CGFloat
        /// 触发方式：帧流断裂的时长（首帧为 nil）或超时等待的年龄。
        let gapSeconds: Double?
        let ageSeconds: Double
    }

    /// constituent KVO 报告新的活跃区间上限（`now` 用 host uptime，与超时判定同钟）。
    /// `acceptTimeout` 按当前切换策略传入：无缝切换用短超时，停帧切换用长超时。
    mutating func kvCeilingDidChange(
        to ceiling: CGFloat,
        at now: Double,
        acceptTimeout: Double = PreviewCropCeilingSynchronizer.stallingAcceptTimeoutSeconds
    ) {
        kvCeiling = ceiling
        kvCeilingChangedAt = now
        activeAcceptTimeout = acceptTimeout
    }

    mutating func reset() {
        self = Self()
    }

    /// 每个预览帧到达时调用；返回该帧起渲染应使用的上限，恰在换轨帧返回回执。
    mutating func frameArrived(pts: Double, at now: Double) -> Latch? {
        defer { lastFramePTS = pts }
        guard kvCeiling != renderCeiling else { return nil }
        let gap = lastFramePTS.map { pts - $0 }
        let discontinuity = gap.map { $0 >= Self.frameGapThresholdSeconds } ?? true
        let timedOut = now - kvCeilingChangedAt >= activeAcceptTimeout
        guard discontinuity || timedOut else { return nil }
        renderCeiling = kvCeiling
        return Latch(ceiling: renderCeiling, gapSeconds: gap, ageSeconds: now - kvCeilingChangedAt)
    }
}
