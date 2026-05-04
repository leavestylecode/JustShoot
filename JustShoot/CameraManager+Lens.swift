import Foundation
@preconcurrency import AVFoundation
import os

// MARK: - 焦段切换（fast / slow path）+ 安全快门 / 镜头转换状态机

extension CameraManager {

    /// 等待镜头切换稳定。capturePhoto 在 issue 给 AVF 之前调用——保证 ZSL ring 已经
    /// 换上新 constituent 的帧，不会从旧镜头的缓冲帧里挑出片。
    /// 600ms 上限保证就算 transition flag 因异常没被清掉，快门也不会永久卡住。
    func waitForLensSettled(timeoutMs: Int = 600) async {
        guard isLensTransitioning else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + Double(timeoutMs) / 1000.0
        while isLensTransitioning, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        let waited = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Log.capture.info("lens_settle_wait waited=\(String(format: "%.0f", waited))ms still_transitioning=\(self.isLensTransitioning)")
    }

    /// 安全快门：限制 AE 最长曝光时间，严格走经典 1/focal（35mm 等效）防手持模糊。
    /// 35mm 等效焦距 = `FocalLengthOption.rawValue`，已折算 W/T 物理镜头 + 数码裁切。
    ///   24mm → 1/24s, 35mm → 1/35s, 50mm → 1/50s, 100mm → 1/100s, 200mm → 1/200s
    /// 不再叠加 OIS 放宽 / 主体运动地板——经验表明手持快照"宁可抬 ISO 出噪点、不可拉快门糊掉",
    /// 1/focal 是这条原则下的经典基线，OIS 在该基线之上只是锦上添花的额外余量。
    /// activeMaxExposureDuration 是无侵入做法：不破坏 .continuousAutoExposure，AE 在上限内自由调节；
    /// 触顶时自动改抬 ISO，符合"保锐优先"。
    /// 上下界用 format.min/maxExposureDuration 兜底，避免越界。
    nonisolated func computeSafeShutterDuration(focalMm: Int, format: AVCaptureDevice.Format) -> CMTime {
        let denom = max(focalMm, 24)
        let target = CMTime(value: 1, timescale: Int32(denom))
        let minDur = format.minExposureDuration
        let maxDur = format.maxExposureDuration
        if CMTimeCompare(target, minDur) < 0 { return minDur }
        if CMTimeCompare(target, maxDur) > 0 { return maxDur }
        return target
    }

    /// 把 CMTime 曝光时长格式化为人类可读字符串（"1/Ns" / "X.XXXs"）。
    /// nil / invalid 返回 "n/a"。capture_dispatch 等多处日志复用。
    nonisolated func formatExposureCMTime(_ time: CMTime?) -> String {
        guard let time, time.isValid, !time.isIndefinite else { return "n/a" }
        let s = CMTimeGetSeconds(time)
        guard s > 0, s.isFinite else { return "n/a" }
        if s < 1 { return "1/\(Int(round(1.0 / s)))s" }
        return String(format: "%.3fs", s)
    }

    /// 外部入口：切换等效焦距
    func setFocalLength(_ option: FocalLengthOption, animated: Bool = true) {
        guard focalInfo.options.contains(option) else { return }
        let previousZoom = currentZoomFactor
        syncCurrentFocalLength(option)
        applyFocalLength(option, animated: animated, fromZoom: previousZoom)
    }

    /// 标记进入"镜头切换中"状态。capturePhoto 会 await 直到此 flag 归 false 再发给 AVF。
    /// 默认 600ms 兜底超时；调用方传 graceMs 控制启动期 / slow-path 完成后的余量（让 ZSL 换血）。
    /// 同样的 flag 在 lensSettleTask 里被定时器或 constituent KVO 命中时清掉——双保险。
    func beginLensTransition(graceMs: Int) {
        isLensTransitioning = true
        lensSettleTask?.cancel()
        lensSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(graceMs))
            guard let self, !Task.isCancelled else { return }
            self.markLensSettled(reason: "grace_timeout(\(graceMs)ms)")
        }
    }

    /// 把 isLensTransitioning 清掉。constituent KVO 命中（active === expected）或 grace 超时调用。
    /// 幂等：已经 false 时直接返回，避免重复打日志。
    func markLensSettled(reason: String) {
        guard isLensTransitioning else { return }
        lensSettleTask?.cancel()
        lensSettleTask = nil
        isLensTransitioning = false
        Log.session.info("lens_settled reason=\(reason, privacy: .public) active=\(self.activeConstituentName, privacy: .public) expected=\(self.expectedConstituent?.localizedName ?? "nil", privacy: .public)")
    }

    /// 单点更新 currentFocalLength 并同步 Camera Control picker 的选中索引。
    /// 程序化设置 selectedIndex 不会回调 picker action，因此安全无重入。
    func syncCurrentFocalLength(_ option: FocalLengthOption) {
        if currentFocalLength != option {
            currentFocalLength = option
        }
        if let picker = focalLengthPicker,
           let idx = focalInfo.options.firstIndex(of: option),
           picker.selectedIndex != idx {
            picker.selectedIndex = idx
        }
    }

    /// 切焦距。两条路径：
    ///
    /// **快路径**（target constituent 已激活，如 35mm→50mm 都在 W 上）：单 lock 块内
    /// `.locked` + ramp + 安全快门，零异步等待，瞬时响应。
    ///
    /// **慢路径**（跨 constituent，如 35mm→100mm）：
    ///   - Phase 0: 独立 lock 块解 `.locked → .auto`，yield 33ms 让 AVF 把 min/max 展回 [1, max]。
    ///     **不能与 zoom 写共用同一锁块**—— zoom 写入仍按旧 .locked min/max clamp，跨档卡住。
    ///   - Phase 1: 单段动画 ramp 直接到 targetZoom。`.auto` 模式下，ramp 经过 switchover 阈值时
    ///     系统硬件级自动 crossfade 切换 constituent —— 这就是 iPhone 原相机连续 zoom 的丝滑感。
    ///   - Phase 2: 等 ramp 完成（KVO `isRampingVideoZoom`）+ constituent 收敛到 target。
    ///   - Phase 3: `.locked` 钉住 constituent，防止后续 AE/zoom 漂移。
    ///
    /// 边界焦距（24mm zoom=2.0、100mm zoom=8.0）在 switchover 上，加 0.05 ε 推进 target 区间内部,
    /// 避免 ramp 落在边界时系统选错 constituent。FOV 偏差 < 1%，肉眼不可察。
    /// `applyFocalToken` 防止快速来回点导致旧 task 把新档位的 lock 撤掉。
    func applyFocalLength(_ option: FocalLengthOption, animated: Bool = true, fromZoom: CGFloat? = nil) {
        guard let device = videoCaptureDevice else {
            Log.session.error("focal_apply_no_device option=\(option.rawValue)")
            return
        }
        guard let target = focalInfo.constituent(for: option) else {
            Log.session.error("focal_apply_no_constituent option=\(option.rawValue) info_constituents=\(self.focalInfo.constituents.count)")
            return
        }

        // 边界保护：targetZoom 恰在 target.virtualZoomRange.lowerBound 上时（24mm/100mm），
        // ramp 终点落在 switchover 阈值上，系统判定有歧义可能选错 constituent。
        // 加 0.05 ε 推进区间内部（FOV 偏差：100mm→100.6mm，24mm→24.6mm，肉眼不可察）。
        // UW 的 lowerBound = 1.0 是设备最小 zoom，没有低位 constituent 可漂移，跳过该补偿。
        let baseZoom = focalInfo.virtualZoomFactor(for: option)
        let needsBoundaryBias = target.virtualZoomRange.lowerBound > 1.0 &&
                                abs(baseZoom - target.virtualZoomRange.lowerBound) < 0.01
        let targetZoom = needsBoundaryBias ? baseZoom + 0.05 : baseZoom

        applyFocalToken &+= 1
        let myToken = applyFocalToken

        // 自适应 ramp 速率：跨度越大越快，小幅切换更柔和（同 iPhone 原相机）
        let ratio = fromZoom.map { max(targetZoom / $0, $0 / targetZoom) } ?? 2.0
        let rampRate: Float = if ratio < 1.5 { 4.0 } else if ratio < 3.0 { 8.0 } else { 16.0 }

        // ============= 快路径：target constituent 已激活，直接 ramp =============
        // 适用 35→50（同 W）、100→200（同 T）等场景。零异步等待，体验最丝滑。
        if device.activePrimaryConstituent === target.device {
            do {
                try device.lockForConfiguration()
                // 幂等：已 .locked 时是 no-op；从 .auto 状态进入则锁到当前 target constituent
                device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                let postLockMin = device.minAvailableVideoZoomFactor
                let postLockMax = device.activeFormat.videoMaxZoomFactor
                let finalZoom = max(postLockMin, min(postLockMax, targetZoom))

                if animated {
                    device.ramp(toVideoZoomFactor: finalZoom, withRate: rampRate)
                } else {
                    device.videoZoomFactor = finalZoom
                }
                self.currentZoomFactor = finalZoom

                let safeShutter = self.computeSafeShutterDuration(focalMm: option.rawValue, format: device.activeFormat)
                device.activeMaxExposureDuration = safeShutter
                device.unlockForConfiguration()

                let active = device.activePrimaryConstituent?.localizedName ?? "nil"
                Log.session.info("focal_applied path=fast option=\(option.rawValue)mm active=\(active, privacy: .public) zoom=\(String(format: "%.2f", finalZoom))x animated=\(animated)")
            } catch {
                Log.session.error("focal_fast_lock_failed error=\(error.localizedDescription, privacy: .public)")
            }
            return
        }

        // ============= 慢路径：跨 constituent，单段动画 ramp + .auto 自然 crossfade =============
        // 进慢路径意味着 ZSL ring 即将经历"旧 constituent 帧 → 切换中模糊帧 → 新 constituent 帧"
        // 三段过渡。capturePhoto 必须等到这段过渡完才发出 issue，否则出片元数据会带上旧镜头。
        expectedConstituent = target.device
        beginLensTransition(graceMs: 600)  // Phase 0–3 + grace 上限

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Phase 0: 释放上一次的 .locked，切回 .auto，让 minAvailableVideoZoomFactor 展回 [1, max]
            do {
                try device.lockForConfiguration()
                device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                device.unlockForConfiguration()
            } catch {
                Log.session.error("focal_phase0_unlock_failed error=\(error.localizedDescription, privacy: .public)")
                return
            }
            try? await Task.sleep(for: .milliseconds(33))  // ≈1 帧 @30fps，让 AVF 重算 min/max
            if self.applyFocalToken != myToken { return }

            // Phase 1: 单段动画 ramp 直接到 targetZoom。ramp 经过 switchover 时 .auto 自动 crossfade。
            // 这是丝滑感的核心：用户看到的是连续 zoom 动画，不是"硬跳一帧 + 等 + 再 ramp"。
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: targetZoom, withRate: rampRate)
                } else {
                    device.videoZoomFactor = targetZoom
                }
                self.currentZoomFactor = targetZoom
                // 安全快门：与 zoom 共用同一把 lock，焦段切换时同步更新
                let safeShutter = self.computeSafeShutterDuration(focalMm: option.rawValue, format: device.activeFormat)
                device.activeMaxExposureDuration = safeShutter
                device.unlockForConfiguration()
            } catch {
                Log.session.error("focal_phase1_lock_failed error=\(error.localizedDescription, privacy: .public)")
                return
            }

            // Phase 2: 等 ramp 完成（KVO isRampingVideoZoom = false），1500ms 兜底
            if animated {
                let rampDeadline = Date().addingTimeInterval(1.5)
                while device.isRampingVideoZoom, Date() < rampDeadline {
                    try? await Task.sleep(for: .milliseconds(20))
                    if self.applyFocalToken != myToken { return }
                }
            }
            // ramp 完成后 .auto 通常已选好 target；个别场景下 AE 还在收敛，再等 300ms 兜底
            let consDeadline = Date().addingTimeInterval(0.3)
            while device.activePrimaryConstituent !== target.device, Date() < consDeadline {
                try? await Task.sleep(for: .milliseconds(20))
                if self.applyFocalToken != myToken { return }
            }
            if self.applyFocalToken != myToken { return }

            // Phase 3: 锁 constituent，防止后续 AE/zoom 漂移
            let activeBeforeLock = device.activePrimaryConstituent
            do {
                try device.lockForConfiguration()
                device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                device.unlockForConfiguration()
            } catch {
                Log.session.error("focal_phase3_lock_failed error=\(error.localizedDescription, privacy: .public)")
                return
            }

            let active = activeBeforeLock?.localizedName ?? "nil"
            let match = activeBeforeLock === target.device
            Log.session.info("focal_applied path=slow option=\(option.rawValue)mm target=\(target.device.localizedName, privacy: .public) active=\(active, privacy: .public) match=\(match) zoom=\(String(format: "%.2f", device.videoZoomFactor))x animated=\(animated)")

            // Phase 3 之后再留 200ms grace 让 ZSL ring 收满新 constituent 的帧再放行 capture
            // （constituent KVO 那条路径只覆盖 active 切到位的瞬间；这里覆盖 active 早就切到位
            // 但 KVO 没新通知的场景——拍摄前 active 一直没变，但锁刚生效 ring 还没刷新）
            try? await Task.sleep(for: .milliseconds(200))
            if self.applyFocalToken == myToken {
                self.markLensSettled(reason: "slow_path_complete")
            }
        }
    }
}
