import Foundation
@preconcurrency import AVFoundation
import UIKit
import os

// MARK: - 权限 / 会话配置 / KVO observers / 生命周期 / 诊断
//
// configureAndStartSession 是冷启动的主入口：在 sessionQueue 上拼装 input/output、
// 一次性把虚拟设备锁到目标焦段（关 ZSL × 镜头切换 race），然后回主 actor 装 KVO 监听 +
// Camera Control 控件 + AVCaptureSession 中断/恢复观察者。
// pauseSessionForBackground / resumeSessionIfPossible / stopSession 三件套覆盖完整的
// 后台/前台/导航返回三种生命周期路径。

extension CameraManager {

    // MARK: - 权限

    func requestCameraPermission() {
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            Log.session.info("permission_camera_status status=\(status.rawValue)")
            switch status {
            case .authorized:
                self.setCameraDenied(false)
                await self.configureAndStartSession()
                if Task.isCancelled { return }
                self.startLocationServices()
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                Log.session.info("permission_camera_result granted=\(granted)")
                if Task.isCancelled { return }
                if granted {
                    self.setCameraDenied(false)
                    await self.configureAndStartSession()
                    if Task.isCancelled { return }
                    self.startLocationServices()
                } else {
                    self.setCameraDenied(true)
                }
            case .denied, .restricted:
                Log.session.error("permission_camera_denied")
                self.setCameraDenied(true)
            @unknown default:
                break
            }
        }
    }

    // MARK: - Session 配置

    /// 在专用串行队列上配置并启动 AVCaptureSession。虚拟设备模式（iOS 26 推荐）：
    /// 单 input（如 .builtInTripleCamera），constituent 切换由系统在内部完成，不再需要 swap。
    func configureAndStartSession() async {
        guard !session.isRunning, let device = captureDevice else {
            Log.session.debug("session_config_skip running=\(self.session.isRunning) has_device=\(self.captureDevice != nil)")
            return
        }
        let configTimer = Log.perf("session_configure", logger: Log.session)
        Log.session.info("session_config_begin device=\(device.localizedName, privacy: .public)")

        let captureSession = session
        let output = photoOutput
        let videoOutput = videoDataOutput
        // 把 MainActor 上的 currentFocalLength 抓到 closure 里——sessionQueue 上不能跨回主 actor 读
        let initialFocal = currentFocalLength

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                captureSession.beginConfiguration()
                captureSession.sessionPreset = .photo

                do {
                    let videoInput = try AVCaptureDeviceInput(device: device)
                    if captureSession.canAddInput(videoInput) {
                        captureSession.addInput(videoInput)
                    }

                    self.applyBestFormatAndModes(on: device)
                    // 关键：在 startRunning 之前把 videoZoomFactor + .locked 钉到目标焦段，
                    // 让 ZSL ring 一开始就只收正确 constituent 的帧——见 lockInitialFocalLength 注释
                    // 里描述的"35mm 拍出 UW 镜头照片"那个 race 的根因 + 修复。
                    self.lockInitialFocalLength(on: device, focal: initialFocal)

                    if captureSession.canAddOutput(output) {
                        captureSession.addOutput(output)

                        // .balanced 启用 Deep Fusion / Smart HDR / Photonic Engine 同步处理：
                        // 暗光降噪、动态范围、纹理细节都接入原生计算摄影管线，回调延迟 +100–300ms
                        // 但 ZSL + ResponsiveCapture 让快门手感不变，LUT 又是异步跑，整体无感。
                        // 注意：不开 isAutoDeferredPhotoDeliveryEnabled——其 deferred 结果只交付
                        // PhotoKit，自定义 SwiftData 存储拿不到，开启反而只拿到早期低质版本。
                        output.maxPhotoQualityPrioritization = .balanced
                        if output.isResponsiveCaptureSupported {
                            output.isResponsiveCaptureEnabled = true
                        }
                        if output.isFastCapturePrioritizationSupported {
                            output.isFastCapturePrioritizationEnabled = false
                        }
                        if output.isZeroShutterLagSupported {
                            output.isZeroShutterLagEnabled = true
                        }

                        // 输出锁定 12MP 附近（4032×3024）。锐度来自 active format 降采样。
                        self.applyMaxPhotoDimensions(output: output, device: device)
                    }

                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    if captureSession.canAddOutput(videoOutput) {
                        captureSession.addOutput(videoOutput)
                        // connection 在 addOutput 后才存在；必须在 commitConfiguration 前/后任意时机设置。
                        // 这里紧跟 addOutput 设置，与其他输出配置一起原子提交，避免首帧抖动可见。
                        self.applyPreviewStabilization(output: videoOutput, device: device)
                    }
                } catch {
                    Log.session.error("session_setup_error error=\(error.localizedDescription, privacy: .public)")
                }

                captureSession.commitConfiguration()
                captureSession.startRunning()
                Log.session.info("session_started running=\(captureSession.isRunning) inputs=\(captureSession.inputs.count) outputs=\(captureSession.outputs.count) max_dims=\(output.maxPhotoDimensions.width)x\(output.maxPhotoDimensions.height)")
                continuation.resume()
            }
        }

        // Back on MainActor — set up delegates and properties that need main thread
        currentVideoInput = captureSession.inputs.first as? AVCaptureDeviceInput
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        observeCaptureRotationAngle()
        videoDataOutput.setSampleBufferDelegate(self, queue: previewQueue)

        // 虚拟设备：activeFormat / constituentDevices / virtualDeviceSwitchOverVideoZoomFactors 均已可用
        focalInfo = DeviceFocalInfo.from(virtualDevice: device)
        if !focalInfo.options.contains(currentFocalLength) {
            currentFocalLength = focalInfo.options.contains(.mm35) ? .mm35 : (focalInfo.options.first ?? .mm24)
        }

        // 镜头硬件锁已在 sessionQueue 配置阶段完成（lockInitialFocalLength），这里不再重复
        // applyFocalLength——后者会走 slow path 把 .locked 临时撤回 .auto，反而打开 race 窗口。
        // 仅同步 MainActor 上的 currentZoomFactor 反映已生效的 zoom，让 UI 的焦距条立刻准。
        currentZoomFactor = focalInfo.virtualZoomFactor(for: currentFocalLength)
        // 启动期同样视作"过渡中"：让前 ~200ms 的 startRunning warmup 帧（哪怕硬件已切到 W,
        // ISP 第一帧偶尔仍带上一颗的影子）走 waitForLensSettled 排空。constituent KVO 命中或
        // 250ms 兜底后清掉 flag——见 markLensSettled。
        expectedConstituent = focalInfo.constituent(for: currentFocalLength)?.device
        beginLensTransition(graceMs: 250)
        applyVideoOrientationToOutputs()
        configTimer.end("zoom=\(String(format: "%.2f", currentZoomFactor))x")

        // dumpLensSpecs 打 70+ 行 os_log + 遍历 device.formats，main actor 上同步执行
        // 会延迟"主 actor 进入 idle"，让用户首次按下快门时的 Task @MainActor in 排队等待。
        let args = LensDumpArgs(
            device: device,
            focalInfo: focalInfo,
            photoOutput: photoOutput,
            videoDataOutput: videoDataOutput
        )
        Task.detached(priority: .background) {
            Self.dumpLensSpecsImpl(args: args)
        }

        // Camera Control 硬件支持（iPhone 16+）：离散焦段选择器
        if currentVideoInput != nil {
            let titles = focalInfo.options.map { "\($0.rawValue)mm" }
            let picker = AVCaptureIndexPicker(String(localized: "Focal length"), symbolName: "camera.metering.spot", localizedIndexTitles: titles)
            if let idx = focalInfo.options.firstIndex(of: currentFocalLength) {
                picker.selectedIndex = idx
            }
            picker.setActionQueue(.main) { [weak self] index in
                guard let self, index < self.focalInfo.options.count else { return }
                self.setFocalLength(self.focalInfo.options[index])
            }
            if session.canAddControl(picker) {
                session.addControl(picker)
                focalLengthPicker = picker
                Log.session.info("camera_control_index_picker_added options=\(titles)")
            }
            // 系统 EV 滑块（绑当前设备）。机身 Camera Control 长按可在 picker / slider 间切换。
            if let device = videoCaptureDevice {
                installExposureBiasSlider(for: device)
            }
            session.setControlsDelegate(self, queue: .main)
        }

        // 一次性绑定 zoom / focus / pressure KVO 到当前设备（swap 后会重绑）
        bindDeviceObservers(to: device)

        // 场景变化时自动恢复连续对焦/曝光（subjectArea 通知不随设备变，绑一次即可）
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.restoreContinuousFocus()
                self.isFocusLocked = false
            }
        }

        // AVCaptureSession 中断 / 恢复 / runtime error 通知：
        //   - WasInterrupted: 来电、控制中心录屏、Siri、其他 app 抢占摄像头
        //     → 系统自动 stopRunning，记一下状态等 InterruptionEnded
        //   - InterruptionEnded: 中断结束，需要手动 startRunning
        //   - RuntimeError: 硬件错误、被高优先级 client 抢占等，AVF 已 fail，需重启 session
        // 没有这套监听，回到前台只看到黑屏（pixelBuffer 是 stale 的）。
        sessionInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            // 在 nonisolated 闭包里提取 Sendable 值（Int），不要把 Notification 跨 Task 边界发——
            // Swift 6 strict concurrency 会报 "sending 'note' risks causing data races"。
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
            Task { @MainActor in
                guard let self else { return }
                self.sessionInterrupted = true
                Log.session.info("session_was_interrupted reason=\(reason)")
            }
        }
        sessionInterruptionEndedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sessionInterrupted = false
                Log.session.info("session_interruption_ended → resume")
                self.resumeSessionIfPossible()
            }
        }
        sessionRuntimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            // 同上：把 AVError 拆成 Sendable 标量再跨 Task。
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            let code = err?.code.rawValue ?? -1
            let desc = err?.localizedDescription ?? "nil"
            Task { @MainActor in
                guard let self else { return }
                Log.session.error("session_runtime_error code=\(code) desc=\(desc, privacy: .public)")
                // 大多数 runtime error 是 mediaServicesWereReset / sessionWasInterrupted 类，重启即可恢复
                self.resumeSessionIfPossible()
            }
        }

        sessionConfigured = true

        // ZSL / Deep Fusion / Smart HDR / Photonic Engine 第一次 capture 时会同步初始化 pipeline,
        // 让用户第一张照片 dt_from_tap 出现 1-3 秒延迟（实测 2988ms vs 第二张 186ms）。
        // setPreparedPhotoSettingsArray 是 Apple 官方解决方案：用与正式 capture 完全一致的 settings
        // 提前喂给 AVF，系统会预分配 ring buffer + Smart HDR 多帧融合所需缓冲，第一张瞬间走热路径。
        prepareForFirstCapture()
    }

    /// 用与 `capturePhoto` 完全一致的 codec / dims / quality settings 预热 photo pipeline。
    /// settings 必须与真实拍摄完全匹配，否则系统按"模板未命中"重走冷启动路径。
    func prepareForFirstCapture() {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .balanced

        let output = photoOutput
        sessionQueue.async {
            output.setPreparedPhotoSettingsArray([settings]) { prepared, error in
                if let error {
                    Log.session.error("photo_pipeline_prepare_failed error=\(error.localizedDescription, privacy: .public)")
                } else {
                    Log.session.info("photo_pipeline_prepared ready=\(prepared)")
                }
            }
        }
    }

    // MARK: - 设备 format / 输出尺寸 / 防抖 / 初始焦段锁定

    /// 给指定设备选好 4:3 format 并设置焦点/曝光/帧率。
    /// 必须在 sessionQueue 调用。设备不必在 session 中（用于预配置 telephoto）。
    ///
    /// 选 format 的 ranking 主键：在 ≤cap 区间内，该 format 能解锁的 **最大 4:3 photo dim**。
    /// 关键事实（日志验证）：iPhone 17 Pro 的 supportedMaxPhotoDimensions 在所有 4:3 format 上
    /// 都只列 [12MP, 48MP] 两档——**没有 24MP 这一中间档**。Apple iPhone Camera 的"默认 24MP"
    /// 是私有/系统级路径，第三方 API 拿不到。要拿到 24MP 级别细节，只能走 48MP 输出，让系统在数码
    /// zoom 时自然裁出对应像素的 cropped 数据（35mm 1.46x → ~22MP 真实细节，对齐 iPhone Camera）。
    /// cap 设到 60M 容纳 48MP；24mm 1.0x 会拿到完整 48MP 文件（~10-15MB JPEG），是这条路径的代价。
    /// Tiebreaker 才用 video dim，保留高分辨率预览。
    nonisolated func applyBestFormatAndModes(on device: AVCaptureDevice) {
        let cap = 60_000_000  // 48MP 上限；这台 iPhone 17 Pro 没有 24MP 中间档可选
        let currentDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)

        // 该 format 在 ≤cap 区间内可解锁的最大 4:3 photo dim 像素面积；找不到返回 0。
        func bestPhotoArea(_ fmt: AVCaptureDevice.Format) -> Int {
            fmt.supportedMaxPhotoDimensions
                .filter { dim in
                    let r = Float(dim.width) / Float(dim.height)
                    return abs(r - 4.0 / 3.0) < 0.02
                }
                .map { Int($0.width) * Int($0.height) }
                .filter { $0 <= cap }
                .max() ?? 0
        }

        let candidates = device.formats.filter { fmt in
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard d.width > 0, d.height > 0 else { return false }
            let aspect = Float(d.width) / Float(d.height)
            let supports30 = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30.0 }
            return abs(aspect - 4.0 / 3.0) < 0.02 && supports30
        }

        let bestFormat = candidates.max { lhs, rhs in
            // 主键：photo 路径上能拿到的最大 4:3 dim（≤24MP）
            let lp = bestPhotoArea(lhs)
            let rp = bestPhotoArea(rhs)
            if lp != rp { return lp < rp }
            // Tiebreaker：video dim（保高分辨率预览）
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }

        do {
            try device.lockForConfiguration()
            if let fmt = bestFormat {
                let newDims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                if newDims.width != currentDims.width || newDims.height != currentDims.height {
                    device.activeFormat = fmt
                    let photoCaps = fmt.supportedMaxPhotoDimensions
                        .map { "\($0.width)x\($0.height)" }
                        .joined(separator: ",")
                    Log.session.info("active_format_set device=\(device.localizedName, privacy: .public) dims=\(newDims.width)x\(newDims.height) photo_caps=[\(photoCaps, privacy: .public)]")
                }
            }
            // 锁 sRGB：胶片 LUT 是按 sRGB 训练的，跳过 P3→sRGB 转换路径让色彩更稳定可预测。
            // supportedColorSpaces 几乎所有 format 都包含 sRGB，找不到就保持默认。
            if device.activeFormat.supportedColorSpaces.contains(.sRGB),
               device.activeColorSpace != .sRGB {
                device.activeColorSpace = .sRGB
                Log.session.info("color_space_set device=\(device.localizedName, privacy: .public) space=sRGB")
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // 关键：smoothAutoFocus 必须关。这是视频录制专用优化（让镜组移动平滑、避免观感突兀），
            // 代价是 AF 收敛"慢慢爬"。叠加 ZSL + ResponsiveCapture 时——系统从 buffered 帧中选一帧交付——
            // buffered 帧永远落在 AF 过渡途中，出片永远差一点。Apple 默认就是 false，iPhone Camera 也保持
            // false 才能在 still capture 上拿到真正的"已锁焦"buffered 帧。
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = false
            }
            device.isSubjectAreaChangeMonitoringEnabled = true

            // 安全快门兜底：1/30s 是手持快照下任何焦段都不应放慢的"主体运动地板"。
            // 后续 applyZoomOnly 会按当前焦段进一步收紧（100mm→1/50s, 200mm→1/100s）；
            // 这里设默认是覆盖"format 已就绪、focal 还没下来"的早期窗口，避免 AE 在那段时间里
            // 顶到 format 原生上限（通常 1s）拍出严重运动模糊。
            let defaultSafeShutter = CMTime(value: 1, timescale: 30)
            let formatMin = device.activeFormat.minExposureDuration
            let formatMax = device.activeFormat.maxExposureDuration
            let clampedDefault: CMTime
            if CMTimeCompare(defaultSafeShutter, formatMin) < 0 { clampedDefault = formatMin }
            else if CMTimeCompare(defaultSafeShutter, formatMax) > 0 { clampedDefault = formatMax }
            else { clampedDefault = defaultSafeShutter }
            device.activeMaxExposureDuration = clampedDefault

            let maxRate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30.0
            let targetFPS = min(maxRate, 60.0)
            nominalFPSLock.withLock { $0 = targetFPS }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))

            device.unlockForConfiguration()
        } catch {
            Log.session.error("apply_format_lock_failed device=\(device.localizedName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 给 photo output 选 4:3 输出尺寸（device 必须已 connect 到 photo output）。
    /// 策略：挑 ≤60M 像素的最大 4:3 dim。iPhone 17 Pro 上选中 48MP（8064×6048），
    /// 因为该机器不暴露 24MP 中间档（详见 applyBestFormatAndModes 注释）。
    /// 数码 zoom 工作机制：videoZoomFactor 在 sensor 上 center crop，输出 dim 自动随之缩小,
    /// 不需要手动按焦段调 maxPhotoDimensions——系统直接交付裁后真实像素。
    /// 例：48MP cap + 1.46x 数码 zoom → 出片 ~5520×4140 (~22.8MP)，对齐 iPhone Camera 35mm。
    nonisolated func applyMaxPhotoDimensions(output: AVCapturePhotoOutput, device: AVCaptureDevice) {
        let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
        let cap = 60_000_000
        let aspect43 = supportedDimensions.filter { dim in
            let ratio = Float(dim.width) / Float(dim.height)
            return abs(ratio - 4.0/3.0) < 0.05
        }
        if let selected = aspect43
            .filter({ Int($0.width) * Int($0.height) <= cap })
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) })
        {
            output.maxPhotoDimensions = selected
        } else if let fallback = aspect43.min(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            output.maxPhotoDimensions = fallback
        } else if let smallest = supportedDimensions.min(by: { $0.width < $1.width }) {
            output.maxPhotoDimensions = smallest
        }
    }

    /// 仅对预览/取景路径启用防抖，对齐 iPhone Camera 的"稳定取景"做法。
    /// photoOutput 不在此设置——静态拍摄走 OIS（硬件常开）+ 多帧融合（Smart HDR / Deep Fusion /
    /// Photonic Engine），任何在 photo connection 上设置的稳定模式都会与帧对齐冲突，反而劣化出片。
    /// 优先级：previewOptimized（iOS 17+，专为取景器设计，零快门延迟代价）→ standard → off。
    /// 100/200mm 长焦端裁切大、抖动放大，这一档对取景手感差异最显著。
    /// W↔T swap 后 active format 改变，需重新评估并重新设置。
    nonisolated func applyPreviewStabilization(output: AVCaptureVideoDataOutput, device: AVCaptureDevice) {
        guard let conn = output.connection(with: .video) else {
            Log.session.info("📷 stabilization_skip reason=no_video_connection device=\(device.localizedName, privacy: .public)")
            return
        }
        let fmt = device.activeFormat
        let mode: AVCaptureVideoStabilizationMode
        let name: String
        if fmt.isVideoStabilizationModeSupported(.previewOptimized) {
            mode = .previewOptimized; name = "preview"
        } else if fmt.isVideoStabilizationModeSupported(.standard) {
            mode = .standard; name = "std"
        } else {
            mode = .off; name = "off"
        }
        conn.preferredVideoStabilizationMode = mode
        Log.session.info("📷 stabilization_applied device=\(device.localizedName, privacy: .public) preferred=\(name, privacy: .public) active=\(conn.activeVideoStabilizationMode.rawValue)")
    }

    /// 在 session config block 内（startRunning 之前）把虚拟设备锁到目标焦段。
    ///
    /// **修复的 bug**：之前的实现在 startRunning 之后才异步走 slow path 切镜头——此时
    /// ZSL ring buffer 已经在收 zoom=1.0 (UW) 的帧，等 slow path Phase 3 lock 完成已过
    /// 300+ ms。这段时间内用户按快门，AVF 从 ring 里挑帧出片，照片元数据里的 LensModel /
    /// 物理 FocalLength 全是 UW，最后用户下载 35mm 拍的照片发现镜头是 13mm。
    ///
    /// **修复策略**：在 beginConfiguration / addInput 之后、addOutput / startRunning 之前,
    /// 把 videoZoomFactor 直接钉到目标焦段对应的虚拟 zoom，并切到 .locked。这样 startRunning
    /// 产出的第一帧就来自正确的 constituent，ring buffer 从生下来就是干净的。
    ///
    /// `.locked` 在配置阶段调用：此时 device 还没产帧，activePrimaryConstituent 可能是 nil
    /// 或默认值。但**hardware 在 startRunning 时按当前 videoZoomFactor 选 constituent**,
    /// 所以 zoom=2.92 一定让硬件挑 W；.locked 只是把这个选择钉住不让后续 AE 漂移。
    /// 即便 .locked 在配置阶段语义上"锁到当前活动"，硬件层面新的 active 选择仍以 zoom 为准。
    ///
    /// 走 nonisolated：从 sessionQueue.async 直接调用，不跨回 MainActor。
    nonisolated func lockInitialFocalLength(on device: AVCaptureDevice, focal: FocalLengthOption) {
        let info = DeviceFocalInfo.from(virtualDevice: device)
        let resolved: FocalLengthOption = {
            if info.options.contains(focal) { return focal }
            if info.options.contains(.mm35) { return .mm35 }
            return info.options.first ?? .mm24
        }()
        guard let target = info.constituent(for: resolved) else {
            Log.session.error("focal_init_lock_no_constituent option=\(resolved.rawValue)")
            return
        }
        let baseZoom = info.virtualZoomFactor(for: resolved)
        // 边界 ε 与 applyFocalLength 一致：targetZoom 恰落在 switchOver 阈值上时，硬件可能选错档
        let needsBoundaryBias = target.virtualZoomRange.lowerBound > 1.0 &&
                                abs(baseZoom - target.virtualZoomRange.lowerBound) < 0.01
        let targetZoom = needsBoundaryBias ? baseZoom + 0.05 : baseZoom

        do {
            try device.lockForConfiguration()
            // 先设 zoom（硬件据此选 constituent），再 .locked 钉住——同一 lock block 内原子提交
            device.videoZoomFactor = targetZoom
            device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
            // 安全快门也在此处一并下，避免 startRunning 后第一帧 AE 跑到 1s 上限
            let safeShutter = self.computeSafeShutterDuration(focalMm: resolved.rawValue, format: device.activeFormat)
            device.activeMaxExposureDuration = safeShutter
            device.unlockForConfiguration()
            Log.session.info("focal_locked_at_config option=\(resolved.rawValue)mm zoom=\(String(format: "%.2f", targetZoom)) target=\(target.device.localizedName, privacy: .public)")
        } catch {
            Log.session.error("focal_init_lock_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 安装/重装系统 EV 滑块（绑定到指定设备）。AVCaptureSystemExposureBiasSlider 是 device-bound 的,
    /// 设备 swap 后必须先 remove 旧的再 add 新的，否则滑块仍调旧设备的 exposureTargetBias，新设备无效。
    /// 安全在 MainActor 调用：和 picker 一样不强制 begin/commitConfiguration（与现有 picker 逻辑一致）。
    func installExposureBiasSlider(for device: AVCaptureDevice) {
        if let old = exposureBiasSlider {
            session.removeControl(old)
            exposureBiasSlider = nil
        }
        let slider = AVCaptureSystemExposureBiasSlider(device: device)
        if session.canAddControl(slider) {
            session.addControl(slider)
            exposureBiasSlider = slider
            Log.session.info("camera_control_bias_slider_added device=\(device.localizedName, privacy: .public) range=\(String(format: "%.1f", device.minExposureTargetBias))–\(String(format: "%.1f", device.maxExposureTargetBias))ev")
        } else {
            Log.session.info("camera_control_bias_slider_skip device=\(device.localizedName, privacy: .public) reason=can_not_add")
        }
    }

    /// 把 zoom / focus / pressure / activePrimaryConstituent KVO 绑到 capture device。
    /// 虚拟设备架构下整个 session 生命周期内 device 实例不变，只在 configureAndStartSession 末尾调一次。
    func bindDeviceObservers(to device: AVCaptureDevice) {
        zoomObservation?.invalidate()
        focusObservation?.invalidate()
        pressureObservation?.invalidate()
        constituentObservation?.invalidate()

        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] dev, change in
            guard let self, let newZoom = change.newValue else { return }
            let isRamping = dev.isRampingVideoZoom
            Task { @MainActor in
                self.currentZoomFactor = newZoom
                if isRamping { return }
                // 等效焦距 = primaryNativeMm × videoZoomFactor（与系统选哪颗 constituent 无关，
                // 因为 videoZoomFactor 是虚拟设备坐标系下的 FOV 比率）。
                let nativeMm = self.focalInfo.primaryNativeMm
                guard nativeMm > 0 else { return }
                let mm = Float(newZoom) * nativeMm
                let closest = self.focalInfo.options.min { abs($0.mm - mm) < abs($1.mm - mm) }
                if let closest, closest != self.currentFocalLength {
                    self.syncCurrentFocalLength(closest)
                }
            }
        }

        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] _, change in
            guard let self, let isAdjusting = change.newValue, !isAdjusting else { return }
            Task { @MainActor in
                self.onFocusCompleted()
            }
        }

        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] dev, _ in
            guard let self else { return }
            let level = dev.systemPressureState.level
            self.sessionQueue.async {
                self.adjustFrameRateForPressure(device: dev, level: level)
            }
        }

        // activePrimaryConstituentDevice：诊断 .locked 是否生效。.locked 期望该值不会因
        // videoZoomFactor 跨阈值而漂移；漂移即说明锁失效，应在日志里被立刻看见。
        // 顺带承担一个职责：active name 命中 expectedConstituent.localizedName 时清
        // isLensTransitioning——这样 capturePhoto 的 waitForLensSettled 不必硬等 grace 超时,
        // 绝大多数情况几十 ms 就放行。
        // 用 localizedName 字符串对比而非引用对比是因为：AVCaptureDevice 非 Sendable,
        // 把它捕获进 Task @MainActor 在 Swift 6 strict concurrency 下会报 sending 警告；
        // localizedName 在同一 session 生命周期内唯一标识 constituent，String 是 Sendable。
        constituentObservation = device.observe(\.activePrimaryConstituent, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            let activeName = change.newValue.flatMap { $0?.localizedName }
            let logName = activeName ?? "nil"
            Task { @MainActor in
                if self.activeConstituentName != logName {
                    self.activeConstituentName = logName
                    Log.session.info("constituent_active_changed name=\(logName, privacy: .public)")
                }
                if self.isLensTransitioning,
                   let expectedName = self.expectedConstituent?.localizedName,
                   let activeName,
                   activeName == expectedName {
                    // 硬件已切到位。再给一帧 grace（~50ms）让 ZSL ring 收新帧再放行。
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(50))
                        self?.markLensSettled(reason: "constituent_match")
                    }
                }
            }
        }
    }

    // MARK: - 系统压力自适应帧率

    /// 根据系统压力等级动态调整预览帧率，防止过热降频
    nonisolated func adjustFrameRateForPressure(device: AVCaptureDevice, level: AVCaptureDevice.SystemPressureState.Level) {
        let currentNominal = nominalFPSLock.withLock { $0 }
        let adjustedFPS: Double
        if level == .nominal || level == .fair {
            adjustedFPS = currentNominal
        } else if level == .serious {
            adjustedFPS = min(currentNominal, 30.0)
        } else {
            // .critical, .shutdown, or unknown
            adjustedFPS = 24.0
        }

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(adjustedFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(adjustedFPS))
            device.unlockForConfiguration()
            Log.session.info("pressure_adjusted fps=\(Int(adjustedFPS))")
        } catch {
            Log.session.error("pressure_adjust_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 生命周期：暂停 / 恢复 / 停止

    /// 进入后台时调用：停止 capture session 释放摄像头硬件，但**保留** observers / KVO /
    /// rotationCoordinator / videoInput 的配置——回前台时 resumeSessionIfPossible 只需 startRunning,
    /// 不需要重新走整套 configureAndStartSession（节省 ~150ms 启动延迟 + 避免触发权限/format 重选）。
    /// 同时清空 stale pixel buffer，避免回前台瞬间 MTKView 显示老画面。
    func pauseSessionForBackground() {
        guard sessionConfigured else { return }
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
                Log.session.info("session_paused_for_background")
            }
        }
        // 清空 stale buffer：iOS 把 app 拉回前台后，MTKView 第一次重绘前会显示
        // 缓存里的最后一帧（可能是几分钟前的画面）。清空 + 由首帧到达自然触发重绘。
        pixelBufferLock.withLockUnchecked { $0.buffer = nil }
    }

    /// 从后台回到前台、或 sessionInterruptionEnded、或 runtime error 之后调用。
    /// 仅当已配置过且当前不在 running 状态时才 startRunning，避免重复触发。
    func resumeSessionIfPossible() {
        guard sessionConfigured, !sessionInterrupted else {
            Log.session.debug("session_resume_skip configured=\(self.sessionConfigured) interrupted=\(self.sessionInterrupted)")
            return
        }
        let captureSession = session
        sessionQueue.async {
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
            Log.session.info("session_resumed running=\(captureSession.isRunning)")
        }
    }

    /// 停止 session 并释放相机资源（导航离开时调用，防止多 session 竞争）
    func stopSession() {
        // 取消可能仍在 await configureAndStartSession 的启动任务,
        // 避免它在 sessionQueue 上把 startRunning 跑完后我们又得排队 stopRunning。
        startupTask?.cancel()
        startupTask = nil

        stopLocationServices()
        focusHoldTimer?.invalidate()
        focusHoldTimer = nil
        // 及早失效所有 KVO，避免 session 停止期间仍有回调被派发到已释放的闭包
        focusObservation?.invalidate()
        focusObservation = nil
        zoomObservation?.invalidate()
        zoomObservation = nil
        pressureObservation?.invalidate()
        pressureObservation = nil
        captureRotationObservation?.invalidate()
        captureRotationObservation = nil
        constituentObservation?.invalidate()
        constituentObservation = nil
        currentVideoInput = nil
        // 清空 buffer（避免 stopRunning 后 MTKView 还显示上次的 frame）
        pixelBufferLock.withLockUnchecked { $0.buffer = nil }
        // 取消 NotificationCenter observer（deinit 因 Swift 6 隔离规则无法访问这些属性）
        if let subjectObserver = subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectObserver)
            subjectAreaObserver = nil
        }
        if let observer = sessionInterruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            sessionInterruptionObserver = nil
        }
        if let observer = sessionInterruptionEndedObserver {
            NotificationCenter.default.removeObserver(observer)
            sessionInterruptionEndedObserver = nil
        }
        if let observer = sessionRuntimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            sessionRuntimeErrorObserver = nil
        }
        sessionConfigured = false
        sessionInterrupted = false
        // 停止加速度计读取（与 setupOrientationMonitoring 配对）
        stopAccelerometerOrientationUpdates()
        previewMTKView = nil

        // setSampleBufferDelegate(nil) 与 stopRunning() 都是阻塞调用——主线程同步执行
        // 会让左滑返回动画卡顿。整体下放到 sessionQueue。
        let captureSession = session
        let videoOutput = videoDataOutput
        sessionQueue.async {
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            if captureSession.isRunning {
                captureSession.stopRunning()
                Log.session.info("session_stopped")
            }
        }
    }

    // MARK: - 设备数据 dump（调试用）
    //
    // 一次性打印当前后置虚拟设备 / 会话的所有可读数据，便于调试与设备适配。
    // 必须在 session 配置完成后调用，否则 activeFormat / 缩放范围 / maxPhotoDimensions 会读到默认值。
    // nonisolated + 所有依赖通过 LensDumpArgs 传入：可在 background QoS task 上跑，不占用主 actor。

    nonisolated static func dumpLensSpecsImpl(args: LensDumpArgs) {
        let device = args.device
        let focalInfo = args.focalInfo
        let photoOutput = args.photoOutput
        let videoDataOutput = args.videoDataOutput
        let log = Log.session
        let modelID = hardwareModelIdentifier()
        let pos: String = {
            switch device.position {
            case .back: return "back"
            case .front: return "front"
            case .unspecified: return "unspecified"
            @unknown default: return "unknown"
            }
        }()

        log.info("📷 lens_dump_begin hw=\(modelID, privacy: .public)")

        // 1) 设备身份
        log.info("📷 device id=\(device.uniqueID, privacy: .public) name=\(device.localizedName, privacy: .public) modelID=\(device.modelID, privacy: .public) manufacturer=\(device.manufacturer, privacy: .public) type=\(device.deviceType.rawValue, privacy: .public) position=\(pos, privacy: .public) virtual=\(device.isVirtualDevice)")

        // 2) Constituent devices（虚拟设备的物理镜头组成）+ switchOver 阈值
        let constituentList = device.constituentDevices.map { c in
            "\(c.localizedName)/\(String(format: "%.1f", c.nominalFocalLengthIn35mmFilm))mm"
        }.joined(separator: ", ")
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { String(format: "%.2f", CGFloat(truncating: $0)) }.joined(separator: ",")
        log.info("📷 constituents [\(constituentList, privacy: .public)] switchOvers=[\(switchOvers, privacy: .public)]")
        log.info("📷 optics current_device=\(device.localizedName, privacy: .public) aperture=f/\(String(format: "%.2f", device.lensAperture)) primaryMm=\(focalInfo.primaryNativeMm) focalOptions=\(focalInfo.options.map { $0.rawValue }, privacy: .public)")

        // 4) 缩放范围 / 当前缩放
        let fmt = device.activeFormat
        log.info("📷 zoom min=\(String(format: "%.2f", device.minAvailableVideoZoomFactor)) max=\(String(format: "%.2f", device.maxAvailableVideoZoomFactor)) format_max=\(String(format: "%.2f", fmt.videoMaxZoomFactor)) current=\(String(format: "%.3f", device.videoZoomFactor)) upscale_threshold=\(String(format: "%.2f", fmt.videoZoomFactorUpscaleThreshold))")

        // 5) 当前 active format
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let fpsRanges = fmt.videoSupportedFrameRateRanges
            .map { "\(Int($0.minFrameRate))–\(Int($0.maxFrameRate))" }
            .joined(separator: ",")
        let colorSpaces = fmt.supportedColorSpaces.map { String(describing: $0) }.joined(separator: ",")
        log.info("📷 active_format dims=\(dims.width)x\(dims.height) fov=\(String(format: "%.2f", fmt.videoFieldOfView))° fps=[\(fpsRanges, privacy: .public)] iso=\(Int(fmt.minISO))–\(Int(fmt.maxISO)) exposure=\(CMTimeGetSeconds(fmt.minExposureDuration))s–\(CMTimeGetSeconds(fmt.maxExposureDuration))s binned=\(fmt.isVideoBinned) hdr=\(fmt.isVideoHDRSupported) color_spaces=[\(colorSpaces, privacy: .public)] active_color=\(String(describing: device.activeColorSpace), privacy: .public)")

        // 6) 照片输出能力
        let photoDims = fmt.supportedMaxPhotoDimensions
            .map { "\($0.width)x\($0.height)" }
            .joined(separator: ",")
        let outDims = photoOutput.maxPhotoDimensions
        let qPri: String = {
            switch photoOutput.maxPhotoQualityPrioritization {
            case .speed: return "speed"
            case .balanced: return "balanced"
            case .quality: return "quality"
            @unknown default: return "unknown"
            }
        }()
        log.info("📷 photo_caps supported=[\(photoDims, privacy: .public)] selected=\(outDims.width)x\(outDims.height) responsive=\(photoOutput.isResponsiveCaptureEnabled) fast_capture=\(photoOutput.isFastCapturePrioritizationEnabled) zsl=\(photoOutput.isZeroShutterLagEnabled) constant_color=\(photoOutput.isConstantColorSupported) quality_pri=\(qPri, privacy: .public)")

        // 7) 闪光灯/低光增强
        log.info("📷 flash has_flash=\(device.hasFlash) flash_available=\(device.isFlashAvailable) torch=\(device.hasTorch) low_light_supported=\(device.isLowLightBoostSupported) low_light_active=\(device.isLowLightBoostEnabled)")

        // 8) 对焦/曝光/白平衡 模式
        let focusModes: [(AVCaptureDevice.FocusMode, String)] = [(.locked, "locked"), (.autoFocus, "auto"), (.continuousAutoFocus, "continuous")]
        let supportedFocus = focusModes.filter { device.isFocusModeSupported($0.0) }.map { $0.1 }.joined(separator: ",")
        let exposureModes: [(AVCaptureDevice.ExposureMode, String)] = [(.locked, "locked"), (.autoExpose, "auto"), (.continuousAutoExposure, "continuous"), (.custom, "custom")]
        let supportedExposure = exposureModes.filter { device.isExposureModeSupported($0.0) }.map { $0.1 }.joined(separator: ",")
        let wbModes: [(AVCaptureDevice.WhiteBalanceMode, String)] = [(.locked, "locked"), (.autoWhiteBalance, "auto"), (.continuousAutoWhiteBalance, "continuous")]
        let supportedWB = wbModes.filter { device.isWhiteBalanceModeSupported($0.0) }.map { $0.1 }.joined(separator: ",")
        log.info("📷 modes focus_supported=[\(supportedFocus, privacy: .public)] focus_current=\(device.focusMode.rawValue) exposure_supported=[\(supportedExposure, privacy: .public)] exposure_current=\(device.exposureMode.rawValue) wb_supported=[\(supportedWB, privacy: .public)] wb_current=\(device.whiteBalanceMode.rawValue) smooth_focus=\(device.isSmoothAutoFocusEnabled) subject_area_monitor=\(device.isSubjectAreaChangeMonitoringEnabled)")

        // 8.5) 视频防抖
        let stabModes: [(AVCaptureVideoStabilizationMode, String)] = [
            (.off, "off"), (.standard, "std"), (.cinematic, "cine"),
            (.cinematicExtended, "cineExt"), (.cinematicExtendedEnhanced, "cineExtEnh"),
            (.previewOptimized, "preview"), (.lowLatency, "lowLat"), (.auto, "auto")
        ]
        let supportedStab = stabModes.filter { fmt.isVideoStabilizationModeSupported($0.0) }.map { $0.1 }.joined(separator: ",")
        let stabName: (AVCaptureVideoStabilizationMode) -> String = { mode in
            switch mode {
            case .off: return "off"
            case .standard: return "std"
            case .cinematic: return "cine"
            case .cinematicExtended: return "cineExt"
            case .cinematicExtendedEnhanced: return "cineExtEnh"
            case .previewOptimized: return "preview"
            case .lowLatency: return "lowLat"
            case .auto: return "auto"
            @unknown default: return "unknown"
            }
        }
        if let conn = videoDataOutput.connection(with: .video) {
            log.info("📷 stabilization supported=[\(supportedStab, privacy: .public)] active=\(stabName(conn.activeVideoStabilizationMode), privacy: .public) preferred=\(stabName(conn.preferredVideoStabilizationMode), privacy: .public)")
        } else {
            log.info("📷 stabilization supported=[\(supportedStab, privacy: .public)] active=no_video_connection")
        }

        // 9) 实时曝光/对焦读数（瞬时值，仅供参考）
        let expSec = CMTimeGetSeconds(device.exposureDuration)
        let expReadable = expSec > 0 && expSec < 1 ? "1/\(Int(round(1.0 / expSec)))s" : String(format: "%.3fs", expSec)
        let wbGains = device.deviceWhiteBalanceGains
        log.info("📷 live iso=\(Int(device.iso)) exposure=\(expReadable, privacy: .public) lens_position=\(String(format: "%.3f", device.lensPosition)) target_bias=\(String(format: "%.2f", device.exposureTargetBias))ev target_offset=\(String(format: "%.2f", device.exposureTargetOffset))ev bias_range=\(String(format: "%.1f", device.minExposureTargetBias))–\(String(format: "%.1f", device.maxExposureTargetBias)) wb_gains=[r=\(String(format: "%.2f", wbGains.redGain)) g=\(String(format: "%.2f", wbGains.greenGain)) b=\(String(format: "%.2f", wbGains.blueGain))] wb_max_gain=\(String(format: "%.2f", device.maxWhiteBalanceGain)) pressure=\(device.systemPressureState.level.rawValue, privacy: .public)")

        // 10) 全部 format 列表
        for (i, f) in device.formats.enumerated() {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let maxFPS = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let isActive = (f === fmt) ? " *" : ""
            let photoCaps = f.supportedMaxPhotoDimensions
                .map { "\($0.width)x\($0.height)" }
                .joined(separator: ",")
            log.info("📷 format[\(i)]\(isActive, privacy: .public) dims=\(d.width)x\(d.height) fov=\(String(format: "%.1f", f.videoFieldOfView))° max_fps=\(Int(maxFPS)) binned=\(f.isVideoBinned) hdr=\(f.isVideoHDRSupported) photo_caps=[\(photoCaps, privacy: .public)]")
        }

        log.info("📷 lens_dump_end")
    }

    /// 原始硬件标识（如 "iPhone18,3"）。仅用于日志排查，不再参与焦距推算
    /// （iOS 26 的 `nominalFocalLengthIn35mmFilm` 已让查表式硬编码彻底过时）。
    nonisolated static func hardwareModelIdentifier() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce("") { acc, el in
            guard let v = el.value as? Int8, v != 0 else { return acc }
            return acc + String(Character(UnicodeScalar(UInt8(v))))
        }
        #endif
    }
}
