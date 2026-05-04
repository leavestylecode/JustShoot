import Foundation
@preconcurrency import AVFoundation
import os

// MARK: - 对焦 / 曝光补偿 / 闪光 / 拍照
//
// 这个 extension 把"按快门到出片"涉及的所有 device 操作集中在一处：
// tap-to-focus / drag-for-EV / 闪光 AE 锁与还原 / capturePhoto 主流程 +
// AVCapturePhotoCaptureDelegate 全套回调。

extension CameraManager {

    // MARK: - 对焦

    func setFocusAndExposure(normalizedPoint: CGPoint) {
        guard let device = videoCaptureDevice else {
            Log.session.error("focus_set_skip reason=no_device")
            return
        }

        let focusPointOK = device.isFocusPointOfInterestSupported
        let exposurePointOK = device.isExposurePointOfInterestSupported
        let autoFocusOK = device.isFocusModeSupported(.autoFocus)
        let autoExposeOK = device.isExposureModeSupported(.autoExpose)

        do {
            try device.lockForConfiguration()
            if focusPointOK { device.focusPointOfInterest = normalizedPoint }
            if exposurePointOK { device.exposurePointOfInterest = normalizedPoint }
            if autoFocusOK { device.focusMode = .autoFocus }
            if autoExposeOK { device.exposureMode = .autoExpose }
            // 每次新 tap 把 EV 偏置归零——对齐 iPhone Camera：sun 总是从中位开始
            device.setExposureTargetBias(0) { _ in }
            device.unlockForConfiguration()

            Log.session.info("focus_set device=\(device.localizedName, privacy: .public) avf=(\(String(format: "%.3f", normalizedPoint.x)),\(String(format: "%.3f", normalizedPoint.y))) focus_pt=\(focusPointOK) expo_pt=\(exposurePointOK) auto_focus=\(autoFocusOK) auto_expose=\(autoExposeOK)")

            if exposureBias != 0 { exposureBias = 0 }
            isFocusLocked = true
            startFocusHoldTimer()
        } catch {
            Log.session.error("focus_set_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 上下滑动手势驱动的曝光补偿。clamp 到 ±1 EV 软上限和设备实际 min/max 的交集——
    /// 胶片模拟用机最常见的需求是"压一档保高光 / 提一档救暗部"，±1 EV 已覆盖这个区间；
    /// 拍同一卷胶片在更极端光比下用户应该换胶片或开闪光灯，而不是把 EV 推到 ±3。
    /// 收紧上限的副效果：sun rail 满程对应 ±1 EV，单次 100pt 即可走完全程，体感更直接。
    /// 注意：flash capture 路径会在 lock 期间临时改写 device.exposureTargetBias，capture 完成后
    /// 通过 pendingFlashRestore 还原到本方法写入的值。所以即使在 capture 之间多次拖动也是安全的——
    /// 只要 isCapturing 守护住了拍照进行中不让此方法触发（CameraView 那一层的 guard）。
    func setExposureBias(_ bias: Float) {
        guard let device = videoCaptureDevice else { return }
        let lo = max(-1.0, device.minExposureTargetBias)
        let hi = min(1.0, device.maxExposureTargetBias)
        let clamped = max(lo, min(hi, bias))
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clamped) { _ in }
            device.unlockForConfiguration()
            if abs(exposureBias - clamped) > 0.001 {
                exposureBias = clamped
            }
        } catch {
            Log.session.error("set_bias_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 对焦完成回调（KVO isAdjustingFocus → false）
    func onFocusCompleted() {
        // 对焦完成后可用于触发 UI 更新（如对焦框缩小动画）
        // 注意：此回调对 continuousAutoFocus 的每次重收敛也会触发，不只是 tap-to-focus。
        // 日志主要用于诊断 tap 是否真的让镜组动了——lensPosition 会从原值收敛到目标。
        if let device = videoCaptureDevice {
            Log.session.debug("focus_completed device=\(device.localizedName, privacy: .public) lens_position=\(String(format: "%.3f", device.lensPosition)) mode=\(device.focusMode.rawValue) locked=\(self.isFocusLocked)")
        }
        NotificationCenter.default.post(name: .focusDidComplete, object: nil)
    }

    func startFocusHoldTimer() {
        focusHoldTimer?.invalidate()
        focusHoldTimer = Timer.scheduledTimer(withTimeInterval: tapFocusHoldDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.restoreContinuousFocus()
                self?.isFocusLocked = false
            }
        }
    }

    /// 用户在 reticle 可见期间继续操作（EV 调整、连续微调）→ 重置 3s 锁定计时器，
    /// 让 reticle 不会在用户还在交互时突然消失。仅在已锁定状态下生效，避免无端续期。
    func refreshFocusHold() {
        guard isFocusLocked else { return }
        startFocusHoldTimer()
    }

    func restoreContinuousFocus() {
        guard let device = videoCaptureDevice else { return }
        focusHoldTimer?.invalidate()
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // 同时把 EV 偏置归零：focusHoldTimer 超时 / subjectAreaDidChange 都走这里——
            // 用户拖动产生的 sun 偏移随对焦框一起淡出，与 iPhone Camera 行为一致。
            if exposureBias != 0 {
                device.setExposureTargetBias(0) { _ in }
            }
            device.unlockForConfiguration()
            if exposureBias != 0 { exposureBias = 0 }
        } catch {}
    }

    // MARK: - 闪光灯曝光补偿

    func calculateFlashExposureBias(device: AVCaptureDevice) -> Float {
        let lensPos = max(0.0, min(1.0, device.lensPosition))
        let exposureDuration = device.exposureDuration
        let exposureSeconds = Double(exposureDuration.value) / Double(exposureDuration.timescale)
        let isLowLight = exposureSeconds > 0.03
        let isVeryLowLight = exposureSeconds > 0.1

        let baseBias = Float(lensPos) * 1.8 - 1.0

        var bias: Float
        if isVeryLowLight {
            bias = baseBias + 0.3
        } else if isLowLight {
            bias = baseBias + 0.15
        } else {
            bias = baseBias
        }

        if lensPos < 0.15 {
            bias = min(bias, -0.6)
        }

        return bias
    }

    /// 把 capture 之前打包的闪光灯状态还原到 device。
    /// 使用 try? + 闭包 catch 容错，AVF 在 swap 期间偶尔会抛锁失败，不应让相机崩溃。
    func applyFlashRestore(_ state: FlashRestoreState, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(state.exposureTargetBias) { _ in }
            if state.lockedExposure, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if state.lockedWB, device.isWhiteBalanceModeSupported(state.wbMode) {
                device.whiteBalanceMode = state.wbMode
            }
            device.unlockForConfiguration()
        } catch {
            Log.session.error("flash_restore_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func toggleFlashMode() {
        flashMode = (flashMode == .on) ? .off : .on
    }

    // MARK: - 拍照

    func capturePhoto(
        onWillCapture: (() -> Void)? = nil,
        onExposureComplete: (() -> Void)? = nil,
        completion: @escaping (Data?) -> Void
    ) {
        photoDataHandler = completion
        exposureCompleteHandler = onExposureComplete
        willCaptureHandler = onWillCapture

        // 镜头切换正在进行（启动期 250ms grace / slow-path Phase 0–3 / 锁后 200ms ZSL refill）
        // 时，await 直到 isLensTransitioning 归 false 再 issue 给 AVF。
        // 修的根因：上一版没有这道闸门 → ZSL ring 里上一颗 constituent 的帧被选作出片源 →
        // 用户选 35mm 拍出来的照片元数据是 13mm UW 镜头。waitForLensSettled 600ms 上限兜底,
        // 不会让快门永久卡住。绝大多数情况实测 0–250ms。
        let initialIsLensTransitioning = isLensTransitioning
        Task { @MainActor [weak self] in
            guard let self else { return }
            if initialIsLensTransitioning {
                await self.waitForLensSettled()
            }
            self.issueCapturePhoto()
        }
    }

    /// capturePhoto 主体——拆出来是为了让外层 capturePhoto 能 await waitForLensSettled。
    /// 必须 @MainActor：访问 photoOutput / videoCaptureDevice / pendingFlashRestore / flashMode。
    func issueCapturePhoto() {
        let issueTime = Log.now()
        // HEIF/HEVC 编码：相同视觉质量下文件比 JPEG 小 ~50%，是 iPhone Camera 的默认格式。
        // 48MP cap 后 24mm 单张 JPEG ~25-35MB，HEIF 直接降到 ~6-10MB；35mm/100mm 等中等焦段也都同步缩。
        // 系统不支持 HEVC（极少见，旧设备）时 fallback 到 JPEG。
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        // 关键：必须把 settings.maxPhotoDimensions 显式设到 output 的声明值，否则系统兜底到默认 12MP
        // (4032×3024)，叠加数码 zoom 后画幅会大幅缩水（如 35mm 1.46x 会从 24MP 退化到 ~10MP）。
        // output.maxPhotoDimensions 只是 capability 声明，per-capture settings 不继承——这是
        // iOS 16+ 的标准模式（取代旧的 isHighResolutionPhotoEnabled）。
        // 真实细节由 active format 决定：48MP active 时 35mm 在 48MP 上裁切到 ~22MP 后交付,
        // 与 iPhone Camera 在 1.5x 的真实细节对齐。
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        // 与 photoOutput.maxPhotoQualityPrioritization 一致：.balanced 走完整原生管线
        // （Deep Fusion / Smart HDR / Photonic Engine），同步交付高质量数据再过 LUT。
        settings.photoQualityPrioritization = .balanced

        if let device = videoCaptureDevice, device.hasFlash {
            settings.flashMode = (flashMode == .on) ? .on : .off
            if flashMode == .on {
                // 异常路径自愈：上一次的 pendingFlashRestore 没被消费（极少见，比如
                // didFinishProcessingPhoto 被 dropped），先把旧状态还原再开新的，
                // 避免 previousExposureTargetBias 被覆盖成"调整后的偏置值"。
                if let stale = pendingFlashRestore {
                    Log.capture.error("flash_restore_leaked recovering")
                    applyFlashRestore(stale, device: device)
                    pendingFlashRestore = nil
                }

                let bias = calculateFlashExposureBias(device: device)
                do {
                    try device.lockForConfiguration()
                    let savedBias = device.exposureTargetBias
                    let savedWBMode = device.whiteBalanceMode
                    var didLockExposure = false
                    var didLockWB = false

                    let clamped = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, bias))
                    device.setExposureTargetBias(clamped) { _ in }
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                        didLockExposure = true
                    }
                    // 锁 WB：闪光灯触发会让 AWB 突跳一帧，引入色温/染色偏移；锁住后 capture 完成再还原。
                    // 已锁 AE 的同时也锁 WB，组合出 iPhone 原相机闪光下的稳色感。
                    if device.isWhiteBalanceModeSupported(.locked), device.whiteBalanceMode != .locked {
                        device.whiteBalanceMode = .locked
                        didLockWB = true
                    }
                    device.unlockForConfiguration()

                    pendingFlashRestore = FlashRestoreState(
                        exposureTargetBias: savedBias,
                        wbMode: savedWBMode,
                        lockedExposure: didLockExposure,
                        lockedWB: didLockWB
                    )
                } catch {}
            }
        }

        settings.embedsDepthDataInPhoto = false
        settings.embedsPortraitEffectsMatteInPhoto = false
        settings.embedsSemanticSegmentationMattesInPhoto = false
        // 闪光灯下恒定色彩（Constant Color）减少白平衡偏移
        if photoOutput.isConstantColorSupported, flashMode == .on {
            settings.isConstantColorEnabled = true
        }

        // 抓取当前 rotation 角度（避免在 sessionQueue 跨 actor 访问）。
        // 出片随物理朝向：横握出横片、竖握出竖片，与 iPhone 系统相机一致。
        // 见 applyVideoOrientationToOutputs 的"预览/出片解耦"说明。
        let rotationAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let output = photoOutput
        let delegate = self
        // 闪光灯路径需要 200ms 延迟让 lockExposure + setExposureTargetBias 真正生效。
        let needsFlashDelay = (pendingFlashRestore?.lockedExposure ?? false)

        // 调度到 sessionQueue：AVCapturePhotoOutput 操作不占用主线程，快门响应更快
        let deadline: DispatchTime = needsFlashDelay ? .now() + 0.20 : .now()
        let reqDims = settings.maxPhotoDimensions
        // 安全快门可观测性：抓 device 的 activeMaxExposureDuration（我们设的 cap）和 exposureDuration
        // (AE 当前一帧的实际曝光时间)。两者对比能一眼看出 cap 是否在咬：
        //   live=cap → AE 顶到上限了（低光场景）
        //   live<cap → 光线足够，AE 自由调，cap 没起作用
        let capStr = self.formatExposureCMTime(self.videoCaptureDevice?.activeMaxExposureDuration)
        let liveStr = self.formatExposureCMTime(self.videoCaptureDevice?.exposureDuration)
        Log.capture.info("capture_dispatch flash=\(self.flashMode.rawValue, privacy: .public) flash_delay=\(needsFlashDelay ? 200 : 0)ms rotation=\(rotationAngle.map { "\(Int($0))°" } ?? "nil", privacy: .public) max_dims=\(reqDims.width)x\(reqDims.height) safe_shutter=\(capStr, privacy: .public) live_exposure=\(liveStr, privacy: .public)")
        sessionQueue.asyncAfter(deadline: deadline) {
            if let angle = rotationAngle,
               let connection = output.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let dispatchLatency = (CFAbsoluteTimeGetCurrent() - issueTime) * 1000.0
            Log.capture.info("capture_invoke dt_issue=\(String(format: "%.1f", dispatchLatency))ms")
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    /// AVF 主曝光即将开始——开闪光灯时这一刻就是氙气主脉冲发射的瞬间。
    /// Apple 文档明确指引这里做 shutter visual feedback（屏幕白屏 / 快门音）。
    /// UI 白屏挂在这里 → 与真实闪光灯物理同帧，告别"先白屏后亮灯"的脱钩感。
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Log.capture.info("delegate_will_capture")
        Task { @MainActor in
            self.willCaptureHandler?()
            self.willCaptureHandler = nil
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Log.capture.info("delegate_did_capture dims=\(resolvedSettings.photoDimensions.width)x\(resolvedSettings.photoDimensions.height)")
        Task { @MainActor in
            self.exposureCompleteHandler?()
            self.exposureCompleteHandler = nil
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error = error {
            Log.capture.error("delegate_process_error error=\(error.localizedDescription, privacy: .public)")
            Task { @MainActor in self.photoDataHandler?(nil) }
            return
        }
        guard let imageData = photo.fileDataRepresentation() else {
            Log.capture.error("delegate_process_no_data")
            Task { @MainActor in self.photoDataHandler?(nil) }
            return
        }
        Log.capture.info("delegate_process_ok bytes=\(imageData.count)")

        // CIImage(data:) in applyLUTPreservingMetadata already applies EXIF orientation,
        // so we pass raw data directly — no need for a separate rotate+encode step.
        // 同一个 main-actor hop 中：先还原闪光灯 EV/WB，再通知 photoDataHandler。
        // 顺序保证下次 capturePhoto 入口看到的 device 状态已经是"还原后"。
        Task { @MainActor in
            if let device = self.videoCaptureDevice, let restore = self.pendingFlashRestore {
                self.applyFlashRestore(restore, device: device)
                self.pendingFlashRestore = nil
            }
            self.photoDataHandler?(imageData)
        }
    }
}
