import SwiftUI
import SwiftData
import UIKit
import Foundation
import AVKit
import os

// MARK: - 拍摄页（SwiftUI shell）
//
// 本文件只保留 CameraView 这一 SwiftUI 视图层。所有 capture 引擎实现已拆到：
//   - CameraManager.swift 及其 +Orientation / +Session / +Lens / +Capture / +Location 扩展
//   - DeviceFocalInfo.swift（焦段数据层）
//   - CameraSubviews.swift（FocusIndicatorView / ExposureSunRail / FocalLengthStrip / FilmSourceCoverThumbnail / FlashMode / openAppSettings）
//   - MetalPreview.swift（RealtimePreviewView + Metal Coordinator）

struct CameraView: View {
    /// 当前选中的胶片源。底部右侧封面打开 picker 后可切换——`@State` 让 toolbar title、
    /// 预览 LUT (RealtimePreviewView.lutCacheKey)、右下封面、左下最近照片 badge 都自动跟随。
    @State private var source: FilmSource
    /// Picker 候选列表里需要展示用户导入的自定义 LUT；CameraView 自己持有 @Query 直接喂给 strip。
    @Query(sort: \CustomLUT.createdAt, order: .reverse) private var customLUTs: [CustomLUT]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cameraManager: CameraManager
    @State private var showFlash = false
    /// 仅守护 tap → 拿到 raw photo data（含闪光灯 AE/WB 还原）这一窗口。
    /// 拿到 data 后立刻释放，让用户能继续按下一张快门 —— 后处理 pipeline 由
    /// pendingPostProcessing 计数 + 上限 2 并发守护，避免 N 张 48MP HEIF 编码同时占满
    /// 内存触发 jetsam，又不至于像旧实现那样卡 1.5–3s 才能再拍。
    @State private var isShutterBusy = false
    /// 后处理（LUT + save + 缩略图）正在跑的张数。spinner 与连按节流都看它。
    /// 上限 2：iPhone 17 Pro 单张 48MP HEIF10 编码峰值内存 ~200-300MB，2 张并发可控。
    @State private var pendingPostProcessing = 0
    private static let maxInflightProcessing = 2
    @State private var shutterPressed = false
    /// 拍照 pipeline 完成时立即 push 进来的 88pt 缩略图 hint（避免等 @Query 通知链 ~300-500ms）。
    /// RecentPhotosBadge 通过 @Binding 读写：source 切换时它会清空 hint 并从新 source 的 @Query
    /// 重新 bootstrap。
    @State private var lastPhotoThumbnail: UIImage?
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
    /// 底部胶片选择条展开状态。点击右下封面切换；选中任一胶片后自动收起。
    @State private var showFilmPicker = false
    /// 预览左右滑动切胶片：手势开始时的 allFilmSources 索引基线。每次 onChanged 累加 delta
    /// 后映射到目标 index，与 iPhone 原相机滤镜横滑切换同手感。nil = 当前没有 swipe 进行中。
    @State private var dragStartFilmIndex: Int? = nil

    init(source: FilmSource) {
        _source = State(initialValue: source)
        _cameraManager = StateObject(wrappedValue: CameraManager())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 预览区
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    // 虚拟设备架构：constituent 切换由系统在内部完成（硬件级 crossfade,
                    // 预览不黑屏），不再需要 bridgeImage 帧桥接。
                    // 手势挂在预览视图上：tap 落点设对焦点，随后 |dy|>8pt 切到曝光补偿。
                    // 不挂在 ZStack 上是为了避免与底部 FocalLengthStrip 的 simultaneousGesture
                    // 同时触发——子视图各自管自己的命中区域。
                    RealtimePreviewView(manager: cameraManager, lutCacheKey: source.lutCacheKey)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                        .gesture(unifiedPreviewGesture(viewportSize: geometry.size))

                    if showFocusIndicator, let point = focusPoint {
                        FocusIndicatorView()
                            .position(point)

                        // 曝光补偿 sun rail（iPhone Camera 风格）：靠近预览右边缘时翻到对焦框左侧,
                        // 永远保持在可视区域内。allowsHitTesting(false) 让手势穿透到下层预览,
                        // 用户可以直接在 sun 图标上继续拖动。
                        ExposureSunRail(
                            bias: cameraManager.exposureBias,
                            isAdjusting: isAdjustingExposure
                        )
                        // 长轴始终沿用户视角竖直——controlRotationAngle 把内容旋转到用户上方为正。
                        // sunYOffset(bias>0) 在旋转后的局部坐标里 = "用户视角向上"，与上滑变亮的手势同向。
                        .rotationEffect(controlRotationAngle)
                        .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.currentDeviceOrientation)
                        .position(sunRailPosition(focus: point, viewport: geometry.size))
                        .allowsHitTesting(false)
                    }

                    // 焦距选择条悬浮在预览底部（iPhone Camera 风格）。容器与位置在所有方向下都
                    // 不变，只是内部数字跟随设备方向旋转，让用户视角下文字方向正确。
                    FocalLengthStrip(
                        focalInfo: cameraManager.focalInfo,
                        current: cameraManager.currentFocalLength,
                        contentRotation: controlRotationAngle
                    ) { option in
                        cameraManager.hapticSoft.impactOccurred()
                        cameraManager.setFocalLength(option)
                    }
                    .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 3:4 纵向 = iPhone 传感器原生纵横比。预览 viewport 与 sensor 输出对齐，aspect-fill
            // 在 MTKView 里是无损裁切（scale_x == scale_y），出片也保留全 sensor FOV。
            // 取消 2:3 (135 胶片) 裁切后：tap-to-focus 坐标无需偏移修正，FOV 也最大化。
            .aspectRatio(3.0/4.0, contentMode: .fit)
            // 两侧留标准内容边距（16pt），让预览左右边缘与顶部工具栏按钮、底部控制行（同 16pt）
            // 三排对齐，而不是几乎贴边。
            .padding(.horizontal, 16)

            // 权限被拒绝时的引导
            if cameraManager.cameraPermissionDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("Camera access required")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Allow camera access for JustShoot in Settings")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    Button("Open Settings", action: openAppSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundColor(.black)
                }
                .padding(40)
            }

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
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        // 全屏相机 push 时隐藏底部 tab 栏——否则 tab 栏会压在取景器/快门之上。
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            // 左上：返回
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .fontWeight(.semibold)
                }
                .tint(.white)
                .accessibilityLabel("Back")
            }

            // 中间：胶片名 + 可选的位置状态
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(source.displayName)
                        .font(.subheadline.weight(.semibold))
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

            // 右上：闪光灯
            ToolbarItem(placement: .primaryAction) {
                Button {
                    cameraManager.toggleFlashMode()
                } label: {
                    Image(systemName: cameraManager.flashMode == .on ? "bolt.fill" : "bolt.slash.fill")
                        .rotationEffect(controlRotationAngle)
                        .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.currentDeviceOrientation)
                }
                .tint(cameraManager.flashMode == .on ? .yellow : .white)
                .accessibilityLabel(cameraManager.flashMode == .on ? Text("Flash on") : Text("Flash off"))
                .accessibilityHint("Toggle flash")
            }
        }
        // 底部控制栏（焦距选择条已移到预览内部，不再占用底部空间）
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                // 胶片选择条（按需展开）：右下封面 tap 切换。选中任一胶片后自动收起。
                if showFilmPicker {
                    FilmSourcePickerStrip(
                        current: source,
                        customLUTs: customLUTs,
                        contentRotation: controlRotationAngle,
                        orientation: cameraManager.currentDeviceOrientation
                    ) { newSource in
                        if newSource.id != source.id {
                            cameraManager.hapticSoft.impactOccurred()
                            source = newSource
                            // 通常 ContentView 启动时已 preload；冷启动后从 picker 第一次切到某胶片
                            // 也走一次保险——FilmProcessor cache 命中时零开销。
                            FilmProcessor.shared.preload(source: newSource)
                        }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showFilmPicker = false
                        }
                    }
                    .padding(.horizontal, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack {
                    // 左：最近照片缩略图。后处理（LUT+save+thumbnail）期间叠加 spinner —
                    // 48MP 10-bit HEIF 编码 1.5-3s，用户需要明确"系统在干活"的反馈。
                    // 子视图持有 source 过滤的 @Query；source 切换时它会重建并从新过滤集 bootstrap thumbnail。
                    RecentPhotosBadge(
                        source: source,
                        lastThumbnailHint: $lastPhotoThumbnail,
                        isShutterBusy: isShutterBusy,
                        isProcessing: pendingPostProcessing > 0,
                        controlRotationAngle: controlRotationAngle,
                        orientation: cameraManager.currentDeviceOrientation
                    )

                    Spacer()

                    // 中：快门按钮
                    Button(action: capturePhoto) {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(.white)
                                .frame(width: 60, height: 60)
                                .scaleEffect(shutterPressed ? 0.85 : 1.0)
                                .animation(.easeInOut(duration: 0.1), value: shutterPressed)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Capture")
                    .accessibilityHint("Take a photo")

                    Spacer()

                    // 右：当前胶片封面缩略图——tap 展开 / 收起底部胶片选择条。
                    // 列表 tile 通过 navigationTransition(.zoom) 放大成本页时，封面落位在这里。
                    Button {
                        cameraManager.hapticLight.impactOccurred()
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showFilmPicker.toggle()
                        }
                    } label: {
                        FilmSourceCoverThumbnail(source: source)
                            .frame(width: 46, height: 46)
                            .overlay {
                                // 展开时给封面一个淡黄色描边，提示当前处于"切换中"状态。
                                if showFilmPicker {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.yellow.opacity(0.85), lineWidth: 1.5)
                                }
                            }
                            .rotationEffect(controlRotationAngle)
                            .animation(.spring(duration: 0.35, bounce: 0.15), value: cameraManager.currentDeviceOrientation)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Switch film"))
                    .accessibilityHint(showFilmPicker ? Text("Tap to close film picker") : Text("Tap to pick another film"))
                }
                // 与预览两侧边距对齐（16pt）：badge / 封面缩略图的外缘与预览左右边缘成一条线。
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
        }
        .onAppear {
            FilmProcessor.shared.preload(source: source)
            cameraManager.requestCameraPermission()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        // 后台/前台切换：按 Home 键 / 切到其他 app → pause；回前台 → resume。
        // 不在 .background 完整 stopSession，因为 onDisappear 没触发（页面仍在导航栈），
        // 只调 pauseSessionForBackground 释放摄像头硬件，配置/observers 全部保留。
        // 没有这条监听，回前台只看到黑屏（pixelBuffer 是 stale 的）+ session 不再产帧。
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                cameraManager.pauseSessionForBackground()
            case .active:
                cameraManager.resumeSessionIfPossible()
            @unknown default:
                break
            }
        }
        // Camera Control 硬件快门按钮（iPhone 16+）
        .onCameraCaptureEvent { event in
            if event.phase == .ended {
                capturePhoto()
            }
        }
        .alert("Capture failed", isPresented: Binding(
            get: { captureError != nil },
            set: { if !$0 { captureError = nil } }
        )) {
            Button("OK", role: .cancel) { captureError = nil }
        } message: {
            Text(captureError ?? "")
        }
    }

    /// 与拍照后立即写入的 thumbnail size 对齐——同 key 命中 NSCache，零额外解码。
    fileprivate static let thumbnailMaxPixel = 88

    private func capturePhoto() {
        // 两道闸门：
        //  1) isShutterBusy — 上一张的 tap → raw data + 闪光灯 AE/WB 还原这段窗口（必须串行）。
        //  2) pendingPostProcessing >= maxInflightProcessing — 后处理并发上限（48MP HEIF10
        //     编码内存峰值 ~200-300MB×N，限 2 张以内）。达到上限时 tap 直接忽略。
        // 拿到 raw data 后立刻释放 isShutterBusy，让用户能继续按下一张快门，后处理走后台。
        // 这是 iPhone 系统相机的快门手感。
        // 相机根本不可用（权限未授予 / 启动配置未完成 / 已离开页面）时静默忽略快门——
        // 否则 issueCapturePhoto 会在无 active connection 时抛 NSException 崩溃。
        // 注意用 isCaptureAvailable 而非 isReadyToCapture：镜头切换中相机是「可用但未就绪」，
        // tap 不该被丢，而应由 capturePhoto 内部 await waitForReadyToCapture 等到位再出片。
        guard cameraManager.isCaptureAvailable else {
            Log.capture.debug("shutter_ignored reason=not_available")
            return
        }
        guard !isShutterBusy else {
            Log.capture.debug("shutter_ignored reason=shutter_busy")
            return
        }
        guard pendingPostProcessing < Self.maxInflightProcessing else {
            Log.capture.debug("shutter_ignored reason=post_processing_full pending=\(pendingPostProcessing)")
            return
        }

        let tapTime = Log.now()
        Log.capture.info("shutter_tap source=\(source.photoFilterName, privacy: .public) pending_post=\(pendingPostProcessing)")

        isShutterBusy = true
        shutterPressed = true
        cameraManager.hapticMedium.impactOccurred()

        // 按钮按压回弹：tap 即时确认，独立于 AVF 时序。100ms 接近物理按键按压时长。
        // 白屏覆盖层不再挂在这里——它跟随 AVF 的 willCapturePhotoFor 回调，与真实
        // 闪光灯主脉冲物理同帧。详见下方 onWillCapture 注释。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            shutterPressed = false
        }

        let currentSource = source
        let manager = cameraManager
        // ModelContainer 是 Sendable；ModelContext 不是。@ModelActor 在 actor 内部
        // 创建自己的 modelContext，与主 context 隔离，save 不阻塞主线程。
        let container = modelContext.container

        let focalMm = cameraManager.currentFocalLength.rawValue
        cameraManager.capturePhoto(onWillCapture: {
            // AVF 主曝光起始帧——开闪光灯时即氙气主脉冲发射的瞬间，关闪光灯时 ZSL/responsive
            // 让这一刻在 tap 后 50–150ms 内 fire。在这里驱动白屏，UI 与真实光线同帧。
            //
            // 动画曲线仍模仿氙气闪光物理：
            //   - 起电瞬间（~40ms）快速上升到峰值——`.easeOut` "fast start, slow end"
            //   - 持峰约 150ms——氙气放电稳定段（覆盖典型 30-100ms 主曝光窗口）
            //   - 衰减 200ms 余辉——`.easeOut` 表达 exponential decay 的初快后慢
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
            Log.capture.info("exposure_complete dt_from_tap=\(Log.ms(since: tapTime))ms")
        }) { imageData in
            // raw photo data 已到手 + 闪光灯 AE/WB 已在 didFinishProcessingPhoto 里同步还原
            // （CameraManager 的 finishCapture 顺序：applyFlashRestore → CaptureRequest.onData）。
            // 立即释放 isShutterBusy，让用户能继续按下一张快门 —— 后续 LUT+save 走后台并发。
            isShutterBusy = false

            guard let data = imageData else {
                Log.capture.error("photo_data_nil dt_from_tap=\(Log.ms(since: tapTime))ms")
                shutterPressed = false
                captureError = String(localized: "Capture failed: couldn't get image data, please try again")
                return
            }
            Log.capture.info("photo_data_received bytes=\(data.count) dt_from_tap=\(Log.ms(since: tapTime))ms")

            // 进后台并发后处理之前先占个位，连按时第二张能感知"已有 1 张在跑"。
            pendingPostProcessing += 1

            Task.detached(priority: .userInitiated) {
                // defer 兜底：即便 LUT/save 抛错，pendingPostProcessing 也必须递减，
                // 否则连按 maxInflight 次后按钮永久 disabled。
                defer {
                    Task { @MainActor in
                        pendingPostProcessing = max(0, pendingPostProcessing - 1)
                    }
                }

                let location = await manager.cachedOrFreshLocation()
                Log.gps.info("gps_resolved present=\(location != nil) age=\(location.map { String(format: "%.1fs", Date().timeIntervalSince($0.timestamp)) } ?? "nil", privacy: .public)")

                let processedData = FilmProcessor.shared.applyLUTPreservingMetadata(
                    imageData: data,
                    lutCacheKey: currentSource.lutCacheKey,
                    outputQuality: 1.0,
                    location: location,
                    focalLengthIn35mm: focalMm
                )

                let finalData = processedData ?? data
                if processedData == nil {
                    Log.capture.error("lut_fallback_raw bytes=\(finalData.count)")
                }

                let displayLabel: String? = {
                    if case .custom(_, let name, _, _) = currentSource { return name }
                    return nil
                }()

                do {
                    // 真相源 = 系统相册：先写入 JustShoot 相簿拿回 localIdentifier。写入失败（权限拒绝
                    // 等）则兜底把字节暂存内部，待授权后由 PhotoMigrator 迁移——绝不丢拍摄结果。
                    var assetID: String? = nil
                    var fallbackData: Data? = nil
                    do {
                        assetID = try await PhotoLibrary.save(
                            imageData: finalData,
                            creationDate: Date(),
                            latitude: location?.coordinate.latitude,
                            longitude: location?.coordinate.longitude,
                            altitude: location?.altitude,
                            locationTimestamp: location?.timestamp
                        )
                    } catch {
                        Log.save.error("photos_write_failed_fallback_internal error=\(error.localizedDescription, privacy: .public)")
                        fallbackData = finalData
                    }

                    let saver = PhotoSaver(modelContainer: container)
                    let id = try await saver.save(
                        assetLocalIdentifier: assetID,
                        imageData: fallbackData,
                        filmPresetName: currentSource.photoFilterName,
                        filmDisplayLabel: displayLabel,
                        latitude: location?.coordinate.latitude,
                        longitude: location?.coordinate.longitude,
                        altitude: location?.altitude,
                        locationTimestamp: location?.timestamp
                    )
                    Log.save.info("photo_saved id=\(id.uuidString, privacy: .public) asset=\(assetID ?? "nil", privacy: .public) bytes=\(finalData.count) preset=\(currentSource.photoFilterName, privacy: .public) gps=\(location != nil)")

                    // 拍照成功后**立即**生成 88pt 缩略图并写入 lastPhotoThumbnail（hint），
                    // 不再等 SwiftData @Query 通知链（PhotoSaver actor save → 跨 context 通知 →
                    // 子视图 @Query 重算 → onChange 自身的 load）。这条链路在日志里隐藏 ~300-500ms
                    // 延迟，是用户感知"缩略图刷新慢"的根因。loadThumbnail 内部已做 in-flight dedup
                    // 和 NSCache 写入，子视图后续 fallback 路径会直接命中。
                    let thumb = await ImageLoader.shared.loadThumbnail(
                        imageData: finalData,
                        photoId: id,
                        maxPixel: Self.thumbnailMaxPixel
                    )
                    if let thumb {
                        await MainActor.run {
                            lastPhotoThumbnail = thumb
                        }
                    }
                } catch {
                    Log.save.error("photo_save_failed error=\(error.localizedDescription, privacy: .public)")
                    await MainActor.run {
                        captureError = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
                    }
                }
                Log.capture.info("capture_pipeline_complete total_dt=\(Log.ms(since: tapTime))ms")
            }
        }
    }

    @MainActor
    /// 设备方向 → 控件旋转角。app UI 锁竖屏，悬浮控件（焦距数字/闪光/缩略图）的物理位置不变，
    /// 只内部 icon / 数字旋转，让用户视角下文字方向正确——与 iPhone Camera 一致。
    private var controlRotationAngle: Angle {
        switch cameraManager.currentDeviceOrientation {
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

    /// 把 viewport 坐标转换成 AVF sensor 归一化坐标，并提交对焦/单次 AE。
    /// 见 setFocusAndExposure 里的旋转推导：portrait viewport 与 sensor landscape 旋转 90° CW 后
    /// 重合，vx/vy 在整个 viewport 上线性映射到 AVF [0,1]，所以 normalizedX = vy/vh，normalizedY = 1 - vx/vw。
    private func commitFocusToDevice(at location: CGPoint, in size: CGSize) {
        let normalizedX = location.y / size.height
        let normalizedY = 1.0 - (location.x / size.width)
        cameraManager.setFocusAndExposure(normalizedPoint: CGPoint(x: normalizedX, y: normalizedY))
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
    /// **picker 展开时的分流**：`showFilmPicker == true` 时整条手势改为"左右滑动切胶片"，
    /// 原对焦/EV 路径完全跳过。两套手势挂在同一个 DragGesture 上而不是条件切换 .gesture
    /// modifier——避免 SwiftUI 重建 RealtimePreviewView 导致 MTKView 闪一下。
    private func unifiedPreviewGesture(viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if showFilmPicker {
                    handleFilmSwipeChanged(value)
                } else {
                    handleFocusEvChanged(value: value, viewportSize: viewportSize)
                }
            }
            .onEnded { value in
                if showFilmPicker {
                    handleFilmSwipeEnded(value)
                } else {
                    handleFocusEvEnded(value: value, viewportSize: viewportSize)
                }
            }
    }

    private func handleFocusEvChanged(value: DragGesture.Value, viewportSize: CGSize) {
        // 仅在 tap → raw data + flash restore 这段窗口禁手势，避免 setExposureTargetBias
        // 与 flash restore 互相覆盖。后处理（LUT+save）已经在背景 task，不会影响 device 状态。
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
            cameraManager.hapticSoft.impactOccurred()
            if cameraManager.isFocusLocked {
                // 活动对焦下继续微调：保留焦点，从当前 bias 累加，续期 hold timer
                cameraManager.refreshFocusHold()
            } else {
                // 首次拖动：提交 AVF 到起始点；setFocusAndExposure 会把 bias 清零
                commitFocusToDevice(at: value.startLocation, in: viewportSize)
                biasAtDragStart = 0
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

        let dx = value.translation.width
        let dy = value.translation.height
        let totalDistance = sqrt(dx * dx + dy * dy)

        let actual = perceivedTranslation(value.translation).horizontal
        let predicted = perceivedTranslation(value.predictedEndTranslation).horizontal
        // 取绝对值更大者作为"有效位移"：慢拖需要够 50pt；快 flick 即便实际只走 20pt，
        // 预测落点也可能 > 50pt，照样切换。这是 UIKit UIScrollView paging 同款手感。
        let effectiveDx = abs(actual) >= abs(predicted) ? actual : predicted

        if abs(effectiveDx) <= Self.filmSwipeThreshold {
            // 未达切换阈值。整体位移 < 10pt 视为 tap → 收起 picker（iPhone Camera 风格的
            // "tap 空白处退出当前模式"）。10-50pt 区间是"想滑但没滑够"，picker 保留。
            if totalDistance < 10 {
                cameraManager.hapticLight.impactOccurred(intensity: 0.5)
                withAnimation(.easeInOut(duration: 0.22)) {
                    showFilmPicker = false
                }
            }
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
        FilmProcessor.shared.preload(source: newSource)
    }

    /// 把 SwiftUI translation（设备屏幕坐标）映射到**用户感知**的轴：
    /// `vertical` 正向 = 用户视角向上（→ 调亮），`horizontal` 正向 = 用户视角向右。
    ///
    /// app 锁竖屏渲染但用户可能横握——若不做转换，横握时手指在物理上的"上滑"会落到屏幕的
    /// X 轴上，旧实现只看 `translation.height` 检测不到、bias 也调反或不动。这是把 iPhone Camera 的
    /// "上滑变亮"承诺扩展到所有持机方向的关键映射。
    @MainActor
    private func perceivedTranslation(_ t: CGSize) -> (vertical: CGFloat, horizontal: CGFloat) {
        switch cameraManager.currentDeviceOrientation {
        case .portraitUpsideDown:
            return (t.height, -t.width)
        case .landscapeLeft:   // home 在右
            return (t.width, t.height)
        case .landscapeRight:  // home 在左
            return (-t.width, -t.height)
        default:               // .portrait + faceUp/Down/unknown 兜底
            return (-t.height, t.width)
        }
    }

    /// Sun rail 在预览中的位置：以对焦框为锚点，沿"用户感知右侧"偏移 60pt；
    /// 越界时翻到对侧。所有持机方向下 sun 都浮在对焦框侧旁、视觉与 EV 手势竖轴一致。
    /// edgePad = 12（rail 宽 22pt 的半宽 + 余量）—— 与旧实现一致，不动调校手感。
    private func sunRailPosition(focus: CGPoint, viewport: CGSize) -> CGPoint {
        let offset: CGFloat = 60
        let edgePad: CGFloat = 12
        switch cameraManager.currentDeviceOrientation {
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
