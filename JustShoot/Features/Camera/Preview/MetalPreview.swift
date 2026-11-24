import SwiftUI
import MetalKit
import MetalPerformanceShaders
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import os

// The worker only calls CAMetalLayer.nextDrawable(). It transfers the result
// through the locked pool to the render callback and never uses it again.
private struct PreviewDrawableSource: @unchecked Sendable {
    let layer: CAMetalLayer

    struct Acquired: @unchecked Sendable {
        let drawable: any CAMetalDrawable
    }

    func next() -> Acquired? {
        layer.nextDrawable().map { Acquired(drawable: $0) }
    }
}

/// Core Video owns the camera buffer's recycling lease. Retaining just MTLTexture is insufficient.
private final class PreviewFrameLease: @unchecked Sendable {
    private var texture: CVMetalTexture?
    private var buffer: CVPixelBuffer?

    init(texture: CVMetalTexture, buffer: CVPixelBuffer) {
        self.texture = texture
        self.buffer = buffer
    }

    /// Only the GPU completion handler consumes this lease. Do not rely on the
    /// driver's command-buffer callback storage being destroyed immediately.
    func release() {
        texture = nil
        buffer = nil
    }
}

/// Bound drawable work independently of screen density and iPad window size.
final class CameraPreviewMetalView: MTKView {
    var onRenderingAvailabilityChanged: ((Bool, String) -> Void)?
    var onInterfaceOrientationChanged: ((UIInterfaceOrientation) -> Void)?
    private var lastInterfaceOrientation: UIInterfaceOrientation?
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var sceneActive = false
    private var dismantled = false
    private var contentVisible = true
    private var configuredPreviewScale: CGFloat?
    private var resizePolicy = PreviewDrawableResizePolicy()
    private var resizeTask: Task<Void, Never>?

    /// UIKit's zoom transition supplies fractional raster scales. Keep the configured
    /// preview density so those animation samples cannot bypass manual drawable sizing.
    override var contentScaleFactor: CGFloat {
        get { configuredPreviewScale ?? super.contentScaleFactor }
        set {
            if configuredPreviewScale != nil, !canResizeDrawable { return }
            let scale = configuredPreviewScale ?? newValue
            if super.contentScaleFactor != scale { super.contentScaleFactor = scale }
        }
    }

    override init(frame frameRect: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frameRect, device: device)
        autoResizeDrawable = false
        isPaused = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(applicationWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneWillDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if configuredPreviewScale == nil, let window { configuredPreviewScale = min(window.screen.scale, 2) }
        sceneActive = window?.windowScene.map { $0.activationState == .foregroundActive } ?? (window != nil)
        refreshInterfaceOrientation()
        updateRenderingAvailability(reason: window == nil ? "detached" : "attached")
    }

    @objc private func applicationWillResignActive() {
        applicationActive = false
        updateRenderingAvailability(reason: "app_inactive")
    }

    @objc private func applicationDidBecomeActive() {
        applicationActive = true
        updateRenderingAvailability(reason: "app_active")
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        sceneActive = false
        updateRenderingAvailability(reason: "scene_inactive")
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        sceneActive = true
        updateRenderingAvailability(reason: "scene_active")
    }

    private func updateRenderingAvailability(reason: String) {
        let active = !dismantled && contentVisible && applicationActive && sceneActive && window != nil
        if !active { resizeTask?.cancel(); resizeTask = nil }
        if isPaused == active {
            isPaused = !active
            onRenderingAvailabilityChanged?(active, reason)
            if active { updateDrawableSize(force: true) }
        } else if active, reason == "attached" {
            updateDrawableSize(force: true)
        }
    }

    func stopRendering() {
        dismantled = true
        updateRenderingAvailability(reason: "dismantled")
        NotificationCenter.default.removeObserver(self)
    }

    func setContentVisible(_ visible: Bool) {
        guard contentVisible != visible else { return }
        contentVisible = visible
        updateRenderingAvailability(reason: visible ? "photo_review_closed" : "photo_review_opened")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshInterfaceOrientation()
        updateDrawableSize()
    }

    /// Read this view's scene, never an arbitrary connected scene or the device aspect.
    /// The draw-time check also catches 180° rotations with unchanged view bounds.
    func refreshInterfaceOrientation() {
        guard let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
              orientation != .unknown, orientation != lastInterfaceOrientation else { return }
        lastInterfaceOrientation = orientation
        onInterfaceOrientationChanged?(orientation)
    }

    func configurePreviewScale(_ scale: CGFloat) {
        let scale = min(max(1, scale), 2)
        guard configuredPreviewScale != scale else { return }
        configuredPreviewScale = scale
        updateDrawableSize(force: true)
    }

    private var canResizeDrawable: Bool {
        !dismantled && contentVisible && applicationActive && sceneActive && !isPaused && window != nil
    }

    private func updateDrawableSize(force: Bool = false) {
        if force || !canResizeDrawable { resizeTask?.cancel(); resizeTask = nil }
        let now = ProcessInfo.processInfo.systemUptime
        let size = CameraPerformancePolicy.drawableSize(bounds: bounds.size, scale: configuredPreviewScale ?? contentScaleFactor)
        guard size != .zero else { resizeTask?.cancel(); resizeTask = nil; return }
        if let committed = resizePolicy.request(size, at: now, canRender: canResizeDrawable, force: force) {
            resizeTask?.cancel()
            resizeTask = nil
            let scale = configuredPreviewScale ?? contentScaleFactor
            if super.contentScaleFactor != scale { super.contentScaleFactor = scale }
            if drawableSize != committed { drawableSize = committed }
        }
        guard canResizeDrawable, let deadline = resizePolicy.nextCommitTime else {
            resizeTask?.cancel()
            resizeTask = nil
            return
        }
        // Layout only moves the policy's deadline. One timer checks the latest size;
        // an ongoing animation can rearm it when it wakes, without one Task per sample.
        guard resizeTask == nil else { return }
        let delay = max(0, deadline - now)
        resizeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self, self.canResizeDrawable else { return }
            self.resizeTask = nil
            self.updateDrawableSize()
        }
    }
}

// MARK: - 系统预览底衬（Apple 官方推荐的预览显示路径，作为镜头切换过渡的第二显示源）
//
// AVCaptureVideoPreviewLayer 是 AVFoundation 官方文档推荐的标准预览显示层，由系统在
// 服务进程自行合成：虚拟设备切镜头时它拿到系统的 crossfade 合成流而非停帧（系统相机
// 同款显示路径）。把它垫在 Metal 预览之下，镜头切换停顿的窗口由 PreviewUnderlayBlender
// 把主源淡出、露出这层实时画面，过渡结束后淡回胶片分级渲染。不参与会话连接结构、
// 不改 sessionPreset、零采集链路影响（设计记录见 LensTransitionCompositor.swift）。

/// 宿主 UIView：layerClass 直接就是 AVCaptureVideoPreviewLayer。
struct CameraPreviewUnderlayView: UIViewRepresentable {
    let manager: CameraManager

    func makeUIView(context: Context) -> PreviewUnderlayUIView {
        let view = PreviewUnderlayUIView(frame: .zero)
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        manager.attachPreviewUnderlay(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUnderlayUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewUnderlayUIView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

final class PreviewUnderlayUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - 实时预览视图（全 Metal 管线：CVPixelBuffer → compute shader → drawable）
struct RealtimePreviewView: UIViewRepresentable {
    let manager: CameraManager
    /// An explicit SwiftUI input: the shared resource cache does not publish changes.
    let resourcesReady: Bool
    let lutCacheKey: String
    var presentedLookKey: String? = nil
    let preparedLUT: PreviewLUTTexture?
    var lutIntensity: Float = 1
    let grain: FilmGrainParameters
    let optics: FilmOpticsParameters
    let chromatic: FilmChromaticResponseParameters
    var isContentVisible = true

    func makeUIView(context: Context) -> MTKView {
        // A loading overlay can mount this view before async preparation finishes.
        // resourcesReady changing installs its device/PSOs even if the LUT finished first.
        // No cold compilation occurs on MainActor.
        let view = CameraPreviewMetalView(frame: .zero, device: PreviewMetalResources.shared.device)
        view.setContentVisible(isContentVisible)
        // CADisplayLink 驱动渲染：MTKView 内部以屏幕 vsync 节拍调 draw(in:)。
        // draw() 内部按 lastRenderedFrameId 去重，没有新相机帧时立刻 return（~零成本）。
        //
        // 旧实现是 isPaused=true + enableSetNeedsDisplay=true，由 captureOutput 每帧
        // DispatchQueue.main.async { setNeedsDisplay() } 触发。问题：编码繁忙 / 相机切镜头时
        // 主队列堆积，setNeedsDisplay 排队跟其它 UI 工作竞争，预览会丢帧。
        // MTKView 的 draw 仍在主线程执行；失去前台时同步暂停，避免 currentDrawable 阻塞 UI。
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false  // 允许 compute shader 写入 drawable
        // 非不透明：主帧流停顿的窗口内本视图按合成器计划淡出（view.alpha < 1），露出下层
        // 系统预览底衬（CameraPreviewUnderlayView）。渲染内容本身始终全幅覆盖 drawable
        //（aspect-fill），alpha 只做视图级合成，不影响 Metal 路径。
        view.isOpaque = false
        // 预览降分辨率：2x 而非 3x，减少 55% 像素量
        view.configurePreviewScale(min(context.environment.displayScale, 2.0))
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.autoResizeDrawable = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        context.coordinator.manager = manager
        if resourcesReady { context.coordinator.setup(view: view) }
        view.onRenderingAvailabilityChanged = { [weak coordinator = context.coordinator] active, reason in
            coordinator?.renderingAvailabilityChanged(active)
            coordinator?.manager?.diagnostics.event("preview_rendering_changed", "active=\(active) reason=\(reason)")
        }
        view.onInterfaceOrientationChanged = { [weak manager] orientation in
            // UIKit can deliver layout inside a SwiftUI update. Publish on the next turn.
            Task { @MainActor [weak manager] in manager?.updatePreviewInterfaceOrientation(orientation) }
        }
        manager.diagnostics.event("preview_renderer_setup", "target_fps=\(view.preferredFramesPerSecond) scale=\(view.contentScaleFactor) max_long_edge=\(CameraPerformancePolicy.maximumPreviewLongEdge) diffusion_scale=0.5")
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        (uiView as? CameraPreviewMetalView)?.setContentVisible(isContentVisible)
        (uiView as? CameraPreviewMetalView)?.configurePreviewScale(min(context.environment.displayScale, 2.0))
        context.coordinator.presentedLookKey = presentedLookKey ?? lutCacheKey
        context.coordinator.lutCacheKey = lutCacheKey
        context.coordinator.preparedLUT = preparedLUT
        context.coordinator.lutIntensity = lutIntensity
        context.coordinator.grain = grain
        context.coordinator.optics = optics
        context.coordinator.chromatic = chromatic
        context.coordinator.manager = manager
        if resourcesReady { context.coordinator.setup(view: uiView) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.renderingAvailabilityChanged(false)
        (uiView as? CameraPreviewMetalView)?.stopRendering()
        uiView.isPaused = true
        uiView.delegate = nil
        coordinator.flushFrameCache()
    }

    // MARK: - Metal Preview Coordinator
    // @MainActor：MTKViewDelegate.draw 在主线程触发，
    // 同时需要访问 @MainActor 的 CameraManager 属性（previewInterfaceOrientation 等）
    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var presentedLookKey: String?
        var lutCacheKey: String = ""
        var preparedLUT: PreviewLUTTexture?
        var lutIntensity: Float = 1
        var grain: FilmGrainParameters = .disabled
        var optics: FilmOpticsParameters = .disabled
        var chromatic: FilmChromaticResponseParameters = .neutral
        weak var manager: CameraManager?

        // nextDrawable() can wait for the compositor even after GPU completion.
        // Only the layer crosses to this serial queue. Camera frames are selected at draw time.
        private let drawables = PreviewTargetPool<PreviewDrawableSource.Acquired>(maximumCount: 1,
            preparationQueue: DispatchQueue(label: "com.justshoot.preview-drawables", qos: .userInteractive))

        // Metal 核心对象
        private var metalDevice: (any MTLDevice)?
        private var commandQueue: (any MTLCommandQueue)?
        private var computePipeline: (any MTLComputePipelineState)?
        private var finishPipeline: (any MTLComputePipelineState)?
        private var materialFinishPipeline: (any MTLComputePipelineState)?
        private let targetPool = PreviewTargetPool<PreviewTargets>(maximumCount: 3)
        private var energyDownsampler: MPSImageBilinearScale?
        private let completionGate = PreviewRenderCompletionGate()
        private let gpuStatistics = PreviewGPUStatistics()

        private struct PreviewTargets: @unchecked Sendable {
            let graded: any MTLTexture
            let energy: any MTLTexture
            let smallEnergy: any MTLTexture
            let halation: any MTLTexture
            let bloom: any MTLTexture
        }

        private func targets(width: Int, height: Int) -> PreviewTargets? {
            let flow = manager?.flowDiagnostics
            return targetPool.request(width: width, height: height) {
                let targets = Self.allocateTargets(width: width, height: height)
                if targets != nil { flow?.allocatedTargets() }
                return targets
            }
        }

        nonisolated private static func allocateTargets(width: Int, height: Int) -> PreviewTargets? {
            guard let metalDevice = PreviewMetalResources.shared.device else { return nil }
            let startedAt = ProcessInfo.processInfo.systemUptime
            func texture(_ format: MTLPixelFormat, width: Int, height: Int) -> (any MTLTexture)? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite]
                return metalDevice.makeTexture(descriptor: descriptor)
            }
            let small = CameraPerformancePolicy.diffusionSize(width: width, height: height)
            guard let graded = texture(.rgba16Float, width: width, height: height),
                  let energy = texture(.r16Float, width: width, height: height),
                  let smallEnergy = texture(.r16Float, width: small.width, height: small.height),
                  let halation = texture(.r16Float, width: small.width, height: small.height),
                  let bloom = texture(.r16Float, width: small.width, height: small.height) else { return nil }
            Diagnostics.emit("preview_targets_prepared", fields: "width=\(width) height=\(height) duration_ms=\(Diagnostics.milliseconds(since: startedAt))")
            return PreviewTargets(graded: graded, energy: energy, smallEnergy: smallEnergy, halation: halation, bloom: bloom)
        }

        // CVPixelBuffer → MTLTexture 零拷贝缓存
        private var textureCache: CVMetalTextureCache?

        // Triple-buffer 信号量：限制 GPU 最多 3 帧 in-flight，防止命令堆积
        // nonisolated：`DispatchSemaphore` 线程安全，且 GPU completion handler 在后台线程触发
        nonisolated private let inflightSemaphore = DispatchSemaphore(value: 3)

        // 帧去重：避免同一相机帧被渲染两次
        private var lastRenderedFrameId: UInt64?

        // 纹理缓存刷新计数器
        private var frameCount: UInt32 = 0

        // Shader 参数结构（必须与 LUTShader.metal 中的 PreviewParams 一致）
        struct PreviewParams {
            var scale: Float
            var offsetX: Float
            var offsetY: Float
            var inputWidth: UInt32
            var inputHeight: UInt32
            var rotation: UInt32
            var lutDimension: UInt32
            var grainAmount: Float
            var grainSize: Float
            var grainChroma: Float
            var grainSeed: UInt32
            var halationAmount: Float
            var halationRadiusPx: Float
            var halationHue: Float
            var bloomAmount: Float
            var bloomRadiusPx: Float
            var highlightThreshold: Float
            var headroomAmount: Float
            var headroomShoulder: Float
            var chromaticGainR: Float
            var chromaticGainG: Float
            var chromaticGainB: Float
            var chromaticHighlightProtection: Float
            var grainResponse: Float
            var materialDensityDimension: Float = 0
            var materialPrintDimension: Float = 0
            var materialFinishDimension: Float = 0
            var materialMaximumR: Float = 0
            var materialMaximumG: Float = 0
            var materialMaximumB: Float = 0
            var materialMinimumR: Float = 0
            var materialMinimumG: Float = 0
            var materialMinimumB: Float = 0
            var materialRefineX: Float = 0
            var materialRefineY: Float = 0
            var materialRefineZ: Float = 0
            var materialRefineW: Float = 0
            var materialNeutralRetention: Float = 0
            var materialSkinHueRetention: Float = 0
            var materialSkinChromaRetention: Float = 0
            var materialSkinResponse: Float = 0
            var materialExposureResponse: Float = 0
            var materialShadowLift: Float = 0
            var materialToneCeiling: Float = 0.6
            var materialGrainScale: Float = 1
            var materialIdentityFlags: UInt32 = 0
            var lutIntensity: Float = 1
            var grainBroadOffset: Float = 0
            var grainFineOffset: Float = 0
            var grainFineWeight: Float = 0.22
        }

        /// 色温响应增益的低通平滑：WB 读数 0.5s 采样 + 100K 量化，直接跳变会在预览上
        /// 产生可见的色阶闪烁。每帧向目标指数逼近（60fps 下 ~150ms 收敛，肉眼顺滑）。
        private var smoothedChromaticGain: SIMD3<Float>?

        private func chromaticGainForFrame() -> SIMD3<Float> {
            let target = chromatic.responseGain(sceneCCT: manager?.automaticWhiteBalanceReading?.temperature)
            guard let smoothed = smoothedChromaticGain else {
                smoothedChromaticGain = target
                return target
            }
            let next = smoothed + (target - smoothed) * 0.12
            smoothedChromaticGain = next
            return next
        }

        func setup(view: MTKView) {
            guard metalDevice == nil else { return }
            // The camera entry task reports preparation failures. An absent snapshot here
            // can also mean that the async preparation has not finished yet.
            guard let resources = PreviewMetalResources.shared.rendererResources else { return }
            view.device = resources.device
            metalDevice = resources.device
            commandQueue = resources.commandQueue
            computePipeline = resources.computePipeline
            finishPipeline = resources.finishPipeline
            materialFinishPipeline = resources.materialFinishPipeline
            textureCache = resources.textureCache
            energyDownsampler = resources.energyDownsampler
            view.delegate = self
            renderingAvailabilityChanged(!view.isPaused && view.window != nil)
            manager?.diagnostics.event("preview_renderer_installed")
        }

        func flushFrameCache() {
            // Shared caches outlive the camera view. Release unused entries on exit;
            // in-flight GPU work still owns its CVMetalTexture and CVPixelBuffer lease.
            if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        }

        func renderingAvailabilityChanged(_ active: Bool) {
            completionGate.setActive(active)
            if !active { drawables.invalidate() }
            // Reattaching may reuse the latest native frame. It still needs a fresh GPU
            // completion in the new renderer epoch before the entry overlay can reveal.
            lastRenderedFrameId = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            drawables.invalidate()
            lastRenderedFrameId = nil
            manager?.diagnostics.event("preview_drawable_changed", "width=\(Int(size.width)) height=\(Int(size.height)) scale=\(view.contentScaleFactor)")
        }

        // MARK: - 每帧渲染（全 Metal，无 CIImage/CIFilter）

        // 一次性诊断用计数器
        private var skipFrameCount: Int = 0
        private var didLogFirstDraw: Bool = false
        private var diagnosticCycle: UInt64?
        private var firstPresentationRegistered = false
        private var frameWindowStart: CFAbsoluteTime?
        private var submittedFrames = 0
        private var cpuFrameCount = 0
        private var cpuTotalMS = 0.0
        private var cpuMaxMS = 0.0
        private var backpressureDrops = 0

        func draw(in view: MTKView) {
            // A queued draw can arrive after pause/detachment. Do not acquire a drawable then:
            // on device this blocked the main thread for 556 ms during app deactivation.
            (view as? CameraPreviewMetalView)?.refreshInterfaceOrientation()
            guard !view.isPaused, view.window != nil, view.bounds.width > 0, view.bounds.height > 0,
                  UIApplication.shared.applicationState == .active else { return }
            let flow = manager?.flowDiagnostics
            guard let preparedLUT, preparedLUT.key == lutCacheKey else { flow?.skipped(.lut); return }
            // 过渡计划（每 vsync 拉一次，即使没有新帧也要执行——淡出/淡回正发生在停顿窗口，
            // 那时恰无新帧）：crop = 扩展数字变焦倍率（帧对齐后的渲染侧上限作分母，见
            // PreviewCropCeilingSynchronizer）；metalOpacity = 停顿窗口内淡出本视图、露出
            // 系统预览底衬，恢复后淡回；普通拍照停顿保持胶片层不透明。
            let transitionPlan = manager?.previewTransitionPlan() ?? (crop: 1, metalOpacity: 1)
            // Entry readiness needs a real GPU frame behind its opaque loading overlay.
            // UIKit must not suppress this view through the ordinary lens-transition fade.
            view.alpha = manager?.entryPreparation.isRevealed == true ? transitionPlan.metalOpacity : 1
            manager?.updatePreviewOpacity(view.alpha)
            // 帧去重：如果相机没有产生新帧，跳过渲染（crop 在稳态是常量，重复帧无需重绘）
            guard let (pixelBuffer, frameId, capturedAt, focalSequence, sourceRevision) = manager?.previewFrames.latestFrame() else {
                flow?.skipped(.noFrame)
                return
            }
            guard frameId != lastRenderedFrameId else { flow?.skipped(.duplicate); return }

            let trace = manager?.diagnostics
            let generation = manager?.diagnosticGeneration ?? 0
            if diagnosticCycle != generation {
                diagnosticCycle = generation
                firstPresentationRegistered = false
                didLogFirstDraw = false
                frameWindowStart = nil; submittedFrames = 0
                cpuFrameCount = 0; cpuTotalMS = 0; cpuMaxMS = 0
                gpuStatistics.reset(generation: generation)
                backpressureDrops = 0
            }
            let cpuStart = Log.now()
            var drawableWaitMS = 0.0
            if frameWindowStart == nil { frameWindowStart = cpuStart }
            defer {
                let elapsed = (Log.now() - cpuStart) * 1_000
                flow?.encoded(cpuMS: elapsed, drawableWaitMS: drawableWaitMS)
                cpuFrameCount += 1
                cpuTotalMS += elapsed
                cpuMaxMS = max(cpuMaxMS, elapsed)
                let windowSeconds = max(0.001, Log.now() - (frameWindowStart ?? cpuStart))
                if cpuFrameCount >= 120 || windowSeconds >= 2 {
                    let cpuAverage = cpuTotalMS / Double(cpuFrameCount)
                    let gpu = gpuStatistics.take(generation: generation)
                    let gpuAverage = gpu.totalMS / Double(max(1, gpu.count))
                    trace?.event("preview_perf", "generation=\(generation) submitted_fps=\(String(format: "%.1f", Double(submittedFrames) / windowSeconds)) cpu_avg_ms=\(String(format: "%.2f", cpuAverage)) cpu_max_ms=\(String(format: "%.2f", cpuMaxMS)) gpu_avg_ms=\(String(format: "%.2f", gpuAverage)) gpu_max_ms=\(String(format: "%.2f", gpu.maximumMS)) gpu_samples=\(gpu.count) dropped=\(backpressureDrops) input=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) output=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))")
                    frameWindowStart = Log.now(); submittedFrames = 0
                    cpuFrameCount = 0; cpuTotalMS = 0; cpuMaxMS = 0
                    backpressureDrops = 0
                }
            }

            // Triple-buffer 背压控制：如果 GPU 有 3 帧在队列中，跳过当前帧
            guard inflightSemaphore.wait(timeout: .now()) == .success else {
                flow?.skipped(.backpressure)
                backpressureDrops += 1
                return
            }

            // Prepare intermediate textures before acquiring a scarce drawable. A cold pool
            // returns immediately while its serial worker allocates away from MainActor.
            let requestedWidth = Int(view.drawableSize.width)
            let requestedHeight = Int(view.drawableSize.height)
            guard let targets = targets(width: requestedWidth, height: requestedHeight) else {
                flow?.skipped(.targets)
                inflightSemaphore.signal()
                return
            }
            var didSubmit = false
            defer {
                if !didSubmit { targetPool.recycle(targets, width: requestedWidth, height: requestedHeight) }
            }

            // Never construct MPS kernels in the draw callback or show a partially prepared film.
            var diffusion: PreviewDiffusionKernelCache.Kernels?
            if optics.hasLightDiffusion {
                guard let recipe = PreviewDiffusionKernelCache.Recipe(optics: optics,
                          width: requestedWidth, height: requestedHeight),
                      let kernels = PreviewDiffusionKernelCache.shared.request(recipe) else {
                    flow?.skipped(.pipeline)
                    inflightSemaphore.signal()
                    return
                }
                diffusion = kernels
            }

            let drawableStartedAt = ProcessInfo.processInfo.systemUptime
            let currentDrawable = (view.layer as? CAMetalLayer).flatMap { layer in
                let source = PreviewDrawableSource(layer: layer)
                return drawables.request(width: requestedWidth, height: requestedHeight, replenish: true) { source.next() }?.drawable
            }
            drawableWaitMS = (ProcessInfo.processInfo.systemUptime - drawableStartedAt) * 1_000
            guard let drawable = currentDrawable else {
                flow?.skipped(.drawable)
                inflightSemaphore.signal()
                return
            }
            guard let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let pipeline = computePipeline,
                  let finishPipeline,
                  let cache = textureCache else {
                flow?.skipped(.pipeline)
                inflightSemaphore.signal()
                skipFrameCount += 1
                if skipFrameCount % 60 == 1 {
                    Log.session.error("preview_skip n=\(self.skipFrameCount)")
                }
                return
            }

            if !didLogFirstDraw {
                didLogFirstDraw = true
                trace?.event("preview_first_draw", "generation=\(generation)")
                Log.session.info("preview_first_draw skipped=\(self.skipFrameCount) lut_key=\(self.lutCacheKey, privacy: .public)")
            }

            // 定期刷新纹理缓存，释放不再使用的 CVMetalTexture（每 300 帧 ≈ 10s）
            frameCount &+= 1
            if frameCount % 300 == 0 {
                CVMetalTextureCacheFlush(cache, 0)
            }

            let inW = CVPixelBufferGetWidth(pixelBuffer)
            let inH = CVPixelBufferGetHeight(pixelBuffer)

            // CVPixelBuffer → MTLTexture（零拷贝，GPU 直接读取相机帧内存）
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil,
                .bgra8Unorm, inW, inH, 0, &cvTexture
            )
            guard status == kCVReturnSuccess,
                  let cvTex = cvTexture,
                  let inputTexture = CVMetalTextureGetTexture(cvTex) else {
                flow?.skipped(.texture)
                inflightSemaphore.signal()
                return
            }

            // The immutable texture was allocated and uploaded before this selection was published.
            let lutTexture = preparedLUT.texture
            let lutDim = preparedLUT.dimension

            let outW = drawable.texture.width
            let outH = drawable.texture.height
            guard outW == requestedWidth, outH == requestedHeight else {
                flow?.skipped(.targets)
                inflightSemaphore.signal()
                return
            }

            // Sensor buffers stay unrotated. Match the actual window, including
            // landscape iPad windows and upside-down rotations of the same size.
            let rotation = CameraOrientationPolicy.previewRotation(for: manager?.previewInterfaceOrientation ?? .portrait)

            let framing = CameraFraming.previewTransform(input: CGSize(width: inW, height: inH),
                rotation: rotation, output: CGSize(width: outW, height: outH), zoom: transitionPlan.crop)

            // 色温响应增益每帧取一次：内部低通平滑消化 WB 读数的量化台阶。
            let chromaticGain = chromaticGainForFrame()

            let longEdge = CGFloat(max(outW, outH))
            let grainSampling = grain.sampling(forLongEdge: longEdge)
            var params = PreviewParams(
                scale: Float(framing.scale),
                offsetX: Float(framing.offset.x),
                offsetY: Float(framing.offset.y),
                inputWidth: UInt32(inW),
                inputHeight: UInt32(inH),
                rotation: rotation,
                lutDimension: UInt32(lutDim),
                grainAmount: grain.amount * grainSampling.scale,
                grainSize: grain.pixelSize(forLongEdge: longEdge),
                grainChroma: grain.chroma,
                grainSeed: FilmGrainRenderer.mixedSeed(
                    base: 0x4A53_4752,
                    counter: UInt32(truncatingIfNeeded: frameId)
                ),
                halationAmount: optics.halationAmount,
                // 光晕半径按源流（传感器 FOV）长边归一——预览流、48MP 成片、Live 帧各按
                // 自身长边换算，光晕占画面比例一致，预览即所得。
                halationRadiusPx: optics.radiusPixels(
                    optics.halationRadius, forLongEdge: CGFloat(max(outW, outH))
                ),
                halationHue: optics.halationHue,
                bloomAmount: optics.bloomAmount,
                bloomRadiusPx: optics.radiusPixels(
                    optics.bloomRadius, forLongEdge: CGFloat(max(outW, outH))
                ),
                highlightThreshold: FilmOpticsParameters.highlightThreshold,
                headroomAmount: optics.headroomAmount,
                headroomShoulder: optics.headroomShoulder,
                chromaticGainR: chromaticGain.x,
                chromaticGainG: chromaticGain.y,
                chromaticGainB: chromaticGain.z,
                chromaticHighlightProtection: chromatic.protectsHighlights ? 1 : 0,
                grainResponse: grain.shaderResponse,
                lutIntensity: lutIntensity,
                grainBroadOffset: grainSampling.broadOffset,
                grainFineOffset: grainSampling.fineOffset,
                grainFineWeight: grainSampling.fineWeight
            )

            if let material = preparedLUT.material {
                params.materialDensityDimension = Float(material.density.width)
                params.materialPrintDimension = Float(material.paper.width)
                params.materialFinishDimension = Float(material.finish.width)
                params.materialMaximumR = material.maximum.x
                params.materialMaximumG = material.maximum.y
                params.materialMaximumB = material.maximum.z
                params.materialMinimumR = material.minimum.x
                params.materialMinimumG = material.minimum.y
                params.materialMinimumB = material.minimum.z
                params.materialRefineX = material.refinement.x
                params.materialRefineY = material.refinement.y
                params.materialRefineZ = material.refinement.z
                params.materialRefineW = material.refinement.w
                params.materialNeutralRetention = material.colorBalance?.neutralRetention ?? 0
                params.materialSkinHueRetention = material.colorBalance?.skinHueRetention ?? 0
                params.materialSkinChromaRetention = material.colorBalance?.skinChromaRetention ?? 0
                params.materialSkinResponse = material.colorBalance?.shaderResponse ?? 0
                params.materialExposureResponse = material.exposureResponse
                params.materialShadowLift = material.calibration?.shadowLift ?? 0
                params.materialToneCeiling = material.calibration?.toneCeiling ?? 0.6
                params.materialGrainScale = material.calibration?.grainScale ?? 1
                params.materialIdentityFlags = material.identityFlags
            }

            // 编码 compute 命令
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                flow?.skipped(.encoder)
                inflightSemaphore.signal()
                return
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(lutTexture, index: 1)
            encoder.setTexture(targets.graded, index: 2)
            encoder.setTexture(targets.energy, index: 3)
            encoder.setBytes(&params, length: MemoryLayout<PreviewParams>.size, index: 0)

            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: outW, height: outH, depth: 1)
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)

            encoder.endEncoding()

            if let diffusion {
                energyDownsampler?.encode(commandBuffer: commandBuffer, sourceTexture: targets.energy, destinationTexture: targets.smallEnergy)
                diffusion.halation?.encode(commandBuffer: commandBuffer, sourceTexture: targets.smallEnergy, destinationTexture: targets.halation)
                diffusion.bloom?.encode(commandBuffer: commandBuffer, sourceTexture: targets.smallEnergy, destinationTexture: targets.bloom)
            }
            guard let composite = commandBuffer.makeComputeCommandEncoder() else {
                flow?.skipped(.encoder)
                inflightSemaphore.signal()
                return
            }
            if let material = preparedLUT.material {
                guard let materialFinishPipeline else {
                    flow?.skipped(.pipeline)
                    inflightSemaphore.signal()
                    return
                }
                composite.setComputePipelineState(materialFinishPipeline)
                composite.setTexture(material.density, index: 4)
                composite.setTexture(material.paper, index: 5)
                composite.setTexture(material.finish, index: 6)
            } else {
                composite.setComputePipelineState(finishPipeline)
            }
            composite.setTexture(targets.graded, index: 0)
            composite.setTexture(optics.halationAmount > 0.0001 ? targets.halation : targets.energy, index: 1)
            composite.setTexture(optics.bloomAmount > 0.0001 ? targets.bloom : targets.energy, index: 2)
            composite.setTexture(drawable.texture, index: 3)
            composite.setTexture(inputTexture, index: 7)
            composite.setBytes(&params, length: MemoryLayout<PreviewParams>.size, index: 0)
            composite.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            composite.endEncoding()

            let firstSubmission = !firstPresentationRegistered
            let submittedAt = ProcessInfo.processInfo.systemUptime
            let completionGate = self.completionGate
            let manager = self.manager
            // Each changed look requires its own presentation confirmation. Native
            // configuration warmup must still precede the first accepted frame.
            let lookKey = presentedLookKey ?? lutCacheKey
            let readiness = manager?.needsPreviewRender(lutKey: lookKey, capturedAt: capturedAt) == true
                ? completionGate.ticket(generation: generation, lutKey: lookKey) : nil
            let flowStamp = flow?.submitted(at: submittedAt, capturedAt: capturedAt)
            let renderedFrame = CameraPreviewFrame(buffer: pixelBuffer, generation: generation,
                frameID: frameId, capturedAt: capturedAt, lutKey: lookKey, rotation: rotation,
                crop: transitionPlan.crop, outputSize: CGSize(width: outW, height: outH), grainSeed: params.grainSeed,
                chromaticGain: chromaticGain, lutIntensity: params.lutIntensity,
                focalSequence: focalSequence, sourceRevision: sourceRevision)
            let presentationLease = CameraPreviewPresentationLease(renderedFrame)
            if firstSubmission {
                firstPresentationRegistered = true
                trace?.event("preview_first_submitted", "generation=\(generation) output=\(outW)x\(outH)")
                #if targetEnvironment(simulator)
                trace?.event("preview_presentation_unavailable", "platform=simulator")
                #endif
            }
            #if !targetEnvironment(simulator)
            drawable.addPresentedHandler { drawable in
                if let frame = presentationLease.takeFrame(), drawable.presentedTime > 0 {
                    manager?.recordPresentedPreview(frame, at: drawable.presentedTime)
                }
                if let flowStamp { flow?.presented(flowStamp, at: drawable.presentedTime, submittedAt: submittedAt) }
                if firstSubmission {
                    trace?.event(drawable.presentedTime > 0 ? "preview_first_presented" : "preview_presentation_unconfirmed",
                        "generation=\(generation) submit_to_present_ms=\(Diagnostics.milliseconds(since: submittedAt))")
                }
                if drawable.presentedTime > 0, let readiness, completionGate.complete(readiness) {
                    Task { @MainActor in
                        guard completionGate.isCurrent(readiness) else { return }
                        manager?.previewDidRender(generation: readiness.generation,
                            lutKey: readiness.lutKey, capturedAt: capturedAt)
                    }
                }
            }
            #endif
            let semaphore = self.inflightSemaphore
            let targetPool = self.targetPool
            let gpuStatistics = self.gpuStatistics
            let frameLease = PreviewFrameLease(texture: cvTex, buffer: pixelBuffer)
            commandBuffer.addCompletedHandler { [weak self] buffer in
                let completedAt = ProcessInfo.processInfo.systemUptime
                frameLease.release()
                if firstSubmission { trace?.event("preview_first_gpu_completed", "generation=\(generation) after_submit_ms=\(Diagnostics.milliseconds(since: submittedAt))") }
                if buffer.status == .error {
                    let errorFields = buffer.error.map { Diagnostics.errorFields($0) } ?? "error_domain=unknown"
                    trace?.event("preview_gpu_error", "generation=\(generation) \(errorFields)")
                    Log.session.error("preview_gpu_failed error=\(buffer.error?.localizedDescription ?? "unknown", privacy: .public)")
                }
                let gpuMS = max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1_000
                gpuStatistics.record(generation: generation, milliseconds: gpuMS)
                if let flowStamp {
                    flow?.completed(flowStamp, gpuMS: gpuMS, elapsedMS: (completedAt - submittedAt) * 1_000, failed: buffer.status == .error)
                }
                targetPool.recycle(targets, width: outW, height: outH)
                semaphore.signal()
                if let flowStamp { flow?.recycled(flowStamp, waitMS: (ProcessInfo.processInfo.systemUptime - completedAt) * 1_000) }
                let succeeded = buffer.status == .completed
                // Simulator drawables do not reliably report presentation. On a
                // device only presentation unlocks capture; GPU failure still ends
                // preparation with the existing retry UI.
                #if targetEnvironment(simulator)
                if let frame = presentationLease.takeFrame(), succeeded {
                    manager?.recordPresentedPreview(frame, at: completedAt)
                }
                let notifyCompletion = true
                #else
                if !succeeded { _ = presentationLease.takeFrame() }
                let notifyCompletion = !succeeded
                #endif
                if notifyCompletion, let readiness, completionGate.complete(readiness) {
                    Task { @MainActor [weak self] in
                        guard let self, completionGate.isCurrent(readiness),
                              (self.presentedLookKey ?? self.lutCacheKey) == readiness.lutKey else { return }
                        if succeeded {
                            self.manager?.previewDidRender(generation: readiness.generation,
                                lutKey: readiness.lutKey, capturedAt: capturedAt)
                        } else {
                            self.manager?.previewDidFail(generation: readiness.generation, lutKey: readiness.lutKey)
                        }
                    }
                }
            }

            commandBuffer.present(drawable)
            didSubmit = true
            commandBuffer.commit()
            lastRenderedFrameId = frameId
            submittedFrames += 1
        }
    }
}
