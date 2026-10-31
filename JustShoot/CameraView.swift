import SwiftUI
import SwiftData
import UIKit
import Foundation
import AVKit
import os

// MARK: - 拍摄页（SwiftUI shell）
//
// 本文件只保留 CameraView 这一 SwiftUI 视图层。所有 capture 引擎实现已拆到：
//   - CameraManager.swift：会话、方向、镜头、权限与拍摄状态机
//   - DeviceFocalInfo.swift（焦段数据层）
//   - CameraSubviews.swift（FocusIndicatorView / ExposureSunRail / FocalLengthStrip / FilmSourceCoverThumbnail / FlashMode / openAppSettings）
//   - MetalPreview.swift（RealtimePreviewView + Metal Coordinator）

struct CameraView: View {
    /// 当前胶片源；预览 LUT、胶片封面与最近照片 badge 随选择更新。
    @State private var source: FilmSource
    /// Preserve the saved Live Photo preference; the still-photo format is automatic.
    @AppStorage("photoCaptureMode") private var captureModeValue = PhotoCaptureMode.quality.rawValue
    /// Live Photo 是否录音（设置页可配置，默认开）。开启时麦克风挂上 session、Live 视频带声音；
    /// 关闭则静音。与顶栏 livePhotoEnabled 一起决定是否挂麦克风——见 CameraManager.setLivePhotoAudio。
    @AppStorage("livePhotoSoundEnabled") private var livePhotoSoundEnabled = true
    /// 曲线目录同时提供当前选择、默认曲线显隐及用户自定义曲线。
    @EnvironmentObject private var curveLibrary: FilmCurveLibrary
    /// Picker 候选列表里需要展示用户导入的自定义 LUT；CameraView 自己持有 @Query 直接喂给 strip。
    @Query(sort: \CustomLUT.createdAt, order: .reverse) private var customLUTs: [CustomLUT]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var cameraManager: CameraManager
    @State private var showFlash = false
    /// 曝光窗口去抖：仅守护 tap → 静态图就绪（含闪光灯 AE/WB 还原）这一小段（live/非 live 都 ~300ms）。
    /// 由 cameraManager 的 `onShutterReady` 回调放开——**不再等 live 配对视频的 ~1.5s 录制窗口**。
    /// 放开后用户即可按下一张；在途的多张拍照由 CameraManager 按 uniqueID 分桶、互不覆盖。
    @State private var isShutterBusy = false
    @ObservedObject private var capturePipeline = CapturePipeline.shared
    @State private var preparedLUT: (key: String, lut: CubeLUT, texture: PreviewLUTTexture,
        profile: FilmRenderProfile, adjustment: ResolvedCameraColorAdjustment?)?
    @State private var lutPreparationCadence = CameraLUTPreparationCadence()
    @State private var entryRetryRevision: UInt64 = 0
    @State private var preparedPickerCovers: [FilmPreset: UIImage] = [:]
    @State private var colorControls = CameraColorControlsState()
    @State private var shutterPressed = false
    /// 拍照 pipeline 完成时立即 push 进来的 88pt 缩略图 hint（避免等 @Query 通知链 ~300-500ms）。
    /// RecentPhotosBadge 通过 @Binding 读写：source 切换时它会清空 hint 并从新 source 的 @Query
    /// 重新 bootstrap。
    @State private var lastPhotoThumbnail: RecentPhotoThumbnail?
    @State private var isReviewingPhotos = false
    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusIndicator = false
    /// tap+drag 手势状态：值为 nil 表示当前没有进行中的手势——onEnded 时清空。
    @State private var dragStartLocation: CGPoint? = nil
    /// 当前手势是否已进入"上下滑动调 EV"模式。一旦进入，后续移动只调 bias，不再切回对焦。
    @State private var isAdjustingExposure = false
    /// 进入 EV 模式时记录的基线 bias。新 bias = 基线 + drag delta，让"活动对焦下继续微调"是连续的，
    /// 而不是每次手势从 0 开始（否则用户拖到 +0.8 后再来一次小调整就被打回 0 附近，体感很糟）。
    @State private var biasAtDragStart: Float = 0
    /// 本次手势是否由触摸落下时主动展示了 reticle。关键用途：onEnded 判定为非 tap 非 EV 时，
    /// 仅在 didShowReticleThisGesture==true 才撤销 reticle——避免把上一次活动对焦的 reticle 误抹掉。
    @State private var didShowReticleThisGesture = false
    /// 拍照失败提示。photo data nil / LUT 失败 / SwiftData save 失败时弹 alert，
    /// 不再静默——避免用户以为拍成功而相册没新照片。
    @State private var captureError: String?
    /// 胶片与曲线面板展开状态。选择后保持展开，以便连续比较。
    @State private var showFilmPicker = false
    /// 从相机曲线条直接进入管理页；保存后曲线条和实时预览由 EnvironmentObject 自动刷新。
    @State private var showCurveManager = false
    /// 预览左右滑动切胶片：手势开始时的 allFilmSources 索引基线。每次 onChanged 累加 delta
    /// 后映射到目标 index，与 iPhone 原相机滤镜横滑切换同手感。nil = 当前没有 swipe 进行中。
    @State private var dragStartFilmIndex: Int? = nil
    @State private var previewGestureRouting = PreviewGestureRouting()
    @State private var gestureAllowsFilmSwipe = false
    @State private var gestureOrientation: UIDeviceOrientation = .portrait
    @GestureState private var previewGestureActive = false

    init(source: FilmSource) {
        _source = State(initialValue: source)
        _cameraManager = StateObject(wrappedValue: CameraManager())
    }

    var body: some View {
        cameraContent
        .allowsHitTesting(!cameraManager.entryPreparation.coversContent)
        .accessibilityHidden(cameraManager.entryPreparation.coversContent)
        .overlay {
            if cameraManager.entryPreparation.coversContent {
                cameraPreparationScreen
                    .ignoresSafeArea()
                    .zIndex(100)
            }
        }
        // Keep Back outside the covered/disabled controls, including during camera preparation.
        .cameraButtonOnlyNavigation(customBackButton: isIPad)
        .overlay {
            if isIPad { iPadBackButton }
        }
        .ignoresSafeArea(.container, edges: isIPad ? .all : [])
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            Diagnostics.start()
            let manager = cameraManager
            DiagnosticWatchdog.shared.addCamera(id: manager.diagnostics.id, flow: manager.flowDiagnostics) { [weak manager] in manager?.previewHealth() }
            manager.diagnostics.event("camera_view_appear")
            cameraManager.setEntrySceneActive(scenePhase == .active)
            cameraManager.updateEntryPipelineReady(capturePipeline.isPrepared)
            cameraManager.updateEntryLUT(expectedKey: previewLUTKey, preparedKey: preparedLUT?.key)
            cameraManager.requestCameraPermission()
            // 告知期望录音状态（live && sound）；session 配置完成后据此决定是否挂麦克风。
            cameraManager.setLivePhotoAudio(live: wantsLiveCapture, sound: livePhotoSoundEnabled)
        }
        // 顶栏 Live 开关 / 设置页声音开关变化时，实时增删麦克风输入（在相机页内切换即时生效）。
        .onChange(of: captureModeValue) { _, _ in
            cameraManager.diagnostics.event("live_photo_preference_changed", "requested=\(wantsLiveCapture) supported=\(cameraManager.livePhotoCaptureState.supported) enabled=\(cameraManager.livePhotoCaptureState.enabled)")
            cameraManager.setLivePhotoAudio(live: wantsLiveCapture, sound: livePhotoSoundEnabled)
        }
        .onChange(of: livePhotoSoundEnabled) { _, _ in
            cameraManager.setLivePhotoAudio(live: wantsLiveCapture, sound: livePhotoSoundEnabled)
        }
        .onChange(of: cameraManager.flashMode) { _, mode in
            cameraManager.diagnostics.event("flash_changed", "mode=\(mode.rawValue)")
        }
        .onChange(of: isShutterBusy) { _, busy in
            cameraManager.diagnostics.event("camera_controls_changed", "shutter_busy=\(busy) readiness=\(cameraManager.readiness.logValue)")
        }
        .onChange(of: showFlash) { _, visible in
            cameraManager.diagnostics.event("shutter_overlay_changed", "visible=\(visible)")
        }
        .onChange(of: previewGestureActive) { _, active in
            if !active { resetPreviewGesture() }
        }
        .onChange(of: previewLUTKey) { _, key in
            cameraManager.updateEntryLUT(expectedKey: key, preparedKey: preparedLUT?.key)
            cameraManager.setLivePhotoAudio(live: wantsLiveCapture, sound: livePhotoSoundEnabled)
        }
        .onChange(of: capturePipeline.isPrepared) { _, ready in
            cameraManager.updateEntryPipelineReady(ready)
        }
        .task(id: cameraManager.entryPreparation.isRevealed) {
            // The hidden picker must not delay first preview or compete with entry preparation.
            guard cameraManager.entryPreparation.isRevealed, preparedPickerCovers.isEmpty else { return }
            do {
                let covers = try await FilmSourcePickerStrip.preloadCovers(displayScale: displayScale)
                try Task.checkCancellation()
                preparedPickerCovers = covers
            } catch is CancellationError {
                return
            } catch {
                cameraManager.diagnostics.event("camera_picker_covers_failed", Diagnostics.errorFields(error))
            }
        }
        // 编辑当前用户曲线时 ID 不变、内容指纹会变化；监听完整后缀可确保新 LUT 立即预热。
        .task(id: previewLUTKey + "#retry-\(entryRetryRevision)") {
            let key = previewLUTKey
            cameraManager.updateEntryLUT(expectedKey: key, preparedKey: preparedLUT?.key)
            guard preparedLUT?.key != key else { return }
            let requestedSource = source
            let curve = selectedCurve
            let curveFields = curveDiagnosticFields(curve)
            let selection = colorControls.temperature
            let tint = colorControls.tint
            let reference = cameraManager.automaticWhiteBalanceReading
            guard ResolvedCameraColorAdjustment.resolve(temperature: selection, tint: tint, reading: reference) != nil else {
                cameraManager.diagnostics.event("color_adjustment_waiting", "reason=automatic_reading_unavailable")
                return
            }
            let requestedAt = ProcessInfo.processInfo.systemUptime
            let delay = lutPreparationCadence.delay(at: requestedAt)
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try Task.checkCancellation()
            } catch { return }
            guard key == previewLUTKey else { return }
            lutPreparationCadence.started(at: ProcessInfo.processInfo.systemUptime)
            let lutWait = cameraManager.diagnostics.span("camera_lut_prepare",
                "\(curveFields) \(colorAdjustmentDiagnosticFields) cadence_wait_ms=\(Diagnostics.milliseconds(since: requestedAt))")
            do {
                let lut = try await ColorTemperatureLUT.shared.prepare(source: requestedSource, curve: curve, selection: selection, tint: tint, reference: reference)
                try await FilmCapturePreparation.shared.prepareRendering()
                try Task.checkCancellation()
                let texture = try await PreviewLUTTextureCache.shared.prepare(key: key, lut: lut)
                lutWait.end("ok", "cancelled=\(Task.isCancelled)")
                guard !Task.isCancelled, key == previewLUTKey else { return }
                let adjustment = selection.isAutomatic && tint.isAutomatic ? nil
                    : ResolvedCameraColorAdjustment.resolve(temperature: selection, tint: tint, reading: reference)
                preparedLUT = (key, lut, texture, requestedSource.captureRenderProfile, adjustment)
                cameraManager.updateEntryLUT(expectedKey: key, preparedKey: key)
                cameraManager.diagnostics.event("camera_lut_ready", "dimension=\(lut.dimension) \(curveFields) \(colorAdjustmentDiagnosticFields)")
                await waitForCurrentLookPresentation(key: key)
            } catch is CancellationError {
                lutWait.end("cancelled")
            } catch let error as PreviewLUTTextureCache.PreparationError {
                lutWait.end("error", Diagnostics.errorFields(error))
                guard !Task.isCancelled, key == previewLUTKey else { return }
                if cameraManager.entryPreparation.isRevealed {
                    captureError = String(localized: "The camera preview could not be prepared. Please try again.")
                } else {
                    cameraManager.previewRendererUnavailable()
                }
            } catch {
                lutWait.end("error", Diagnostics.errorFields(error))
                guard !Task.isCancelled, key == previewLUTKey else { return }
                if !selection.isAutomatic || !tint.isAutomatic {
                    colorControls.resetAutomatic()
                    captureError = String(localized: "Color adjustments could not be applied. Auto has been restored.")
                } else {
                    if !cameraManager.entryLUTPreparationFailed(key: key) {
                        captureError = String(localized: "This LUT is invalid or unsupported.")
                    }
                }
            }
        }
        .onReceive(capturePipeline.$lastCompletion) { completion in
            guard let completion, completion.filterName == source.photoFilterName else { return }
            guard lastPhotoThumbnail?.filterName != completion.filterName
                || (lastPhotoThumbnail?.captureDate ?? .distantPast) <= completion.captureDate else { return }
            lastPhotoThumbnail = RecentPhotoThumbnail(id: completion.id, filterName: completion.filterName,
                image: completion.thumbnail, captureDate: completion.captureDate)
        }
        .onDisappear {
            cameraManager.diagnostics.event("camera_view_disappear")
            DiagnosticWatchdog.shared.removeCamera(id: cameraManager.diagnostics.id)
            cameraManager.stopSession()
        }
        // 后台/前台切换：按 Home 键 / 切到其他 app → pause；回前台 → resume。
        // 不在 .background 完整 stopSession，因为 onDisappear 没触发（页面仍在导航栈），
        // 只调 pauseSessionForBackground 释放摄像头硬件，配置/observers 全部保留。
        // 没有这条监听，回前台只看到黑屏（pixelBuffer 是 stale 的）+ session 不再产帧。
        .onChange(of: scenePhase) { _, newPhase in
            cameraManager.setEntrySceneActive(newPhase == .active)
            switch newPhase {
            case .background:
                cameraManager.pauseSessionForBackground()
            case .inactive:
                break
            case .active:
                cameraManager.resumeSessionIfPossible()
            @unknown default:
                break
            }
        }
        // Camera Control 硬件快门按钮（iPhone 16+）
        .cameraShutterEvent { Task { await capturePhoto() } }
        .alert("Capture failed", isPresented: Binding(
            get: { captureError != nil },
            set: { if !$0 { captureError = nil } }
        )) {
            if preparedLUT?.key != previewLUTKey {
                Button("Try Again") { retryCameraEntry() }
            }
            Button("OK", role: .cancel) { captureError = nil }
        } message: {
            Text(captureError ?? "")
        }
        .sheet(isPresented: $showCurveManager) {
            NavigationStack {
                FilmCurveLibraryView(showsDoneButton: true)
            }
            .preferredColorScheme(.dark)
        }
    }

    private var cameraContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if isIPad {
                    iPadCameraContent
                } else {
                    iPhoneCameraContent
                }
            }
            .disabled(cameraManager.readiness != .ready || isShutterBusy)
            .allowsHitTesting(cameraManager.readiness == .ready && !isShutterBusy)
            .accessibilityHidden(cameraManager.readiness != .ready)

            // 快门闪光效果——模拟柯达 / 富士即时相机的氙气闪光膜质感：
            // 1) 主层 0.78 不到纯白，给暖色 gradient 留出对比空间
            // 2) 中心暖色 radial gradient (~3200K 钨丝色温)，模拟氙气 + 琥珀色滤光的真实闪光
            // 3) 边缘暗角，模拟反射板边缘衰减——只在角落，避免减弱主反馈
            // 三层用 ZStack 组合，blendMode(.screen) 保证暖光叠加更亮而非覆盖
            if showFlash {
                ZStack {
                    Color.white
                        .ignoresSafeArea()
                        .opacity(0.78)
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color(red: 1.0, green: 0.94, blue: 0.82).opacity(0.35),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 500
                    )
                    .ignoresSafeArea()
                    .blendMode(.screen)
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.clear,
                            Color.black.opacity(0.18)
                        ]),
                        center: .center,
                        startRadius: 280,
                        endRadius: 720
                    )
                    .ignoresSafeArea()
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.22), value: cameraManager.readiness)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // 全屏相机 push 时隐藏底部 tab 栏——否则 tab 栏会压在取景器/快门之上。
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !isIPad && !cameraManager.entryPreparation.coversContent {
                // 中间：仅可选的位置状态（胶片名标题已去掉——当前胶片由底部右下封面 + picker 表达，
                // 取景器中央保持干净）。位置被拒时才显示一个警示按钮。
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        if cameraManager.locationPermissionDenied {
                            Button(action: openAppSettings) {
                                Label("Location off", systemImage: "location.slash.fill")
                                    .font(.caption2.weight(.medium))
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(.orange.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Location off")
                            .accessibilityHint("Open Settings and allow Location Services to geo-tag photos")
                        }
                    }
                }

                // Keep the control visible while support/enablement is being negotiated.
                // If availability is lost, an existing On preference can still be switched Off.
                if LivePhotoEncoderConfiguration.isSupported {
                    ToolbarItem(placement: .primaryAction) {
                        livePhotoControl
                    }
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                }

                ToolbarItem(placement: .primaryAction) { flashControl }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }

                ToolbarItem(placement: .primaryAction) { colorControl }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: isIPad ? 0 : nil) {
            if !isIPad {
                HStack {
                    recentPhotosControl
                    Spacer()
                    shutterControl
                    Spacer()
                    filmPickerControl
                }
                .padding(.horizontal, 16)
                .pageContentWidth(PageLayout.cameraControlsWidth)
                .padding(.bottom, 10)
                .disabled(cameraManager.readiness != .ready || isShutterBusy)
                .opacity(cameraManager.readiness == .ready ? 1 : 0.42)
                .animation(.easeOut(duration: 0.2), value: cameraManager.readiness)
            }
        }
    }

    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var iPhoneCameraContent: some View {
        VStack(spacing: 12) {
            viewfinder
            focalLengthControl.padding(.horizontal, 16)
            if showFilmPicker {
                filmCurvePicker
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .padding(.horizontal, 16)
                    .pageContentWidth(PageLayout.cameraControlsWidth)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                filmSourcePicker
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .padding(.horizontal, 16)
                    .pageContentWidth(PageLayout.cameraControlsWidth)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var iPadBackButton: some View {
        GeometryReader { geometry in
            let layout = IPadCameraLayoutGeometry(size: geometry.size, aspect: cameraManager.previewAspectRatio,
                pickerHeight: IPadCameraLayoutGeometry.pickerHeight(for: sizeClass),
                toolCount: LivePhotoEncoderConfiguration.isSupported ? 4 : 3,
                zoomCount: cameraManager.focalInfo.options.count)
            IPadCameraBackButton().position(layout.back)
        }
    }

    private var iPadCameraContent: some View {
        IPadCameraLayout(aspect: cameraManager.previewAspectRatio, showsPicker: showFilmPicker,
            toolCount: LivePhotoEncoderConfiguration.isSupported ? 4 : 3,
            zoomCount: cameraManager.focalInfo.options.count) {
            viewfinder
        } tools: { axis in
            IPadCameraTools(axis: axis) {
                flashControl.iPadCameraTool(compact: axis == .horizontal)
                if LivePhotoEncoderConfiguration.isSupported {
                    livePhotoControl.iPadCameraTool(compact: axis == .horizontal)
                }
                colorControl.iPadCameraTool(compact: axis == .horizontal)
                filmPickerButton(size: axis == .horizontal ? 44 : 56)
            }
        } shutter: {
            shutterControl
        } recentPhoto: {
            recentPhotosControl
        } zoom: {
            iPadFocalLengthControl
        } picker: {
            IPadCameraLookPanel {
                filmCurvePicker
            } films: {
                filmSourcePicker
            }
        } overlays: { layout in
            if colorControls.isVisible {
                let frame = layout.adjustmentFrame(showsPicker: showFilmPicker)
                whiteBalanceControls
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
            if abs(cameraManager.exposureBias) > 0.01 || isAdjustingExposure {
                exposureControl.position(layout.exposurePosition(
                    showsColorControls: colorControls.isVisible, showsPicker: showFilmPicker))
            }
            if cameraManager.locationPermissionDenied {
                Button(action: openAppSettings) {
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .cameraControlSurface()
                .accessibilityLabel("Location off")
                .accessibilityHint("Open Settings and allow Location Services to geo-tag photos")
                .position(x: 108, y: 38)
            }
        }
    }

    private var iPadFocalLengthControl: some View {
        FocalLengthStrip(
            focalInfo: cameraManager.focalInfo,
            current: cameraManager.currentFocalLength,
            contentRotation: controlRotationAngle,
            axis: .vertical
        ) { option in
            cameraManager.hapticSoft.impactOccurred()
            cameraManager.setFocalLength(option)
        }
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Keep the preview mounted and opaque while the independent entry
                // cover is visible, so Metal can obtain and render its first drawable.
                Group {
                    // 镜头切换过渡底衬：系统合成预览层（Apple 官方推荐的预览显示路径），
                    // 切镜头时拿到系统 crossfade 而非停帧。常态完全被上层 Metal 预览盖住
                    //（opacity 0）；镜头切换停顿的窗口内由 PreviewUnderlayBlender 把上层淡出、
                    // 露出这层实时画面。见 MetalPreview.swift 与 LensTransitionCompositor.swift。
                    CameraPreviewUnderlayView(manager: cameraManager)
                        .clipShape(RoundedRectangle(cornerRadius: isIPad ? 0 : 12, style: .continuous))
                        .allowsHitTesting(false)

                    // 虚拟设备架构：constituent 切换由系统在内部完成（硬件级 crossfade,
                    // 预览不黑屏），不再需要 bridgeImage 帧桥接。
                    // 手势挂在预览视图上：tap 落点设对焦点，随后 |dy|>8pt 切到曝光补偿。
                    RealtimePreviewView(
                        manager: cameraManager,
                        lutCacheKey: preparedLUT?.key ?? previewLUTKey,
                        preparedLUT: preparedLUT?.texture,
                        grain: preparedLUT?.profile.grain ?? source.captureRenderProfile.grain,
                        optics: preparedLUT?.profile.optics ?? source.captureRenderProfile.optics,
                        chromatic: preparedLUT?.profile.effectiveChromatic ?? source.captureRenderProfile.effectiveChromatic,
                        isContentVisible: !isReviewingPhotos
                    )
                        .id(entryRetryRevision)
                        .clipShape(RoundedRectangle(cornerRadius: isIPad ? 0 : 12, style: .continuous))
                        .contentShape(Rectangle())
                        .gesture(unifiedPreviewGesture(viewportSize: geometry.size))
                }

                if showFocusIndicator, let point = focusPoint {
                    FocusIndicatorView()
                        .position(point)
                        .allowsHitTesting(false)

                    // 曝光补偿 sun rail（iPhone Camera 风格）：靠近预览右边缘时翻到对焦框左侧,
                    // 永远保持在可视区域内。allowsHitTesting(false) 让手势穿透到下层预览,
                    // 用户可以直接在 sun 图标上继续拖动。
                    ExposureSunRail(
                        bias: cameraManager.exposureBias,
                        range: cameraManager.exposureRange,
                        isAdjusting: isAdjustingExposure
                    )
                    // 长轴始终沿用户视角竖直——controlRotationAngle 把内容旋转到用户上方为正。
                    // sunYOffset(bias>0) 在旋转后的局部坐标里 = "用户视角向上"，与上滑变亮的手势同向。
                    .rotationEffect(controlRotationAngle)
                    .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.controlsOrientation)
                    .position(sunRailPosition(focus: point, viewport: geometry.size))
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if !isIPad && colorControls.isVisible {
                    whiteBalanceControls
                }
            }
            .overlay(alignment: .topLeading) {
                if !isIPad && (abs(cameraManager.exposureBias) > 0.01 || isAdjustingExposure) {
                    exposureControl
                        .padding(.horizontal, 10)
                        .padding(.top, colorControls.isVisible ? 64 : 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Match the full-width photo viewer as well as the still's aspect.
        .aspectRatio(cameraManager.previewAspectRatio, contentMode: .fit)
    }

    private var focalLengthControl: some View {
        FocalLengthStrip(
            focalInfo: cameraManager.focalInfo,
            current: cameraManager.currentFocalLength,
            contentRotation: controlRotationAngle
        ) { option in
            cameraManager.hapticSoft.impactOccurred()
            cameraManager.setFocalLength(option)
        }
    }

    private var filmCurvePicker: some View {
        FilmCurvePickerStrip(
            curves: curveLibrary.visibleCurves,
            current: selectedCurve,
            contentRotation: controlRotationAngle,
            orientation: cameraManager.controlsOrientation,
            style: isIPad ? .iPadOverlay : .standard,
            onManage: { showCurveManager = true }
        ) { curve in
            guard curveLibrary.canEdit else {
                showCurveManager = true
                return
            }
            if curve.id != selectedCurve.id {
                cameraManager.hapticSoft.impactOccurred()
                curveLibrary.select(curve)
            }
        }
    }

    private var filmSourcePicker: some View {
        FilmSourcePickerStrip(
            current: source,
            customLUTs: customLUTs,
            contentRotation: controlRotationAngle,
            orientation: cameraManager.controlsOrientation,
            preparedCovers: preparedPickerCovers,
            style: isIPad ? .iPadOverlay : .standard
        ) { newSource in
            if newSource.id != source.id {
                cameraManager.hapticSoft.impactOccurred()
                source = newSource
                // 通常 ContentView 启动时已 preload；冷启动后从 picker 第一次切到某胶片
                // 也走一次保险——FilmProcessor cache 命中时零开销。曲线合成条目一并生成。
            }
            // 选择后保留面板，便于连续比较。
        }
    }

    private var recentPhotosControl: some View {
        RecentPhotosBadge(
            source: source,
            lastThumbnailHint: $lastPhotoThumbnail,
            pendingPreview: capturePipeline.lastPreview,
            isShutterBusy: isShutterBusy,
            isProcessing: capturePipeline.pendingCount > 0,
            controlRotationAngle: controlRotationAngle,
            orientation: cameraManager.controlsOrientation,
            onPresentationChanged: { isReviewingPhotos = $0 }
        )
    }

    private var shutterControl: some View {
        CameraShutterButton(
            isCapturing: isShutterBusy,
            isPreparingFilm: preparedLUT?.key != previewLUTKey || !cameraManager.entryPreparation.isCurrentLookRendered,
            canCapture: capturePipeline.canCapture,
            isPressed: shutterPressed
        ) {
            Task { await capturePhoto() }
        }
    }

    private var filmPickerControl: some View {
        filmPickerButton(size: sizeClass == .regular ? 56 : 46)
    }

    private func filmPickerButton(size: CGFloat) -> some View {
        Button {
            cameraManager.hapticLight.impactOccurred()
            withAnimation(.easeInOut(duration: 0.22)) {
                showFilmPicker.toggle()
            }
        } label: {
            // 整块随设备方向旋转，与最近照片角标（RecentPhotosBadge）同款 rotationEffect
            // + 同款 spring，旋转手感完全一致。封面无 glass 描边，整块旋转也不会显得放大。
            FilmSourceCoverThumbnail(source: source)
                .frame(width: size, height: size)
                .overlay {
                    // 展开时给封面一个淡黄色描边，提示当前处于"切换中"状态。
                    if showFilmPicker {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.yellow.opacity(0.85), lineWidth: 1.5)
                    }
                }
                .rotationEffect(controlRotationAngle)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.controlsOrientation)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("camera.film_picker")
        .accessibilityLabel(Text("Switch film"))
        .accessibilityHint(showFilmPicker ? Text("Tap to close film picker") : Text("Tap to pick another film"))
    }

    private var flashControl: some View {
        Button {
            cameraManager.toggleFlashMode()
        } label: {
            Image(systemName: cameraManager.flashMode == .on ? "bolt.fill" : "bolt.slash.fill")
                .foregroundStyle(cameraManager.flashMode == .on ? Color.yellow : .white)
                .rotationEffect(controlRotationAngle)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.controlsOrientation)
        }
        .tint(cameraManager.flashMode == .on ? .yellow : .white)
        .disabled(cameraManager.readiness != .ready || isShutterBusy)
        .opacity(cameraManager.readiness == .ready ? 1 : 0.45)
        .accessibilityLabel(cameraManager.flashMode == .on ? Text("Flash on") : Text("Flash off"))
        .accessibilityHint("Toggle flash")
    }

    private var colorControl: some View {
        Button {
            cameraManager.hapticSoft.impactOccurred()
            let visible = !colorControls.isVisible
            colorControls.setVisible(visible)
            cameraManager.diagnostics.event("color_controls_visibility_changed",
                "visible=\(visible) \(colorAdjustmentDiagnosticFields)")
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(colorControls.isVisible ? Color.yellow : .white)
                .rotationEffect(controlRotationAngle)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.controlsOrientation)
        }
        .buttonBorderShape(.circle)
        .tint(colorControls.isVisible ? .yellow : .white)
        .disabled(isShutterBusy)
        .accessibilityLabel("Color controls")
        .accessibilityHint("Show color controls; hiding restores Auto")
        .accessibilityAddTraits(colorControls.isVisible ? [.isSelected] : [])
        .accessibilityIdentifier("camera.white_balance.toggle")
    }

    private var exposureControl: some View {
        ExposureCompensationControl(bias: cameraManager.exposureBias, setBias: cameraManager.setExposureBias)
        .disabled(isShutterBusy || cameraManager.readiness != .ready)
    }

    private var whiteBalanceControls: some View {
        WhiteBalanceControl(
            selection: colorControls.temperature,
            tint: colorControls.tint,
            automaticReading: cameraManager.automaticWhiteBalanceReading,
            onTemperature: { value in
                if let kelvin = CameraWhiteBalancePolicy.temperature(value) {
                    colorControls.temperature = .temperature(kelvin)
                }
            },
            onTint: { value in
                if let tint = CameraWhiteBalancePolicy.tint(value) { colorControls.tint = .value(tint) }
            },
            onAutomaticTemperature: { colorControls.temperature = .automatic },
            onAutomaticTint: { colorControls.tint = .automatic },
            onEditingEnded: {
                cameraManager.diagnostics.event("color_adjustment_selected", colorAdjustmentDiagnosticFields)
            }
        )
        .disabled(isShutterBusy)
    }

    /// Initial entry has its own readiness timeout. A later look change also
    /// needs a bounded wait if a renderer stops presenting without a GPU error.
    private func waitForCurrentLookPresentation(key: String) async {
        guard let generation = cameraManager.entryPreparation.generation else { return }
        var timer = CameraEntryPreparation.ActiveTimer()
        timer.reset(at: ProcessInfo.processInfo.systemUptime,
            counting: scenePhase == .active && !isReviewingPhotos)
        while !Task.isCancelled, key == previewLUTKey,
              cameraManager.entryPreparation.generation == generation,
              cameraManager.entryPreparation.isRevealed,
              !cameraManager.entryPreparation.isCurrentLookRendered {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled, key == previewLUTKey,
                  cameraManager.entryPreparation.generation == generation,
                  cameraManager.entryPreparation.isRevealed,
                  !cameraManager.entryPreparation.isCurrentLookRendered else { return }
            timer.update(at: ProcessInfo.processInfo.systemUptime,
                counting: scenePhase == .active && !isReviewingPhotos)
            if timer.elapsed >= 6 {
                cameraManager.previewDidFail(generation: generation, lutKey: key)
                return
            }
        }
    }

    private var livePhotoControl: some View {
        Button {
            cameraManager.hapticSoft.impactOccurred()
            let live = !wantsLiveCapture
            // Close capture admission synchronously before publishing the preference.
            // A shutter tap must not resolve a new mode against the previous output.
            cameraManager.setLivePhotoAudio(live: live, sound: livePhotoSoundEnabled)
            captureModeValue = live ? PhotoCaptureMode.livePhoto.rawValue : PhotoCaptureMode.quality.rawValue
        } label: {
            Image(systemName: wantsLiveCapture ? "livephoto" : "livephoto.slash")
                .foregroundStyle(wantsLiveCapture ? Color.yellow : .white)
                .rotationEffect(controlRotationAngle)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.controlsOrientation)
        }
        .tint(wantsLiveCapture ? .yellow : .white)
        .disabled(cameraManager.readiness != .ready || isShutterBusy)
        .opacity(cameraManager.readiness == .ready ? 1 : 0.45)
        .accessibilityIdentifier("camera.live_photo")
        .accessibilityLabel(wantsLiveCapture ? Text("Live Photo on") : Text("Live Photo off"))
        .accessibilityHint("Toggle Live Photo")
    }

    private var selectedCurve: FilmCurve { curveLibrary.selectedCurve }
    private var captureMode: PhotoCaptureMode {
        LivePhotoEncoderConfiguration.isSupported
            ? PhotoCaptureMode(rawValue: captureModeValue) ?? .quality : .quality
    }
    private var wantsLiveCapture: Bool { captureMode == .livePhoto }
    private var capturePlan: PhotoCapturePlan {
        .resolve(mode: captureMode)
    }

    @ViewBuilder
    private var cameraPreparationScreen: some View {
        if let failure = cameraManager.entryPreparation.failure {
            PreparationScreen(
                title: cameraPreparationTitle,
                message: failure == .permissionDenied
                    ? String(localized: "Allow camera access for JustShoot in Settings") : nil,
                isLoading: false,
                actionTitle: failure == .permissionDenied ? "Open Settings" : "Try Again",
                onAction: {
                    if failure == .permissionDenied { openAppSettings() }
                    else { retryCameraEntry() }
                }
            )
        } else {
            // Keep unprepared controls covered without adding a loading screen to camera entry.
            Color.black
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Preparing camera")
                .accessibilityIdentifier("preparation_screen")
        }
    }

    private var cameraPreparationTitle: LocalizedStringKey {
        switch cameraManager.entryPreparation.failure {
        case .permissionDenied: "Camera access required"
        case .cameraUnavailable: "Camera unavailable"
        case .filmUnavailable: "Film unavailable"
        case .previewUnavailable: "Preview unavailable"
        case .timedOut: "Camera timed out"
        case nil: "Preparing camera"
        }
    }

    private func retryCameraEntry() {
        captureError = nil
        preparedLUT = nil
        entryRetryRevision &+= 1
        cameraManager.updateEntryLUT(expectedKey: previewLUTKey, preparedKey: nil)
        cameraManager.retryEntryPreparation()
        cameraManager.setLivePhotoAudio(live: wantsLiveCapture, sound: livePhotoSoundEnabled)
    }
    private var previewLUTKey: String {
        let baseKey = FilmProcessor.shared.composedLUTCacheKey(source.lutCacheKey, curve: selectedCurve)
        return ColorTemperatureLUT.cacheKey(baseKey: baseKey, selection: colorControls.temperature,
            tint: colorControls.tint, reference: cameraManager.automaticWhiteBalanceReading)
    }

    private func curveDiagnosticFields(_ curve: FilmCurve) -> String {
        let suffix = curve.cacheKeySuffix
        return "curve_id=\(curve.id) curve_key=\(suffix.isEmpty ? "identity" : suffix)"
    }

    private var colorAdjustmentDiagnosticFields: String {
        let reading = cameraManager.automaticWhiteBalanceReading
        let resolved = reading.flatMap { ResolvedCameraColorAdjustment.resolve(temperature: colorControls.temperature, tint: colorControls.tint, reading: $0) }
        return "temperature_backend=lut temperature_auto=\(colorControls.temperature.isAutomatic) tint_auto=\(colorControls.tint.isAutomatic) " +
            "kelvin=\(resolved.map { String($0.temperature) } ?? "unavailable") tint=\(resolved.map { String($0.tint) } ?? "unavailable") " +
            "reference_kelvin=\(reading.map { String($0.temperature) } ?? "unavailable") reference_tint=\(reading.map { String($0.tint) } ?? "unavailable")"
    }

    /// 与拍照后立即写入的 thumbnail size 对齐——同 key 命中 NSCache，零额外解码。
    fileprivate static let thumbnailMaxPixel = 88

    private func capturePhoto() async {
        // Reserve bounded storage before exposure. AVFoundation releases the shutter independently
        // of the application-wide durable processing queue.
        guard cameraManager.entryPreparation.isRevealed, cameraManager.readiness == .ready else {
            cameraManager.diagnostics.event("shutter_ignored", "reason=camera_preparing")
            Log.capture.debug("shutter_ignored reason=camera_preparing")
            return
        }
        guard cameraManager.isCaptureAvailable else {
            cameraManager.diagnostics.event("shutter_ignored", "reason=not_available")
            Log.capture.debug("shutter_ignored reason=not_available")
            return
        }
        guard !isShutterBusy else {
            cameraManager.diagnostics.event("shutter_ignored", "reason=shutter_busy")
            Log.capture.debug("shutter_ignored reason=shutter_busy")
            return
        }

        guard let preparedLUT, preparedLUT.key == previewLUTKey,
              cameraManager.entryPreparation.isCurrentLookRendered else {
            cameraManager.diagnostics.event("shutter_ignored", "reason=lut_not_ready")
            return
        }
        guard let admission = cameraManager.beginCaptureAdmission() else {
            cameraManager.diagnostics.event("shutter_ignored", "reason=admission_busy")
            return
        }
        let capturedCurve = selectedCurve
        let curveFields = curveDiagnosticFields(capturedCurve)
        let requestedID = admission.id
        let captureTrace = DiagnosticTrace(id: requestedID.uuidString)
        captureTrace.event("shutter_tap", "camera=\(cameraManager.diagnostics.id) pending=\(capturePipeline.pendingCount) requested_live=\(wantsLiveCapture) \(curveFields) \(colorAdjustmentDiagnosticFields)")
        let tapTime = Log.now()
        // 拍摄时刻快照：相册 creationDate 必须反映按快门的瞬间。后处理已串行排队，若在队列任务
        // 里才求值 Date()，连拍尾部照片的时间会晚数秒到数十秒（Photos 按 creationDate 排序展示）。
        let captureDate = Date()
        Log.capture.info("shutter_tap source=\(source.photoFilterName, privacy: .public) pending_post=\(capturePipeline.pendingCount)")

        let currentSource = source
        // 快门时刻的曲线快照——拍照是异步链，用户可能在后处理途中改曲线；
        // 这里固化合成键，预览所见（拍摄瞬间）与成片一致。
        // 自动渲染配置与随机基种子也在快门时刻固化。后续切换胶片不会改变已排队照片；
        // Live Photo 用同一基种子按时间戳派生逐帧 seed，静态帧与标记时刻保持连续。
        let renderProfile = preparedLUT.profile
        // Keep the scene reading for diagnostics; the actual render gain is frozen
        // from the completed preview frame, including its temporal smoothing.
        let chromaticSceneCCT = cameraManager.automaticWhiteBalanceReading?.temperature
        let location = cameraManager.captureLocation(at: captureDate).map(CaptureLocation.init)

        let plan = capturePlan
        let capturedLUT = preparedLUT.lut
        captureTrace.event("capture_plan", "format=\(plan.format.rawValue) input=\(plan.inputSpace.rawValue) approximate=\(plan.approximateLook)")
        let focalMm = admission.focalLength
        let wantsLive = plan.capturesLivePhoto
        guard !wantsLive || cameraManager.livePhotoCaptureState.canCapture else {
            captureTrace.event("live_photo_request_unavailable", "stage=shutter supported=\(cameraManager.livePhotoCaptureState.supported) enabled=\(cameraManager.livePhotoCaptureState.enabled)")
            cameraManager.cancelCaptureAdmission(admission)
            captureError = String(localized: "Live Photo is unavailable. Turn off Live Photo or reopen the camera to try again.")
            return
        }
        isShutterBusy = true
        // Acknowledge the accepted press before any storage or hardware wait.
        shutterPressed = true
        cameraManager.hapticMedium.impactOccurred()
        captureTrace.event("shutter_acknowledged", "tap_to_ack_ms=\(Log.ms(since: tapTime))")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            shutterPressed = false
        }
        guard let captureID = await capturePipeline.reserve(lutBytes: capturedLUT.byteCount, id: requestedID) else {
            cameraManager.cancelCaptureAdmission(admission)
            isShutterBusy = false
            return
        }
        guard cameraManager.isCaptureAdmissionValid(admission),
              cameraManager.readiness == .ready, cameraManager.isCaptureAvailable,
              previewLUTKey == preparedLUT.key else {
            capturePipeline.cancelReservation(captureID)
            cameraManager.cancelCaptureAdmission(admission)
            isShutterBusy = false
            return
        }
        guard let previewFrame = await cameraManager.waitForCapturePreview(lutKey: preparedLUT.key, admission: admission),
              previewLUTKey == preparedLUT.key else {
            captureTrace.event("capture_skip", "reason=matching_preview_unavailable")
            capturePipeline.cancelReservation(captureID)
            cameraManager.cancelCaptureAdmission(admission)
            isShutterBusy = false
            if !Task.isCancelled, scenePhase == .active {
                captureError = String(localized: "The camera preview could not be prepared. Please try again.")
            }
            return
        }
        let grainBaseSeed = previewFrame.grainSeed
        let chromaticGain = previewFrame.chromaticGain
        captureTrace.event("capture_framing", "frame_id=\(previewFrame.frameID) focal_seq=\(previewFrame.focalSequence) source_revision=\(previewFrame.sourceRevision) preview_crop=\(previewFrame.crop) frame_age_ms=\(Int((ProcessInfo.processInfo.systemUptime - previewFrame.capturedAt) * 1_000)) \(previewFrame.framingDiagnosticFields)")
        let displayLabel: String? = {
            if case .custom(_, let name, _, _) = currentSource { return name }
            return nil
        }()
        let recipe = CaptureRecipe(
            id: captureID, captureDate: captureDate, filterName: currentSource.photoFilterName,
            displayLabel: displayLabel, focalLength: focalMm, outputQuality: nil,
            profile: renderProfile, grainSeed: grainBaseSeed, location: location,
            lutDimension: capturedLUT.dimension, chromaticSceneCCT: chromaticSceneCCT, photoDisplayTime: nil,
            plan: plan, colorAdjustment: preparedLUT.adjustment,
            frozenChromaticGain: previewFrame.chromaticGain,
            preservesSourceFocalLength: cameraManager.focalInfo.constituent(for: FocalLengthOption(focalMm))?.calibrationSource == .fieldOfView)
        capturePipeline.preparePreview(previewFrame, recipe: recipe, lut: capturedLUT)
        cameraManager.capturePhoto(admission: admission, live: wantsLive, previewFrame: previewFrame, trace: captureTrace, onWillCapture: {
            // AVF 主曝光起始帧——开闪光灯时即氙气主脉冲发射的瞬间，关闪光灯时 ZSL/responsive
            // 让这一刻在 tap 后 50–150ms 内 fire。在这里驱动白屏，UI 与真实光线同帧。
            //
            // 动画曲线仍模仿氙气闪光物理：
            //   - 起电瞬间（~40ms）快速上升到峰值——`.easeOut` "fast start, slow end"
            //   - 持峰约 150ms——氙气放电稳定段（覆盖典型 30-100ms 主曝光窗口）
            //   - 衰减 200ms 余辉——`.easeOut` 表达 exponential decay 的初快后慢
            captureTrace.event("shutter_feedback")
            Log.capture.info("will_capture dt_from_tap=\(Log.ms(since: tapTime))ms")
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.04)) {
                    showFlash = true
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeOut(duration: 0.20)) {
                    showFlash = false
                }
            }
        }, onExposureComplete: {
            // 仅 log——曝光物理完成的延迟可观察 ZSL 冷启动 / pre-flash AE 收敛耗时。
            captureTrace.event("exposure_complete_main")
            Log.capture.info("exposure_complete dt_from_tap=\(Log.ms(since: tapTime))ms")
        }, onShutterReady: {
            // 静态图完成早期落盘 + 闪光灯 AE/WB 已还原 → 放开快门，让用户能按下一张。
            // live 配对视频（~1.5s 环形缓冲）与全部后处理仍在后台进行，不阻塞这一步。
            // 这是把「快门可再按」从「完整交付」解耦后的核心收益：live 模式快门响应从 ~1.5s 降到 ~300ms。
            captureTrace.event("shutter_available")
            isShutterBusy = false
        }, onStillCaptured: { still in
            await capturePipeline.checkpointStill(still, recipe: recipe, lut: capturedLUT)
        }) { result in
            // 拍照交付（启动后处理的信号，**不是**放开快门的信号——快门早在 onShutterReady 放开了）。
            // 闪光灯 AE/WB 已在 CameraManager.deliverCaptureIfReady 里于静态图就绪时还原。
            // 非 live：result 在静态图就绪时立即到达。live：等静态图 + 动态视频两个交付物齐了才到达
            // （视频是 shutter 前后 ~1.5s 环形缓冲，故 live 时此回调约在 tap 后 ~1.5s）。
            guard let result else {
                captureTrace.event("capture_delivery_failed")
                Log.capture.error("photo_data_nil dt_from_tap=\(Log.ms(since: tapTime))ms")
                shutterPressed = false
                // 失败：释放 tap 时预留的在途槽位。isShutterBusy 也在此兜底重置——正常 terminal 路径
                // onShutterReady 会先放开它（此处幂等），但若某条失败路径未触发 onShutterReady，
                // 没有这行快门会永久 disabled。
                isShutterBusy = false
                capturePipeline.cancelReservation(captureID)
                guard cameraManager.diagnosticGeneration == admission.sessionGeneration else { return }
                captureError = cameraManager.lensSwitchFailed
                    ? String(localized: "Could not switch to this focal length. Select it again to retry.")
                    : wantsLive && !cameraManager.livePhotoCaptureState.canCapture
                    ? String(localized: "Live Photo is unavailable. Turn off Live Photo or reopen the camera to try again.")
                    : String(localized: "Capture failed: couldn't get image data, please try again")
                return
            }
            captureTrace.event("capture_received", "bytes=\(result.imageData.count) live=\(result.livePhotoMovieURL != nil)")
            let displayTime = result.photoDisplayTime
            let completedRecipe = recipe.withPhotoDisplayTime(
                displayTime.isValid && displayTime.isNumeric ? displayTime.seconds : nil)
            captureTrace.event("chromatic_response_snapshot",
                "native_kk=\(Int(renderProfile.effectiveChromatic.nativeCCT)) strength=\(String(format: "%.2f", renderProfile.effectiveChromatic.strength)) scene_kk=\(chromaticSceneCCT.map { Int($0) }.map(String.init) ?? "unavailable") gain=\(String(format: "%.3f/%.3f/%.3f", chromaticGain.x, chromaticGain.y, chromaticGain.z))")
            capturePipeline.enqueue(result, recipe: completedRecipe, lut: capturedLUT)
        }
    }

    @MainActor
    /// Compensate only for physical rotation that the window has not already applied.
    private var controlRotationAngle: Angle {
        switch cameraManager.controlsOrientation {
        case .portraitUpsideDown: return .degrees(180)
        case .landscapeLeft: return .degrees(90)
        case .landscapeRight: return .degrees(-90)
        default: return .degrees(0)
        }
    }

    /// 视觉反馈：reticle 立刻在 location 弹出 + 轻触感。**不**触发 AVF 对焦——
    /// 真正的对焦/AE 提交延迟到手势意图明确后（onEnded 判定为 tap，或 onChanged 进 EV 模式）。
    /// 这样横向滑动 / 斜向滑动不会平白触发一次对焦动作和 bias 清零。
    private func showFocusReticle(at location: CGPoint) {
        cameraManager.hapticLight.impactOccurred()
        focusPoint = location
        withAnimation(.easeOut(duration: 0.15)) {
            showFocusIndicator = true
        }
    }

    /// Map the visible point through the current preview rotation before focus/AE.
    private func commitFocusToDevice(at location: CGPoint, in size: CGSize, resetExposure: Bool = true) {
        let point = CameraOrientationPolicy.focusPoint(at: location, viewport: size,
            rotation: CameraOrientationPolicy.previewRotation(for: cameraManager.previewInterfaceOrientation))
        cameraManager.setFocusAndExposure(normalizedPoint: point, resetExposure: resetExposure)
    }

    /// 3.5s 后若 focus 已不再 locked（focusHoldTimer 已过期）则淡出 reticle。
    /// 检查 isFocusLocked 是为了让连续多次 tap 期间 reticle 始终可见——只在最后一次过期才消失。
    private func scheduleHideFocusReticle() {
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !cameraManager.isFocusLocked {
                withAnimation(.easeOut(duration: 0.3)) {
                    showFocusIndicator = false
                }
            }
        }
    }

    /// 手势被判定为"非 tap、非 EV"（横向滑动 / 大幅斜向移动）时撤销已弹出的 reticle。
    /// AVF 还没提交，所以无需 restore 任何相机状态。
    private func cancelFocusReticle() {
        withAnimation(.easeOut(duration: 0.18)) {
            showFocusIndicator = false
        }
    }

    /// tap-to-focus + 上下滑动调曝光补偿（iPhone Camera 风格）。
    ///
    /// **核心分流**：按"是否已有活动对焦"(cameraManager.isFocusLocked) 走两条路径，
    /// 让"刚 tap 完想继续微调 EV"和"全新 tap 选个新焦点"都各自顺滑。
    ///
    /// **无活动对焦**（reticle 已隐藏）：
    /// - 触摸落下：立即展示 reticle 在触摸位置（视觉反馈），但**不**提交 AVF。
    /// - 垂直主导拖动：进 EV 模式 → 提交 AVF 到起始点，bias 从 0 起调。
    /// - 松手判 tap（位移 < 10pt）：提交 AVF。
    /// - 松手非 tap 非 EV：撤销刚展示的 reticle，相机状态零侧效。
    ///
    /// **有活动对焦**（前次 tap 后 hold timer 仍未过期，reticle 在原位）：
    /// - 触摸落下：**不**移动 reticle、**不**触发 haptic（与 iPhone Camera 一致）。
    /// - 垂直主导拖动：直接进 EV 模式，从**当前 bias 累加**（biasAtDragStart + delta），
    ///   不重新提交 AVF（焦点不变），refreshFocusHold 续期可见时长。
    /// - 松手判 tap：把 reticle 移到新位置 + 提交 AVF（重新对焦，bias 清零）。
    /// - 松手非 tap 非 EV：原 reticle 安然不动，AVF 状态零侧效。
    ///
    /// **进 EV 双条件**：|dy| > 14pt **且** |dy| > |dx| × 1.5。挡住手抖与斜向滑动。
    /// **EV 灵敏度**：100pt = 1 EV；配合 ±1 EV 上限，满程 ±100pt 即触底。
    ///
    /// Picker 展开时仍保留点按对焦和垂直 EV；水平主导手势才切胶片。
    /// 一次手势锁定一个用途，两个方向都按手势开始时的持机方向解释。
    private func unifiedPreviewGesture(viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($previewGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !isShutterBusy else { return }
                if dragStartLocation == nil {
                    gestureAllowsFilmSwipe = showFilmPicker
                    gestureOrientation = cameraManager.controlsOrientation
                    handleFocusEvChanged(value: value, viewportSize: viewportSize)
                    handleFilmSwipeChanged(value)
                }
                let movement = perceivedTranslation(value.translation)
                switch previewGestureRouting.update(horizontal: movement.horizontal, vertical: movement.vertical,
                    allowsFilmSwipe: gestureAllowsFilmSwipe) {
                case .film:
                    if didShowReticleThisGesture { cancelFocusReticle(); didShowReticleThisGesture = false }
                case .exposure, .undecided:
                    handleFocusEvChanged(value: value, viewportSize: viewportSize)
                }
            }
            .onEnded { value in
                defer { resetPreviewGesture() }
                guard !isShutterBusy else { return }
                let movement = perceivedTranslation(value.translation)
                let intent = previewGestureRouting.update(horizontal: movement.horizontal, vertical: movement.vertical,
                    allowsFilmSwipe: gestureAllowsFilmSwipe)
                if intent == .film {
                    if didShowReticleThisGesture { cancelFocusReticle() }
                    handleFilmSwipeEnded(value)
                } else {
                    if intent == .exposure { handleFocusEvChanged(value: value, viewportSize: viewportSize) }
                    handleFocusEvEnded(value: value, viewportSize: viewportSize)
                }
                cameraManager.diagnostics.event("preview_gesture_ended", "film_picker=\(gestureAllowsFilmSwipe) intent=\(intent) ev=\(cameraManager.exposureBias)")
            }
    }

    private func resetPreviewGesture() {
        cameraManager.endExposureAdjustment()
        if dragStartLocation != nil, didShowReticleThisGesture, !cameraManager.isFocusLocked { cancelFocusReticle() }
        previewGestureRouting = PreviewGestureRouting()
        dragStartLocation = nil
        dragStartFilmIndex = nil
        isAdjustingExposure = false
        didShowReticleThisGesture = false
        gestureAllowsFilmSwipe = false
    }

    private func handleFocusEvChanged(value: DragGesture.Value, viewportSize: CGSize) {
        // Freeze device controls from admission through the durable still checkpoint.
        guard !isShutterBusy else { return }

        if dragStartLocation == nil {
            dragStartLocation = value.startLocation
            isAdjustingExposure = false
            biasAtDragStart = cameraManager.exposureBias
            if cameraManager.isFocusLocked {
                // 已有活动对焦：reticle 留原位，等手势意图明确再行动
                didShowReticleThisGesture = false
            } else {
                didShowReticleThisGesture = true
                showFocusReticle(at: value.startLocation)
            }
            return
        }

        let perceived = perceivedTranslation(value.translation)

        if isAdjustingExposure {
            // 已进 EV 模式：忽略用户感知的横向晃动，沿用户感知的竖轴从 biasAtDragStart 累加
            let evDelta = Float(perceived.vertical) / 100.0
            cameraManager.setExposureBias(biasAtDragStart + evDelta)
            return
        }

        if abs(perceived.vertical) > 14 && abs(perceived.vertical) > abs(perceived.horizontal) * 1.5 {
            isAdjustingExposure = true
            cameraManager.beginExposureAdjustment()
            cameraManager.hapticSoft.impactOccurred()
            if cameraManager.isFocusLocked {
                // 活动对焦下继续微调：保留焦点，从当前 bias 累加，续期 hold timer
                cameraManager.refreshFocusHold()
            } else {
                // A fresh EV drag can establish a point without resetting the retained EV.
                commitFocusToDevice(at: value.startLocation, in: viewportSize, resetExposure: false)
            }
            let evDelta = Float(perceived.vertical) / 100.0
            cameraManager.setExposureBias(biasAtDragStart + evDelta)
        }
    }

    private func handleFocusEvEnded(value: DragGesture.Value, viewportSize: CGSize) {
        let dy = value.translation.height
        let dx = value.translation.width
        let distance = sqrt(dx * dx + dy * dy)

        if isAdjustingExposure {
            // EV 模式自然结束：续期 hold 给用户操作余裕，再安排 reticle 淡出
            cameraManager.refreshFocusHold()
            scheduleHideFocusReticle()
        } else if distance < 10 {
            // 纯 tap：触摸落下未弹 reticle（活动对焦路径）→ 此刻把 reticle 移到新位置
            if !didShowReticleThisGesture {
                showFocusReticle(at: value.startLocation)
            }
            commitFocusToDevice(at: value.startLocation, in: viewportSize)
            scheduleHideFocusReticle()
        } else if didShowReticleThisGesture {
            // 非 tap 非 EV，且本次手势自己弹过 reticle → 撤销
            cancelFocusReticle()
        }
        // 活动对焦路径下的非 tap 非 EV 手势：reticle 与 AVF 状态都不动

        dragStartLocation = nil
        isAdjustingExposure = false
        didShowReticleThisGesture = false
    }

    /// Picker 展开时预览的左右滑动手感：**单挡切换**——一次完整手势最多切一档胶片，
    /// 与 iOS 系统级 swipe（分页、滤镜栏、状态切换）的离散切换语义一致。决策放在 onEnded：
    /// 取实际位移与 predictedEndTranslation 的较大者，让"快 flick 短距离"也能触发，
    /// 同时挡住"慢拖到一半又松手"的误操作。
    ///
    /// **方向**：perceived horizontal < 0（左滑）→ 下一张，> 0（右滑）→ 上一张。
    /// **阈值**：50pt——比单 cell 宽度（52pt）略小，让"瞄准一格距离的快滑"稳定触发。
    private static let filmSwipeThreshold: CGFloat = 50

    /// Picker 候选列表，顺序与 FilmSourcePickerStrip 一致（preset 在前，自定义在后）。
    /// FilmPreset.allCases 是常量，customLUTs 已经在 @Query 缓存里，每次重新拼开销可忽略。
    /// 放 computed property 避免 SwiftUI body 闭包捕获 stale 数组。
    private var allFilmSources: [FilmSource] {
        FilmPreset.allCases.map(FilmSource.preset) + customLUTs.map(FilmSource.from)
    }

    private func handleFilmSwipeChanged(_ value: DragGesture.Value) {
        // 单挡模式：onChanged 仅落基线，不实时切换。
        if dragStartFilmIndex == nil {
            dragStartFilmIndex = allFilmSources.firstIndex(of: source) ?? 0
        }
    }

    private func handleFilmSwipeEnded(_ value: DragGesture.Value) {
        defer { dragStartFilmIndex = nil }
        let sources = allFilmSources
        guard sources.count > 1, let baseIndex = dragStartFilmIndex else { return }

        // Use orthogonal perceived axes for film and exposure, including landscape holding.
        let actual = perceivedTranslation(value.translation).horizontal
        let predicted = perceivedTranslation(value.predictedEndTranslation).horizontal
        // 取绝对值更大者作为"有效位移"：慢拖需要够 50pt；快 flick 即便实际只走 20pt，
        // 预测落点也可能 > 50pt，照样切换。这是 UIKit UIScrollView paging 同款手感。
        let effectiveDx = abs(actual) >= abs(predicted) ? actual : predicted

        if abs(effectiveDx) <= Self.filmSwipeThreshold {
            // 未达切换阈值。picker 保持展开——列表由胶片封面开关，
            // 预览区 tap / 短滑不再作为关闭手势（选定胶片后要连读对比）。
            return
        }

        // 左滑（dx < 0）= 下一张；右滑（dx > 0）= 上一张
        let direction = effectiveDx < 0 ? 1 : -1
        let targetIndex = baseIndex + direction

        guard targetIndex >= 0 && targetIndex < sources.count else {
            // 已在两端继续滑动：rigid haptic 提示"撞墙"。
            cameraManager.hapticLight.impactOccurred(intensity: 0.6)
            return
        }

        let newSource = sources[targetIndex]
        cameraManager.hapticSoft.impactOccurred()
        source = newSource
        // ContentView 启动时已 preload；这里命中 cache 零开销，冷路径下也只是 LUT 解析一次。
    }

    /// 把 SwiftUI translation（设备屏幕坐标）映射到**用户感知**的轴：
    /// `vertical` 正向 = 用户视角向上（→ 调亮），`horizontal` 正向 = 用户视角向右。
    ///
    /// 窗口已跟随设备旋转时直接使用窗口坐标；方向锁定时补偿剩余旋转，
    /// 让横握设备时的上滑也能正确调亮。
    @MainActor
    private func perceivedTranslation(_ t: CGSize) -> (vertical: CGFloat, horizontal: CGFloat) {
        PreviewGestureRouting.axes(for: t, orientation: gestureOrientation)
    }

    /// Sun rail 在预览中的位置：以对焦框为锚点，沿"用户感知右侧"偏移 60pt；
    /// 越界时翻到对侧。所有持机方向下 sun 都浮在对焦框侧旁、视觉与 EV 手势竖轴一致。
    /// edgePad = 12（rail 宽 22pt 的半宽 + 余量）—— 与旧实现一致，不动调校手感。
    private func sunRailPosition(focus: CGPoint, viewport: CGSize) -> CGPoint {
        let offset: CGFloat = 60
        let edgePad: CGFloat = 12
        switch cameraManager.controlsOrientation {
        case .portraitUpsideDown:  // 用户右 = 屏幕 -X
            let pref = focus.x - offset
            let x = pref - edgePad < 0 ? focus.x + offset : pref
            return CGPoint(x: x, y: focus.y)
        case .landscapeLeft:       // 用户右 = 屏幕 +Y
            let pref = focus.y + offset
            let y = pref + edgePad > viewport.height ? focus.y - offset : pref
            return CGPoint(x: focus.x, y: y)
        case .landscapeRight:      // 用户右 = 屏幕 -Y
            let pref = focus.y - offset
            let y = pref - edgePad < 0 ? focus.y + offset : pref
            return CGPoint(x: focus.x, y: y)
        default:                   // .portrait: 用户右 = 屏幕 +X
            let pref = focus.x + offset
            let x = pref + edgePad > viewport.width ? focus.x - offset : pref
            return CGPoint(x: x, y: focus.y)
        }
    }
}
