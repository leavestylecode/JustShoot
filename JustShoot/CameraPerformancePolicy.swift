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

    init?(currentZoom: CGFloat, targetZoom: CGFloat, isRamping: Bool, animated: Bool) {
        guard currentZoom.isFinite, targetZoom.isFinite, currentZoom > 0, targetZoom > 0 else { return nil }
        self.targetZoom = targetZoom
        anchorZoom = animated && isRamping ? currentZoom : nil
        let ratio = max(targetZoom / currentZoom, currentZoom / targetZoom)
        rate = ratio < 1.5 ? 4 : ratio < 3 ? 8 : 16
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
/// 要到切换完成后才换成新镜头（实测跨镜头停帧 ≥500ms，→超广 2.1–2.5s）。若 KVO 一到
/// 就换上限，窗口内仍在渲染的旧镜头帧会拿到按新上限算的裁切——取景瞬间跳宽/跳近再
/// 跳回（低光 200mm 上限 8.0↔16.0 时是整整 2 倍），即用户可见的预览闪烁。
///
/// 对齐信号：跨镜头切换必然在帧流上留下 PTS 断裂。KVO 只登记待生效上限
/// （`kvCeilingDidChange`），`frameArrived` 在每帧到达时裁决——出现 ≥200ms 断裂
/// （第一帧视为断裂）即认为内容已切到新镜头，此刻换上限恰好在第一帧新内容上生效；
/// 停顿窗口内被冻结重绘的保持帧继续用旧上限，取景全程连续。帧流持续无断裂
/// （无缝切换的假想情形）时按 600ms 年龄兜底接受，保证上限不会永久滞留旧值。
struct PreviewCropCeilingSynchronizer: Sendable {
    /// 帧间断裂判定阈值：正常 30fps 节距 33ms、重负载 15fps 节距 66ms 都在下方，
    /// 真实跨镜头切换停帧 ≥500ms。
    static let frameGapThresholdSeconds: Double = 0.2
    /// KVO 上限变化后仍无断裂时，最多延迟这么久无条件接受。
    static let acceptTimeoutSeconds: Double = 0.6

    /// 渲染侧当前应使用的上限（`previewZoomCrop` 的分母）。
    private(set) var renderCeiling: CGFloat = .greatestFiniteMagnitude
    private var kvCeiling: CGFloat = .greatestFiniteMagnitude
    private var kvCeilingChangedAt: Double = 0
    private var lastFramePTS: Double?

    /// 上限换轨完成的回执（`frameArrived` 恰好在此帧生效），供日志取证。
    struct Latch: Equatable {
        let ceiling: CGFloat
        /// 触发方式：帧流断裂的时长（首帧为 nil）或超时等待的年龄。
        let gapSeconds: Double?
        let ageSeconds: Double
    }

    /// constituent KVO 报告新的活跃区间上限（`now` 用 host uptime，与超时判定同钟）。
    mutating func kvCeilingDidChange(to ceiling: CGFloat, at now: Double) {
        kvCeiling = ceiling
        kvCeilingChangedAt = now
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
        let timedOut = now - kvCeilingChangedAt >= Self.acceptTimeoutSeconds
        guard discontinuity || timedOut else { return nil }
        renderCeiling = kvCeiling
        return Latch(ceiling: renderCeiling, gapSeconds: gap, ageSeconds: now - kvCeilingChangedAt)
    }
}
