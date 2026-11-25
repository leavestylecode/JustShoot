import SwiftUI
import SwiftData
import UIKit
import Foundation
import AVKit
import os

// MARK: - 拍摄页（SwiftUI shell）
//
// CameraView owns presentation and selection. CameraCoordinator owns shutter orchestration;
// CameraManager owns native hardware, and MetalPreview owns renderer/view integration.

struct CameraView: View {
    /// 当前胶片源；预览 LUT 与胶片封面随选择更新，最近照片独立于胶片选择。
    @State private var source: FilmSource
    @ObservedObject private var filmSettings: FilmPageSettings
    /// Preserve the saved Live Photo preference; the still-photo format is automatic.
    @AppStorage("photoCaptureMode") private var captureModeValue = PhotoCaptureMode.quality.rawValue
    @AppStorage(AppAppearance.cameraKey) private var cameraAppearance = AppAppearance.automatic
    /// 曲线目录同时提供当前选择、默认曲线显隐及用户自定义曲线。
    @EnvironmentObject private var curveLibrary: FilmCurveLibrary
    /// Picker 候选列表里需要展示用户导入的自定义 LUT；CameraView 自己持有 @Query 直接喂给 strip。
    @Query(sort: \CustomLUT.createdAt, order: .reverse) private var customLUTs: [CustomLUT]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var appColorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var cameraManager: CameraManager
    @State private var showFlash = false
    @StateObject private var coordinator: CameraCoordinator
    @ObservedObject private var capturePipeline = CapturePipeline.shared
    @State private var preparedLUT: (key: String, lut: CubeLUT, texture: PreviewLUTTexture,
        profile: FilmRenderProfile, adjustment: ResolvedCameraColorAdjustment?)?
    @State private var lutPreparationCadence = CameraLUTPreparationCadence()
    @State private var entryRetryRevision: UInt64 = 0
    @State private var preparedPickerCovers: [FilmPreset: UIImage] = [:]
    @State private var colorControls = CameraColorControlsState()
    @State private var shutterPressed = false
    /// 拍照 pipeline 完成时立即 push 进来的 成片缩略图 hint（避免等 @Query 通知链 ~300-500ms）。
    /// RecentPhotosBadge 观察全部拍摄记录；切换胶片保留最新缩略图。
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

    init(source: FilmSource, filmSettings: FilmPageSettings? = nil) {
        _source = State(initialValue: source)
        _filmSettings = ObservedObject(wrappedValue: filmSettings ?? .shared)
        let manager = CameraManager()
        _cameraManager = StateObject(wrappedValue: manager)
        _coordinator = StateObject(wrappedValue: CameraCoordinator(camera: manager, pipeline: CapturePipeline.shared))
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
        .environment(\.colorScheme, cameraColorScheme)
        .toolbarColorScheme(cameraColorScheme, for: .navigationBar)
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
            cameraManager.setLivePhotoAudio(live: wantsLiveCapture)
        }
        .onChange(of: captureModeValue) { _, _ in
            cameraManager.diagnostics.event("live_photo_preference_changed", "requested=\(wantsLiveCapture) supported=\(cameraManager.livePhotoCaptureState.supported) enabled=\(cameraManager.livePhotoCaptureState.enabled)")
            cameraManager.setLivePhotoAudio(live: wantsLiveCapture)
        }
        .onChange(of: cameraManager.flashMode) { _, mode in
            cameraManager.diagnostics.event("flash_changed", "mode=\(mode.rawValue)")
        }
        .onChange(of: coordinator.isShutterBusy) { _, busy in
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
        }
        .onChange(of: capturePipeline.isPrepared) { _, ready in
            cameraManager.updateEntryPipelineReady(ready)
        }
        .task(id: cameraManager.entryPreparation.isRevealed ? allFilmSources.map(\.id) : []) {
            // The hidden picker must not delay first preview or compete with entry preparation.
            guard cameraManager.entryPreparation.isRevealed else { return }
            let presets = allFilmSources.compactMap { source -> FilmPreset? in
                if case .preset(let preset) = source { return preset }
                return nil
            }
            preparedPickerCovers = preparedPickerCovers.filter { presets.contains($0.key) }
            let missing = presets.filter { preparedPickerCovers[$0] == nil }
            guard !missing.isEmpty else { return }
            do {
                let covers = try await FilmSourcePickerStrip.preloadCovers(presets: missing, displayScale: displayScale)
                try Task.checkCancellation()
                preparedPickerCovers.merge(covers) { _, new in new }
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
            let requestedProfile = requestedSource.captureRenderProfile
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
                let adjustedLUT = try await ColorTemperatureLUT.shared.prepare(source: requestedSource, curve: curve, selection: selection, tint: tint, reference: reference)
                let lut = try await FilmCapturePreparation.shared.prepareRendering(for: adjustedLUT)
                try Task.checkCancellation()
                let texture = try await PreviewLUTTextureCache.shared.prepare(key: key, lut: lut)
                lutWait.end("ok", "cancelled=\(Task.isCancelled)")
                guard !Task.isCancelled, key == previewLUTKey else { return }
                let adjustment = selection.isAutomatic && tint.isAutomatic ? nil
                    : ResolvedCameraColorAdjustment.resolve(temperature: selection, tint: tint, reading: reference)
                preparedLUT = (key, lut, texture, requestedProfile, adjustment)
                cameraManager.updateEntryLUT(expectedKey: key, preparedKey: key)
                cameraManager.diagnostics.event("camera_lut_ready", "dimension=\(lut.dimension) \(curveFields) \(colorAdjustmentDiagnosticFields)")
                await waitForCurrentLookPresentation(key: key)
            } catch is CancellationError {
                lutWait.end("cancelled")
            } catch let error as PreviewLUTTextureCache.PreparationError {
                lutWait.end("error", Diagnostics.errorFields(error))
                guard !Task.isCancelled, key == previewLUTKey else { return }
                if cameraManager.entryPreparation.isRevealed {
                    coordinator.error = String(localized: "The camera preview could not be prepared. Please try again.")
                } else {
                    cameraManager.previewRendererUnavailable()
                }
            } catch {
                lutWait.end("error", Diagnostics.errorFields(error))
                guard !Task.isCancelled, key == previewLUTKey else { return }
                if !selection.isAutomatic || !tint.isAutomatic {
                    colorControls.resetAutomatic()
                    coordinator.error = String(localized: "Color adjustments could not be applied. Auto has been restored.")
                } else {
                    if !cameraManager.entryLUTPreparationFailed(key: key) {
                        coordinator.error = String(localized: "This LUT is invalid or unsupported.")
                    }
                }
            }
        }
        .onReceive(capturePipeline.$lastCompletion) { completion in
            guard let completion,
                  (lastPhotoThumbnail?.captureDate ?? .distantPast) <= completion.captureDate else { return }
            lastPhotoThumbnail = RecentPhotoThumbnail(id: completion.id,
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
            get: { coordinator.error != nil },
            set: { if !$0 { coordinator.error = nil } }
        )) {
            if preparedLUT?.key != previewLUTKey {
                Button("Try Again") { retryCameraEntry() }
            }
            Button("OK", role: .cancel) { coordinator.error = nil }
        } message: {
            Text(coordinator.error ?? "")
        }
        .sheet(isPresented: $showCurveManager) {
            NavigationStack {
                FilmCurveLibraryView(showsDoneButton: true)
            }
        }
    }

    private var cameraContent: some View {
        ZStack {
            cameraBackground.ignoresSafeArea()

            Group {
                if isIPad {
                    iPadCameraContent
                } else {
                    iPhoneCameraContent
                }
            }
            .disabled(cameraManager.readiness != .ready || coordinator.isShutterBusy)
            .allowsHitTesting(cameraManager.readiness == .ready && !coordinator.isShutterBusy)
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
        .softScrollEdges()
        .toolbarBackground(.hidden, for: .navigationBar)
        // 全屏相机 push 时隐藏底部 tab 栏——否则 tab 栏会压在取景器/快门之上。
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !isIPad && !cameraManager.entryPreparation.coversContent {
                if showsPermissionControls {
                    ToolbarItem(placement: .principal) {
                        permissionControls
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
                .disabled(cameraManager.readiness != .ready || coordinator.isShutterBusy)
                .opacity(cameraManager.readiness == .ready ? 1 : 0.42)
                .animation(.easeOut(duration: 0.2), value: cameraManager.readiness)
            }
        }
    }

    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var cameraColorScheme: ColorScheme { cameraAppearance.scheme ?? appColorScheme }
    private var cameraBackground: Color { cameraColorScheme == .light ? .white : .black }
    private var controlForeground: Color { CameraPalette.foreground(for: cameraColorScheme) }
    private var controlAccent: Color { CameraPalette.accent(for: cameraColorScheme) }

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
            if showsPermissionControls {
                permissionControls
                    .padding(.leading, 86)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        let profile = preparedLUT?.profile ?? source.captureRenderProfile
        return GeometryReader { geometry in
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
                        resourcesReady: cameraManager.entryPreparation.resourcesReady,
                        lutCacheKey: preparedLUT?.texture.key ?? previewLUTKey,
                        presentedLookKey: preparedLUT?.key ?? previewLUTKey,
                        preparedLUT: preparedLUT?.texture,
                        lutIntensity: CameraCapturePolicy.defaultLUTIntensity,
                        grain: profile.grain,
                        optics: profile.optics,
                        chromatic: profile.effectiveChromatic,
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
            sources: allFilmSources,
            contentRotation: controlRotationAngle,
            orientation: cameraManager.controlsOrientation,
            preparedCovers: preparedPickerCovers,
            style: isIPad ? .iPadOverlay : .standard
        ) { newSource in
            if newSource.id != source.id {
                cameraManager.hapticSoft.impactOccurred()
                source = newSource
                // 通常 FilmHomeView 启动时已 preload；冷启动后从 picker 第一次切到某胶片
                // 也走一次保险——FilmProcessor cache 命中时零开销。曲线合成条目一并生成。
            }
            // 选择后保留面板，便于连续比较。
        }
    }

    private var recentPhotosControl: some View {
        RecentPhotosBadge(
            lastThumbnailHint: $lastPhotoThumbnail,
            pendingPreview: capturePipeline.lastPreview,
            isShutterBusy: coordinator.isShutterBusy && coordinator.activeShutterID != capturePipeline.lastPreview?.id,
            isProcessing: capturePipeline.lastPreview.map { capturePipeline.isProcessing($0.id) } ?? false,
            controlRotationAngle: controlRotationAngle,
            orientation: cameraManager.controlsOrientation,
            onPresentationChanged: { isReviewingPhotos = $0 }
        )
    }

    private var shutterControl: some View {
        CameraShutterButton(
            isCapturing: coordinator.isShutterBusy,
            isPreparingFilm: preparedLUT?.key != previewLUTKey || !cameraManager.entryPreparation.isCurrentLookRendered,
            canCapture: capturePipeline.canCapture,
            isPressed: shutterPressed,
            showsProgress: coordinator.showsCaptureProgress
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
                    // 用描边标记胶片选择面板已展开。
                    if showFilmPicker {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(controlAccent.opacity(0.85), lineWidth: 1.5)
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
        let tint = cameraManager.flashMode == .on ? controlAccent : controlForeground
        return Button {
            cameraManager.toggleFlashMode()
        } label: {
            Image(systemName: cameraManager.flashMode == .on ? "bolt.fill" : "bolt.slash.fill")
                .foregroundStyle(tint)
                .rotationEffect(controlRotationAngle)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.controlsOrientation)
        }
        .tint(tint)
        .disabled(cameraManager.readiness != .ready || coordinator.isShutterBusy)
        .opacity(cameraManager.readiness == .ready ? 1 : 0.45)
        .accessibilityLabel(cameraManager.flashMode == .on ? Text("Flash on") : Text("Flash off"))
        .accessibilityHint("Toggle flash")
    }

    private var colorControl: some View {
        let tint = colorControls.isVisible ? controlAccent : controlForeground
        return Button {
            cameraManager.hapticSoft.impactOccurred()
            let visible = !colorControls.isVisible
            colorControls.setVisible(visible)
            cameraManager.diagnostics.event("color_controls_visibility_changed",
                "visible=\(visible) \(colorAdjustmentDiagnosticFields)")
        } label: {
            Image(systemName: "drop.halffull")
                .foregroundStyle(tint)
                .rotationEffect(controlRotationAngle)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.controlsOrientation)
        }
        .buttonBorderShape(.circle)
        .tint(tint)
        .disabled(coordinator.isShutterBusy)
        .accessibilityLabel("Color controls")
        .accessibilityHint("Show color controls; hiding restores Auto")
        .accessibilityAddTraits(colorControls.isVisible ? [.isSelected] : [])
        .accessibilityIdentifier("camera.white_balance.toggle")
    }

    private var exposureControl: some View {
        ExposureCompensationControl(bias: cameraManager.exposureBias, setBias: cameraManager.setExposureBias)
        .disabled(coordinator.isShutterBusy || cameraManager.readiness != .ready)
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
        .disabled(coordinator.isShutterBusy)
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
        let tint = wantsLiveCapture ? controlAccent : controlForeground
        return Button {
            cameraManager.hapticSoft.impactOccurred()
            let live = !wantsLiveCapture
            // Close capture admission synchronously before publishing the preference.
            // A shutter tap must not resolve a new mode against the previous output.
            cameraManager.setLivePhotoAudio(live: live)
            captureModeValue = live ? PhotoCaptureMode.livePhoto.rawValue : PhotoCaptureMode.quality.rawValue
        } label: {
            Image(systemName: wantsLiveCapture ? "livephoto" : "livephoto.slash")
                .foregroundStyle(tint)
                .rotationEffect(controlRotationAngle)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.controlsOrientation)
        }
        .tint(tint)
        .disabled(cameraManager.readiness != .ready || coordinator.isShutterBusy)
        .opacity(cameraManager.readiness == .ready ? 1 : 0.45)
        .accessibilityIdentifier("camera.live_photo")
        .accessibilityLabel(wantsLiveCapture ? Text("Live Photo on") : Text("Live Photo off"))
        .accessibilityHint("Toggle Live Photo")
    }

    private var livePhotoSoundUnavailable: Bool {
        wantsLiveCapture && cameraManager.microphonePermissionDenied
    }

    private var showsPermissionControls: Bool {
        cameraManager.locationPermissionDenied || livePhotoSoundUnavailable
    }

    private var permissionControls: some View {
        HStack(spacing: 4) {
            if cameraManager.locationPermissionDenied {
                permissionButton(icon: "location.slash.fill", label: "Location off",
                    hint: "Open Settings and allow Location Services to geo-tag photos")
            }
            if livePhotoSoundUnavailable {
                permissionButton(icon: "mic.slash.fill", label: "Live Photo sound off",
                    hint: "Microphone access is off. Turn it on in Settings to record sound.")
                    .accessibilityIdentifier("camera.microphone_settings")
            }
        }
    }

    private func permissionButton(icon: String, label: LocalizedStringKey, hint: LocalizedStringKey) -> some View {
        let button = Button(action: openAppSettings) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(hint))

        return Group {
            if isIPad { button.cameraControlSurface() }
            else { button }
        }
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
            PreparationErrorScreen(
                title: cameraPreparationTitle,
                systemImage: "camera.viewfinder",
                message: failure == .permissionDenied
                    ? String(localized: "Allow camera access in Settings.") : nil,
                actionTitle: failure == .permissionDenied ? "Open Settings" : "Retry",
                actionIcon: failure == .permissionDenied ? "arrow.up.forward" : "arrow.clockwise",
                onAction: {
                    if failure == .permissionDenied { openAppSettings() }
                    else { retryCameraEntry() }
                }
            )
        } else {
            // Keep unprepared controls covered without adding a loading screen to camera entry.
            cameraBackground
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
        coordinator.error = nil
        preparedLUT = nil
        entryRetryRevision &+= 1
        cameraManager.updateEntryLUT(expectedKey: previewLUTKey, preparedKey: nil)
        cameraManager.retryEntryPreparation()
        cameraManager.setLivePhotoAudio(live: wantsLiveCapture)
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

    private func capturePhoto() async {
        let selection = preparedLUT.map {
            CameraCaptureSelection(source: source, lutKey: $0.key, lut: $0.lut, profile: $0.profile,
                adjustment: $0.adjustment, plan: capturePlan, curveFields: curveDiagnosticFields(selectedCurve),
                colorFields: colorAdjustmentDiagnosticFields, lutIntensity: CameraCapturePolicy.defaultLUTIntensity)
        }
        await coordinator.capture(selection: selection, currentLookKey: { previewLUTKey },
            isSceneActive: { scenePhase == .active }, onAccepted: {
                shutterPressed = true
                cameraManager.hapticMedium.impactOccurred()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    shutterPressed = false
                }
            }, onWillCapture: {
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.04)) { showFlash = true }
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.easeOut(duration: 0.20)) { showFlash = false }
                }
            })
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
                guard !coordinator.isShutterBusy else { return }
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
                guard !coordinator.isShutterBusy else { return }
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
        guard !coordinator.isShutterBusy else { return }

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

    /// The strip and swipe gesture share the user's library membership and order.
    private var allFilmSources: [FilmSource] {
        filmSettings.preferences.cameraSources(
            FilmPreset.allCases.map(FilmSource.preset) + customLUTs.filter { !$0.isDeleted }.map(FilmSource.from),
            current: source)
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
        // FilmHomeView 启动时已 preload；这里命中 cache 零开销，冷路径下也只是 LUT 解析一次。
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
