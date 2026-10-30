import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import CoreLocation
import CoreMotion
import UIKit
import MetalKit
import os

// MARK: - 相机管理器
//
// MainActor owns UI/delegate state. The serial hardware queue owns device/session changes;
// CameraCaptureAdmission freezes one exposure across storage reservation and native capture.
// Pure policies, lens admission, Metal preview, and device diagnostics live in separate files.

/// 一次拍照的完整产出，跨 actor 边界传给 CameraView 的后处理。非 live 时只有 imageData，
/// 其余为 nil/invalid。live 时还带配对视频文件 URL + content identifier + still-image-time，
/// 供 LivePhotoProcessor 套 LUT 并重写配对元数据后存为 Live Photo。
struct CaptureResult: Sendable {
    let imageData: Data
    let livePhotoMovieURL: URL?
    let photoDisplayTime: CMTime
    let warning: CaptureWarning?
    let deferredPhoto: DeferredPhotoState?

    init(imageData: Data, livePhotoMovieURL: URL?, photoDisplayTime: CMTime, requestedLive: Bool = false,
         deferredPhoto: DeferredPhotoState? = nil) {
        self.imageData = imageData
        self.livePhotoMovieURL = livePhotoMovieURL
        self.photoDisplayTime = photoDisplayTime
        warning = requestedLive && livePhotoMovieURL == nil ? .livePhotoMovieUnavailable : nil
        self.deferredPhoto = deferredPhoto
    }
}

enum CaptureWarning: Equatable, Sendable {
    case livePhotoMovieUnavailable

    var message: String {
        switch self {
        case .livePhotoMovieUnavailable:
            String(localized: "The still photo will be saved, but its Live Photo video could not be captured.")
        }
    }
}

struct CaptureStill: Sendable {
    let imageData: Data
    let pendingLivePhotoMovieURL: URL?
    var deferredPhoto: DeferredPhotoState? = nil
}

enum CameraReadiness: Equatable {
    case idle
    case requestingPermission
    case configuring
    case waitingForFirstFrame
    case ready
    case failed

    var logValue: String {
        switch self {
        case .idle: return "idle"
        case .requestingPermission: return "requesting_permission"
        case .configuring: return "configuring"
        case .waitingForFirstFrame: return "waiting_first_frame"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

@MainActor
class CameraManager: NSObject, ObservableObject {

    nonisolated let diagnostics: DiagnosticTrace
    nonisolated let flowDiagnostics: CameraFlowDiagnostics
    nonisolated var diagnosticGeneration: UInt64 { sessionIntent.withLock { $0.generation } }

    // MARK: 1. 存储属性

    /// 虚拟设备 AVCaptureSession（iOS 26 推荐架构）：以 .builtInTripleCamera 等虚拟设备作为
    /// 单一 input；切焦距 = 把 videoZoomFactor ramp 到目标 + `.restricted` 切换策略 — 系统在内部
    /// 按 zoom 做硬件级 constituent crossfade（能切长焦就切、近物/暗光裁主摄），预览不黑屏，无需 bridgeImage。
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    /// 当前 session 的虚拟（或物理）设备 input —— 整个生命周期只 add 一次，不 swap。
    private var currentVideoInput: AVCaptureDeviceInput?
    /// 当前 video 设备（虚拟或物理）。focus / exposure / zoom 都打在它身上；
    /// constituent 切换由系统在内部完成，对外仍是同一个 device 实例。
    private var videoCaptureDevice: AVCaptureDevice? { currentVideoInput?.device }
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var usesPreviewProxyBuffers = true
    private var previewConfiguredForLivePhoto = false
    private let previewQueue = DispatchQueue(label: "preview.lut.queue")
    /// 专用会话队列（AVCaptureSession 操作必须在同一串行队列）
    nonisolated private static let hardwareQueue = DispatchQueue(label: "camera.hardware.queue", qos: .userInitiated)
    private let sessionQueue = CameraManager.hardwareQueue
    private let sessionIntent = OSAllocatedUnfairLock(initialState: CameraSessionIntent())
    private let captureAdmission = OSAllocatedUnfairLock(initialState: CameraCaptureAdmission())
    private var isCameraVisible = false

    /// 线程安全的像素缓冲区（用 os_unfair_lock 保护跨线程访问）
    private struct PreviewState: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var frameId: UInt64 = 0
        var lastFrameAt: TimeInterval?
        var focalSequence: UInt64 = 0
        var sourceRevision: UInt64 = 0
        var renderedFrame: CameraPreviewFrame?
        var droppedFrames: UInt64 = 0
        var lastDropReason = "none"
        var lastDropLogAt: TimeInterval = 0
    }
    private let pixelBufferLock = OSAllocatedUnfairLock(initialState: PreviewState())

    /// 切焦距时用于丢弃过时回调的单调递增 token（用户快速来回点档位时旧任务不会把
    /// 新档位的 lock 撤掉）。
    private var applyFocalToken: UInt64 = 0
    /// The hardware queue checks the newest request independently of the main-actor settle task.
    private let latestFocalRequest = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// 镜头切换的稳定轮询 task：beginLensSwitch 启动，每 ~30ms evaluateLensSettle 一次，直到
    /// 镜头到位 + grace 走完（finishLensSwitch），或 maxWait 兜底超时。新一次 beginLensSwitch 取消旧的。
    private var lensSettleTask: Task<Void, Never>?
    private var lensSettleDeadline: TimeInterval?
    private var framingSettledAt: TimeInterval?
    private let lensSourceStability = OSAllocatedUnfairLock(initialState: CameraLensCaptureGate.SourceStability())
    private var lastTeleLockAttempt: CameraLensCaptureGate.RequestStamp?

    /// 弱引用 MTKView，用于从相机回调触发渲染。
    /// `internal` 而不是 `private`：`MetalPreview.swift` 的 `RealtimePreviewView.updateUIView`
    /// 直接写 `manager.previewMTKView = uiView` —— 跨文件协作但属于同一模块的 view-controller 关系。
    weak var previewMTKView: MTKView?

    /// 首帧到达标记（线程安全，仅打印一次）
    private let firstFrameFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// 预览旋转角度。
    /// `internal` 而不是 `private`：`MetalPreview.swift` 的渲染 coordinator 读它来决定
    /// CVPixelBuffer → drawable 的 90°/180°/270° 旋转。和上面的 `previewMTKView` 一样，
    /// 是同模块跨文件的 view-controller 协作；其余 preview-related 状态（如 device orientation
    /// 缓存）都保持 private。
    var previewRotationAngle: CGFloat?
    private var previewDeviceOrientation: UIDeviceOrientation?

    /// 一次拍照在途的全部状态打包成单一值对象——取代旧的 photoDataHandler /
    /// exposureCompleteHandler / willCaptureHandler 等分散 optional。
    /// capturePhoto 入口创建、issueCapturePhoto 按 settings.uniqueID 登记进 inFlightCaptures，
    /// deliverCaptureIfReady 消费。每个 closure 只被对应 delegate 触发一次（AVF 保证每个 delegate
    /// 每次 capture 调一次）。
    ///   - onData          : 完整交付（非 live：静态图；live：静态图 + 配对视频）就绪后回调恰好一次
    ///                       （nil = 失败/中断）。**这是后处理的启动信号，不是快门放开信号。**
    ///   - onShutterReady  : 静态图已持久化时回调恰好一次——CameraView 据此放开
    ///                       快门让用户拍下一张。**与 onData 解耦**：live 时静态图 ~300ms 就到，而
    ///                       配对视频要等 ~1.5s 环形缓冲；快门只需等前者，视频交给后台后处理。
    ///   - onWillCapture   : 主曝光起始帧——屏幕白屏挂载点（与氙气主脉冲同帧）。
    ///   - onExposureComplete: 曝光物理完成（仅诊断）。
    private struct CaptureRequest {
        let admission: CameraCaptureAdmission.Token
        let trace: DiagnosticTrace
        let onData: (CaptureResult?) -> Void
        let onShutterReady: () -> Void
        let onStillCaptured: (@MainActor (CaptureStill) async -> Void)?
        let onWillCapture: (() -> Void)?
        let onExposureComplete: (() -> Void)?
        /// 本次拍照是否要求 Live Photo（issue 阶段已设 livePhotoMovieFileURL）。true 时 onData 要等
        /// 静态图 + 动态视频两个交付物都到齐（或 didFinishCaptureFor 终结兜底）才回调一次。
        let expectsLiveMovie: Bool
        let rawFormat: CameraRAWFormat?
        var previewSourceRevision: UInt64? = nil
        // —— 两个异步交付物的累积状态（仅 @MainActor 读写）——
        var stillArrived = false
        var stillData: Data?
        var deferredPhoto: DeferredPhotoState?
        var movieArrived = false
        var movieURL: URL?
        var photoDisplayTime: CMTime = .invalid
        /// onShutterReady / onData 各自只触发一次的幂等守卫（多个 delegate 回调会重入 deliver）。
        var shutterReleased = false
        var resultDelivered = false
        var terminalReceived = false
        var stillCheckpointed = false
        var isCheckpointingStill = false
        var pendingMovieURL: URL?
    }

    /// Immutable AVFoundation arguments retained while a late source change delays invocation.
    private struct NativeCaptureInvocation: @unchecked Sendable {
        let output: AVCapturePhotoOutput
        let settings: AVCapturePhotoSettings
        let admission: CameraCaptureAdmission.Token
        let trace: DiagnosticTrace
        let rotationAngle: CGFloat?
        let expectsLiveMovie: Bool
        let rawFormat: CameraRAWFormat?
        let previewSourceRevision: UInt64?
        let enqueuedAt: TimeInterval
        let deadline: TimeInterval
    }
    /// 在途拍照按 `settings.uniqueID` 分桶——取代旧的单槽 `inFlightCapture?`。分桶后多张拍照可重叠：
    /// 静态图就绪即放开快门，上一张还在等 ~1.5s 配对视频时用户已能按下一张，新旧 capture 各自独立、
    /// 互不覆盖。delegate 回调用 `resolvedSettings.uniqueID` 精确定位到对应 request。
    private var inFlightCaptures: [Int64: CaptureRequest] = [:]
    private let captureTraces = OSAllocatedUnfairLock<[Int64: DiagnosticTrace]>(initialState: [:])
    @Published var flashMode: FlashMode = .off
    @Published private(set) var automaticWhiteBalanceReading: CameraWhiteBalanceReading?
    private var whiteBalanceReadingObservation: NSKeyValueObservation?
    private let whiteBalanceReadingGate = OSAllocatedUnfairLock(initialState: WhiteBalanceReadingGate())
    /// Keep support and actual session enablement separate. Neither changes the saved user preference.
    @Published private(set) var livePhotoCaptureState = LivePhotoCaptureState(supported: false, enabled: false)
    @Published private(set) var rawCaptureFormat: CameraRAWFormat?
    @Published private(set) var usesDeferredPhotoDelivery = false
    private var livePhotoCaptureDesired = false
    private var photoDeliveryConfigurationPending = false
    private var photoDeliveryReconciliationPending = false
    private var rawFormatsObservation: NSKeyValueObservation?
    private var livePhotoSupportObservation: NSKeyValueObservation?
    private var livePhotoEnabledObservation: NSKeyValueObservation?

    // MARK: Live Photo 录音（麦克风）
    //
    // 麦克风输入**只在「Live 开 ＆ 声音开 ＆ 已授权」时**挂到 session 上：普通拍照 / 关掉 Live /
    // 关掉声音时都不挂，避免无谓亮起系统麦克风指示灯（橙点）。开关变化由 CameraView 经
    // setLivePhotoAudio(live:sound:) 告知，内部在 sessionQueue 增删 audio input。
    //
    // 音频会话用 .playAndRecord + .mixWithOthers（用户选定「保持背景音乐播放」），所以把
    // session.automaticallyConfiguresApplicationAudioSession 关掉、自管 AVAudioSession——
    // 否则 AVCapture 会按独占式 .record 抢占、把用户音乐掐断。
    /// CameraView 告知的期望录音状态（live && sound）。session 配置完成后据此 reconcile。
    private var livePhotoAudioDesired: Bool = false
    private var audioReconciliationPending = false
    private var audioPermissionRequestPending = false
    /// 麦克风权限被拒——设置页据此提示用户去开。声音开关仍可开，只是降级为静音。
    @Published var microphonePermissionDenied: Bool = false

    // 震动反馈（预创建复用，减少首次延迟）
    let hapticLight = UIImpactFeedbackGenerator(style: .light)
    let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
    let hapticSoft = UIImpactFeedbackGenerator(style: .soft)

    // 等效焦距
    @Published var currentFocalLength: FocalLengthOption = FocalLengthOption(35)
    @Published var focalInfo: DeviceFocalInfo = .placeholder
    /// 当前 zoom factor。镜头 ramp 期间被 KVO 每帧写入，UI 不直接读 —— 故意不 @Published,
    /// 避免每帧触发 SwiftUI 全 body 重算（一次跨档 ramp 能让 CameraView body 重算 30+ 次，
    /// 把主线程交给 SwiftUI 而非预览渲染）。
    var currentZoomFactor: CGFloat = 1.0
    /// 当前实际激活的物理 constituent（KVO 自虚拟设备 activePrimaryConstituentDevice）。
    /// 仅用于 log，UI 不读。
    private var activeConstituentName: String = ""
    /// 切镜头的目标终态——「就绪」判定的唯一依据。nil = 没有进行中的切换（已稳定）。
    /// 取代旧的 isLensTransitioning(Bool) + expectedConstituent(device)：旧设计把「是否在切换」
    /// 和「切到哪」分开存，且由 3 条 markLensSettled 路径各自翻转，任一条漏判一个条件
    /// （如 isRampingVideoZoom）就会过早放行 capture，出片落在过冲 zoom 上 → EXIF 焦段偏。
    /// 现在「是否到位」完全派生自设备真值（lensIsOnTarget），KVO/轮询只触发重新评估、不翻转状态——
    /// 漏条件这一整类 bug 结构性消失。不 @Published（避免无谓的 SwiftUI 重算），仅供 capture 闸门读。
    private var lensCaptureGate = CameraLensCaptureGate()
    @Published private(set) var lensSwitchFailed = false
    private var zoomObservation: NSKeyValueObservation?
    private var constituentObservation: NSKeyValueObservation?
    /// 活跃 constituent 的区间上限（预览代理流取景钳制点，ExtendedPreviewZoom 的分母）。
    /// 未知（.greatestFiniteMagnitude）时禁用扩展裁切，行为与原始流一致。
    /// 仅是 KVO 侧最新值（日志用）；渲染实际使用 cropCeilingSync 里**帧对齐后**的值。
    private var activeConstituentZoomCeiling: CGFloat = .greatestFiniteMagnitude
    /// 上限→裁切的帧对齐状态机：KVO 只登记，帧流断裂（镜头切换停帧）处才换渲染侧上限，
    /// 否则旧镜头帧拿到新上限算出的裁切会取景跳变（预览闪烁）。
    private let cropCeilingSync = OSAllocatedUnfairLock(initialState: PreviewCropCeilingSynchronizer())
    /// 主源（Metal）↔ 底衬源（系统预览层）混合状态机：主帧流跨镜头切换停顿时把主源淡出、
    /// 露出持续流动的系统合成流（Apple 官方推荐预览路径，见 LensTransitionCompositor.swift）。
    private var underlayBlender = PreviewUnderlayBlender()
    /// 「静止期镜头翻转」的底衬遮罩截止时刻（CFAbsoluteTime）。`.restricted` 的资格评估
    /// 「等 AF/AE 稳定后再落定」会在 zoom 不变的情况下延迟翻转 constituent（2026-10-08
    /// 真机实锤：24mm 以超广角 settle 后 125ms 翻到主摄）——同一位置两次换流即用户可见
    /// 的「来回闪烁」。翻转发生在非 ramp 状态（病理性）时把主源淡出一段，露出系统预览
    /// 层自带的 crossfade（系统相机同款过渡），再淡回分级画面。ramp 中的翻转是正常
    /// 过渡，不遮罩。
    private var underlayFlipMaskUntil: CFTimeInterval = 0
    private var lastUnderlayOpacity: CGFloat = 0
    private var underlayBlendLogged = false
    /// 底衬取景对齐的当前倍率（去抖用）；配套 `underlayAlignmentActive` 只在启用/停用
    /// 边界打日志，避免 ramp 期间按 KVO 步进刷屏。
    private var lastUnderlayAlignmentCrop: CGFloat = 1
    private var underlayAlignmentActive = false
    /// 系统预览层底衬（AVCaptureVideoPreviewLayer）。由 CameraPreviewUnderlayView 挂载，
    /// weak——生命周期归视图，视图释放后引用自动置 nil。
    weak var previewUnderlayLayer: AVCaptureVideoPreviewLayer?
    /// 设备真值 zoom（KVO 每次写入）——扩展裁切的分子。不复用 currentZoomFactor：
    /// UI 可能乐观写目标值，ramp 跨越钳制点的瞬间会把裁切瞬间拉满。
    private var lastObservedDeviceZoom: CGFloat = 1.0
    private var focalLengthPicker: AVCaptureIndexPicker?
    /// 系统级 EV 滑块（iOS 18+）。虚拟设备架构下 device 实例不变，整生命周期内只装一次。
    private var exposureBiasSlider: AVCaptureSystemExposureBiasSlider?
    private var exposureControlEpoch: UInt64 = 0

    // 位置管理器
    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?

    // iOS 18 方向管理（每次 swap 后重建 RotationCoordinator）
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// KVO 监听 coordinator 的 horizon-level 角度。RotationCoordinator 初始值是 0，等运动数据
    /// 到位后才异步收敛——光在 configureAndStartSession 末尾同步读一次，会把错误角度写进 photo
    /// connection（用户横屏入页时，photoOutput.videoRotationAngle 会被钉死成默认值，出片永远是
    /// 错向）。Apple 在 RotationCoordinator 文档里就推荐 KVO 联动，每次值变就 reapply。
    private var captureRotationObservation: NSKeyValueObservation?
    /// UI 端通过此值给悬浮控件（焦距条等）做 rotationEffect。app 整体 UI 锁竖屏，但用户横握时
    /// 控件需要随设备旋转保持"用户视角下水平"，对齐 iPhone Camera 体验。
    @Published var currentDeviceOrientation: UIDeviceOrientation = .portrait
    /// 直接读重力向量做方向判定。系统旋转锁开启时 UIDevice.orientationDidChange 会被节流甚至不发出，
    /// CMMotionManager 不受锁影响，与 iPhone Camera 保持一致——永远响应物理方向。
    private let motionManager = CMMotionManager()
    private var subjectAreaObserver: (any NSObjectProtocol)?
    private var sessionInterruptionObserver: (any NSObjectProtocol)?
    private var sessionInterruptionEndedObserver: (any NSObjectProtocol)?
    private var sessionRuntimeErrorObserver: (any NSObjectProtocol)?
    /// session 是否已完成首次配置；区分"冷启动需要 configureAndStartSession"与"前台返回只 startRunning"
    private var sessionConfigured: Bool = false
    /// 当前 session 周期是否已收到首帧。与 sessionConfigured + lensCaptureGate 共同决定 UI ready。
    private var hasReceivedPreviewFrame = false
    /// 系统中断仍在进行中（来电/控制中心/录屏），interruptionEnded 后 resume
    private var sessionInterrupted: Bool = false

    // 权限状态
    @Published private(set) var readiness: CameraReadiness = .idle
    @Published private(set) var entryPreparation = CameraEntryPreparation()
    private var entryPreparationTask: Task<Void, Never>?
    private var entryResourcesTask: Task<Void, Never>?
    private var entryTimer = CameraEntryPreparation.ActiveTimer()
    private var entrySceneIsActive = true
    private var entryPipelineIsReady = false
    private var previewRendererIsUnavailable = false
    private var entryFailedLUTKey: String?
    @Published var cameraPermissionDenied: Bool = false
    /// 定位权限被拒绝或受限时，UI 显示「位置已关闭」提示
    @Published var locationPermissionDenied: Bool = false

    private var focusHoldTimer: Timer?
    private let tapFocusHoldDuration: TimeInterval = 3.0
    private var focusObservation: NSKeyValueObservation?
    private var pressureObservation: NSKeyValueObservation?
    /// 进入相机时启动 session 的任务句柄；离开时取消，避免在 sessionQueue 上做完整 startRunning 后又被立即停止
    private var startupTask: Task<Void, Never>?
    private var capturePreparationTask: Task<Void, Never>?
    private var captureGeneration: UInt64 = 0
    private var captureWatchdogs: [Int64: Task<Void, Never>] = [:]
    private let exposureApplication = OSAllocatedUnfairLock(initialState: CameraExposureApplication())
    private var isEditingExposure = false
    @Published private(set) var exposureRange = CameraExposureRange()
    /// 正常情况下的目标帧率；由 sessionQueue 写入、压力回调 KVO 读取，用锁保护避免数据竞争
    private let nominalFPSLock = OSAllocatedUnfairLock<Double>(initialState: 30.0)
    @Published var isFocusLocked = false
    /// User intent is independent of focus-reticle lifetime and native processing.
    @Published var exposureBias: Float = 0

    /// 虚拟（或物理）设备 — 整个生命周期固定，不 swap。constituent 由系统按 zoom + `.restricted`
    /// 策略在内部切换。session 配置完成前为 nil。
    private var captureDevice: AVCaptureDevice?

    // MARK: - init / deinit / 设备发现

    override init() {
        let trace = DiagnosticTrace()
        diagnostics = trace
        flowDiagnostics = CameraFlowDiagnostics(trace: trace)
        super.init()
        DiagnosticWatchdog.shared.addCamera(id: diagnostics.id, flow: flowDiagnostics) { [weak self] in self?.previewHealth() }
        diagnostics.event("camera_manager_init")
        diagnostics.measure("orientation_setup") { setupOrientationMonitoring() }
    }

    /// 按 iOS 26 推荐顺序选取后置 capture device。优先虚拟设备：让系统按 videoZoomFactor
    /// 在内部完成 constituent 切换（硬件级 crossfade，无黑屏，能切长焦就切、近物/暗光裁主摄）。
    /// 优先级：triple（UW+W+T）→ dual（W+T）→ dualWide（UW+W）→ 单 wide 兜底。
    nonisolated private static func discoverBestCaptureDevice() -> AVCaptureDevice? {
        let priorities: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: priorities,
            mediaType: .video,
            position: .back
        )
        // DiscoverySession.devices 按 deviceTypes 顺序返回，取第一个即最高优先级
        return discovery.devices.first
    }

    deinit {
        diagnostics.event("camera_manager_deinit")
        DiagnosticWatchdog.shared.removeCamera(id: diagnostics.id)
        // @MainActor class 的 deinit 在 Swift 6 中是 nonisolated，无法访问 @MainActor 隔离的属性。
        // observer / KVO 的生命周期已由 stopSession() 在 onDisappear 时托管。
        // 注意：stopRunning() 虽然线程安全，但是**阻塞调用**（Apple 文档：don't call on main thread）。
        // SwiftUI 释放 @StateObject 时 deinit 通常运行在主线程，若同步调用会阻塞导航返回动画。
        // 因此这里只做异步兜底；真正的停止已由 onDisappear → stopSession() 在 sessionQueue 处理。
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    // MARK: - 2. 帧状态（线程安全的 pixelBuffer / first frame）

    /// 获取最新帧（用于 MTKView 渲染）。`nonisolated` 让 Metal 渲染线程直接读，不绕主 actor。
    nonisolated func getLatestFrame() -> (CVPixelBuffer, UInt64, TimeInterval, UInt64, UInt64)? {
        pixelBufferLock.withLockUnchecked { state in
            guard let buf = state.buffer, let capturedAt = state.lastFrameAt else { return nil }
            return (buf, state.frameId, capturedAt, state.focalSequence, state.sourceRevision)
        }
    }

    nonisolated func recordPresentedPreview(_ frame: CameraPreviewFrame, at presentedAt: TimeInterval) {
        guard sessionIntent.withLock({ $0.permitsStart(frame.generation) }) else { return }
        var presented = frame
        presented.presentedAt = presentedAt
        pixelBufferLock.withLockUnchecked {
            guard $0.renderedFrame.map({ $0.frameID < frame.frameID }) ?? true else { return }
            $0.renderedFrame = presented
        }
    }

    func capturePreview(lutKey: String) -> CameraPreviewFrame? {
        guard isReadyToCapture, let settledAt = framingSettledAt,
              (previewMTKView?.alpha ?? 0) >= 0.999 else { return nil }
        let generation = diagnosticGeneration
        let sourceRevision = lensSourceStability.withLock { $0.revision }
        let expectedCrop = previewZoomCrop()
        let now = ProcessInfo.processInfo.systemUptime
        return pixelBufferLock.withLockUnchecked {
            guard let frame = $0.renderedFrame, frame.lutKey == lutKey,
                  CameraPreviewCapturePolicy.permits(frame: frame, generation: generation,
                    focalSequence: applyFocalToken, sourceRevision: sourceRevision,
                    settledAt: settledAt, expectedCrop: expectedCrop, now: now) else { return nil }
            return frame
        }
    }

    /// Acknowledged shutter presses may wait for the requested lens and its first
    /// visible frame; they never freeze an old view and capture the new focal length.
    func waitForCapturePreview(lutKey: String, admission: CameraCaptureAdmission.Token) async -> CameraPreviewFrame? {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !Task.isCancelled, isCaptureAdmissionValid(admission),
              !lensCaptureGate.hasFailed, ProcessInfo.processInfo.systemUptime < deadline {
            if let frame = capturePreview(lutKey: lutKey) { return frame }
            do { try await Task.sleep(for: .milliseconds(15)) } catch { return nil }
        }
        return nil
    }

    nonisolated func previewHealth() -> PreviewHealth {
        pixelBufferLock.withLockUnchecked { state in
            PreviewHealth(frameID: state.frameId, lastFrameAt: state.lastFrameAt,
                width: state.buffer.map(CVPixelBufferGetWidth) ?? 0,
                height: state.buffer.map(CVPixelBufferGetHeight) ?? 0,
                droppedFrames: state.droppedFrames, lastDropReason: state.lastDropReason)
        }
    }

    nonisolated func setLatestPixelBuffer(_ buffer: CVPixelBuffer) {
        let sequence = latestFocalRequest.withLock { $0 }
        let sourceRevision = lensSourceStability.withLock { $0.revision }
        pixelBufferLock.withLockUnchecked {
            $0.buffer = buffer
            $0.frameId &+= 1
            $0.lastFrameAt = ProcessInfo.processInfo.systemUptime
            $0.focalSequence = sequence
            $0.sourceRevision = sourceRevision
        }
    }

    nonisolated func logFirstFrameOnce(width: Int, height: Int) {
        let shouldLog = firstFrameFlag.withLock { flagged -> Bool in
            guard !flagged else { return false }
            flagged = true
            return true
        }
        if shouldLog {
            let generation = diagnosticGeneration
            diagnostics.event("preview_first_buffer", "generation=\(generation) w=\(width) h=\(height)")
            Log.session.info("preview_first_frame w=\(width) h=\(height)")
            Task { @MainActor [weak self] in
                guard let self, self.sessionIntent.withLock({ $0.permitsStart(generation) }) else { return }
                self.didReceiveFirstPreviewFrame()
            }
        }
    }

    /// 仅在值真正变化时写入 @Published 属性，避免无意义的 objectWillChange 发布
    private func setReadiness(_ value: CameraReadiness) {
        if readiness != value {
            readiness = value
            diagnostics.event("camera_state", "state=\(value.logValue) generation=\(diagnosticGeneration)")
            Log.session.info("camera_readiness state=\(value.logValue, privacy: .public)")
        }
        updateEntryClock()
        if value == .failed {
            failEntry(cameraPermissionDenied ? .permissionDenied : .cameraUnavailable)
        } else {
            refreshEntryReadiness()
        }
        updateCaptureControls()
    }

    /// 每次冷配置/恢复 session 都重新等一张新帧，杜绝旧 pixel buffer 让 UI 过早解锁。
    private func beginCameraPreparation(_ state: CameraReadiness = .configuring) {
        framingSettledAt = nil
        flowDiagnostics.reset(generation: diagnosticGeneration)
        hasReceivedPreviewFrame = false
        firstFrameFlag.withLock { $0 = false }
        pixelBufferLock.withLockUnchecked { $0.buffer = nil; $0.renderedFrame = nil }
        setReadiness(state)
    }

    private func didReceiveFirstPreviewFrame() {
        hasReceivedPreviewFrame = true
        promoteReadinessIfPossible()
    }

    /// UI ready 的单一判定点：session 配置完成、当前周期首帧已到、初始焦段与 ZSL grace 已稳定。
    private func promoteReadinessIfPossible() {
        guard isCameraVisible, !sessionInterrupted, sessionIntent.withLock({ $0.wantsRunning }) else { return }
        guard sessionConfigured,
              hasReceivedPreviewFrame,
              !lensCaptureGate.isTransitioning else {
            if sessionConfigured && readiness != .failed {
                setReadiness(.waitingForFirstFrame)
            }
            return
        }
        setReadiness(.ready)
    }

    private func setCameraDenied(_ denied: Bool) {
        if cameraPermissionDenied != denied { cameraPermissionDenied = denied }
    }
    private func setLocationDenied(_ denied: Bool) {
        if locationPermissionDenied != denied { locationPermissionDenied = denied }
    }

    // MARK: - Entry preparation

    func updateEntryLUT(expectedKey: String, preparedKey: String?) {
        if preparedKey == expectedKey || entryFailedLUTKey != expectedKey { entryFailedLUTKey = nil }
        var next = entryPreparation
        next.updateLUT(expectedKey: expectedKey, preparedKey: preparedKey)
        publishEntry(next)
        refreshEntryReadiness()
    }

    func updateEntryPipelineReady(_ ready: Bool) {
        entryPipelineIsReady = ready
        refreshEntryReadiness()
    }

    private func entryResourcesPrepared(generation: UInt64) {
        guard sessionIntent.withLock({ $0.permitsStart(generation) }) else { return }
        var next = entryPreparation
        next.preparedResources(generation: generation)
        publishEntry(next)
        refreshEntryReadiness()
    }

    func setEntrySceneActive(_ active: Bool) {
        entrySceneIsActive = active
        updateEntryClock()
    }

    func needsPreviewRender(lutKey: String, capturedAt: TimeInterval) -> Bool {
        guard let generation = entryPreparation.generation, isCameraVisible,
              sessionIntent.withLock({ $0.permitsStart(generation) }) else { return false }
        return entryPreparation.needsRender(generation: generation, lutKey: lutKey, capturedAt: capturedAt)
    }

    func previewDidRender(generation: UInt64, lutKey: String, capturedAt: TimeInterval) {
        guard isCameraVisible, sessionIntent.withLock({ $0.permitsStart(generation) }),
              entryPreparation.needsRender(generation: generation, lutKey: lutKey, capturedAt: capturedAt) else { return }
        previewRendererIsUnavailable = false
        var next = entryPreparation
        next.rendered(generation: generation, lutKey: lutKey, capturedAt: capturedAt)
        publishEntry(next)
        refreshEntryReadiness()
    }

    private func entryDeviceConfigurationFinished(generation: UInt64, completedAt: TimeInterval, status: String) {
        guard sessionIntent.withLock({ $0.permitsStart(generation) }) else { return }
        diagnostics.event("camera_entry_device_settled", "generation=\(generation) status=\(status)")
        var next = entryPreparation
        next.preparedDevice(generation: generation, completedAt: completedAt)
        publishEntry(next)
        refreshEntryReadiness()
    }

    /// Synchronous renderer setup failures can precede the view's onAppear/session request.
    func previewRendererUnavailable() {
        previewRendererIsUnavailable = true
        failEntry(.previewUnavailable)
    }

    func previewDidFail(generation: UInt64, lutKey: String) {
        guard sessionIntent.withLock({ $0.permitsStart(generation) }),
              entryPreparation.expectedLUTKey == lutKey else { return }
        previewRendererIsUnavailable = true
        failEntry(.previewUnavailable)
    }

    @discardableResult
    func entryLUTPreparationFailed(key: String) -> Bool {
        guard entryPreparation.expectedLUTKey == key else { return false }
        entryFailedLUTKey = key
        failEntry(.filmUnavailable)
        return !entryPreparation.isRevealed
    }

    func retryEntryPreparation() {
        stopSession()
        previewRendererIsUnavailable = false
        entryFailedLUTKey = nil
        requestCameraPermission()
    }

    private var countsEntryTime: Bool {
        entrySceneIsActive && UIApplication.shared.applicationState == .active &&
            readiness != .requestingPermission && !audioPermissionRequestPending
    }

    private func updateEntryClock() {
        guard entryPreparation.isPreparing else { return }
        entryTimer.update(at: ProcessInfo.processInfo.systemUptime, counting: countsEntryTime)
    }

    private func beginEntryPreparation(generation: UInt64) {
        entryPreparationTask?.cancel()
        entryResourcesTask?.cancel()
        var next = entryPreparation
        next.begin(generation: generation)
        publishEntry(next)
        entryTimer.reset(at: ProcessInfo.processInfo.systemUptime, counting: countsEntryTime)
        if previewRendererIsUnavailable { failEntry(.previewUnavailable); return }
        if entryFailedLUTKey == entryPreparation.expectedLUTKey, entryFailedLUTKey != nil {
            failEntry(.filmUnavailable)
            return
        }
        // Session ownership keeps SwiftUI navigation/toolbar rebuilds from restarting work.
        let preparation = diagnostics.span("camera_entry_resources", "generation=\(generation)")
        entryResourcesTask = Task { @MainActor [weak self] in
            do {
                async let preview: Void = PreviewMetalResources.warmUpForRenderer()
                async let processing: Void = FilmProcessor.shared.warmUpForCapture()
                _ = try await (preview, processing)
                try Task.checkCancellation()
                guard let self, self.entryPreparation.generation == generation else {
                    preparation.end("superseded")
                    return
                }
                self.entryResourcesPrepared(generation: generation)
                preparation.end()
            } catch is CancellationError {
                preparation.end("cancelled")
            } catch {
                preparation.end("error", Diagnostics.errorFields(error))
                guard !Task.isCancelled, let self, self.entryPreparation.generation == generation else { return }
                self.previewRendererUnavailable()
            }
        }
        entryPreparationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.entryPreparation.generation == generation,
                      self.entryPreparation.isPreparing,
                      self.sessionIntent.withLock({ $0.permitsStart(generation) }) else { return }
                self.refreshEntryReadiness()
                guard self.entryPreparation.isPreparing else { return }
                self.updateEntryClock()
                if self.entryTimer.elapsed >= 12 {
                    self.failEntry(.timedOut)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    private func refreshEntryReadiness() {
        guard entryPreparation.isPreparing, let generation = entryPreparation.generation,
              sessionIntent.withLock({ $0.permitsStart(generation) }) else { return }
        var next = entryPreparation
        next.updateReadiness(generation: generation, session: readiness == .ready,
            preview: hasReceivedPreviewFrame, capture: isReadyToCapture, pipeline: entryPipelineIsReady)
        publishEntry(next)
    }

    private func failEntry(_ failure: CameraEntryPreparation.Failure) {
        guard let generation = entryPreparation.generation else { return }
        var next = entryPreparation
        next.fail(failure, generation: generation)
        publishEntry(next)
    }

    private func cancelEntryPreparation() {
        entryPreparationTask?.cancel()
        entryPreparationTask = nil
        entryResourcesTask?.cancel()
        entryResourcesTask = nil
        var next = entryPreparation
        next.cancel()
        publishEntry(next)
    }

    private func publishEntry(_ next: CameraEntryPreparation) {
        guard next != entryPreparation else { return }
        entryPreparation = next
        let phase: String
        switch next.phase {
        case .inactive: phase = "inactive"
        case .preparing: phase = "preparing"
        case .revealed: phase = "revealed"
        case .failed: phase = "failed"
        }
        diagnostics.event("camera_entry_state", "phase=\(phase) generation=\(next.generation.map(String.init) ?? "none") reason=\(next.failure?.rawValue ?? "none") waiting=\(next.pendingRequirements.isEmpty ? "none" : next.pendingRequirements)")
        updateCaptureControls()
    }

    // MARK: - 3. 方向监控（CoreMotion 直读重力向量，绕过系统旋转锁）

    private func setupOrientationMonitoring() {
        bootstrapInitialOrientationIfNeeded()
        startAccelerometerOrientationUpdates()
    }

    /// 启动加速度计读取并转换为 UIDeviceOrientation。5 Hz 足够流畅，CPU/电池开销忽略不计。
    /// 重力向量约定（Apple）：accel 报"重力方向"，portrait 时 -y_d 朝下 → accel.y ≈ -1；
    /// upsideDown ≈ +1；landscapeLeft（home 在右、设备 +x 朝天）重力沿 -x → accel.x ≈ -1；
    /// landscapeRight（home 在左、设备 +x 朝地）重力沿 +x → accel.x ≈ +1。
    private func startAccelerometerOrientationUpdates() {
        guard motionManager.isAccelerometerAvailable, !motionManager.isAccelerometerActive else { return }
        motionManager.accelerometerUpdateInterval = 0.2
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.updateOrientationFromAcceleration(data.acceleration)
        }
    }

    /// 把重力向量映射成 UIDeviceOrientation。带阈值过滤：设备过于水平（|z| 占优）保留当前方向，
    /// 避免桌面/俯视摆放时方向乱跳。仅在判定值与当前不同时写入，触发的 @Published 通知最少。
    private func updateOrientationFromAcceleration(_ a: CMAcceleration) {
        let absX = abs(a.x)
        let absY = abs(a.y)
        let absZ = abs(a.z)

        // 主轴必须显著大于 z 轴（设备不能太平），且至少 0.5g 量级才算"明确指向"
        guard max(absX, absY) > 0.5, max(absX, absY) > absZ else { return }

        let candidate: UIDeviceOrientation
        if absY > absX {
            candidate = a.y < 0 ? .portrait : .portraitUpsideDown
        } else {
            // landscapeLeft（home 在右）：accel.x ≈ -1；landscapeRight（home 在左）：accel.x ≈ +1
            candidate = a.x > 0 ? .landscapeRight : .landscapeLeft
        }

        guard candidate != currentDeviceOrientation else { return }
        currentDeviceOrientation = candidate
        previewDeviceOrientation = candidate
        applyVideoOrientationToOutputs()
    }

    /// 停止加速度计（页面退出时调用）
    private func stopAccelerometerOrientationUpdates() {
        if motionManager.isAccelerometerActive {
            motionManager.stopAccelerometerUpdates()
        }
    }

    private func bootstrapInitialOrientationIfNeeded() {
        if previewDeviceOrientation == nil || previewDeviceOrientation == .unknown {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let io = scene.effectiveGeometry.interfaceOrientation
                let dev: UIDeviceOrientation
                switch io {
                case .portrait: dev = .portrait
                case .portraitUpsideDown: dev = .portraitUpsideDown
                case .landscapeLeft: dev = .landscapeRight
                case .landscapeRight: dev = .landscapeLeft
                default: dev = .portrait
                }
                previewDeviceOrientation = dev
                currentDeviceOrientation = dev
                applyVideoOrientationToOutputs()
            }
        }
    }

    /// 监听 RotationCoordinator 的 horizon-level capture 角度。该值依赖 motion sensor 异步收敛——
    /// 如果用户横屏入页，光在 configureAndStartSession 末尾同步读一次会读到尚未收敛的默认值,
    /// 把 photoOutput.connection.videoRotationAngle 钉死成错向，导致出片永远是错角度。KVO 联动后,
    /// motion 数据一到位就 reapply，与 Apple 在 RotationCoordinator 文档里推荐的做法一致。
    private func observeCaptureRotationAngle() {
        captureRotationObservation?.invalidate()
        guard let coordinator = rotationCoordinator else { return }
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyVideoOrientationToOutputs()
            }
        }
    }

    private func applyVideoOrientationToOutputs() {
        // 预览旋转 vs 出片旋转必须解耦——对齐 iPhone 系统相机的体验：
        //
        // 1) **预览（MTKView）**：UI 在 AppDelegate 锁死竖屏，viewport 永远 3:4 portrait。
        //    无论用户竖握还是横握，预览框都不旋转，所以这里固定 90°（sensor landscape → portrait viewport
        //    的 CW 旋转）。
        //
        // 2) **出片（photoOutput.connection）**：跟随物理设备朝向，让 JPEG 的"上"方向与用户当时的"上"方向
        //    一致。横握 → 出 4:3 横片，竖握 → 出 3:4 竖片。相册/详情靠 EXIF orientation 渲染，横片在竖屏
        //    UI 里就上下留黑边横向展示，与系统 Photos 一致。
        //    使用 RotationCoordinator.videoRotationAngleForHorizonLevelCapture：portrait→90, landscapeRight→0,
        //    landscapeLeft→180, upsideDown→270。
        previewRotationAngle = 90

        guard let coordinator = rotationCoordinator else { return }
        let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let pconn = photoOutput.connection(with: .video),
           pconn.isVideoRotationAngleSupported(captureAngle) {
            pconn.videoRotationAngle = captureAngle
        }
        Log.orientation.info("rotation_applied preview=90° capture=\(Int(captureAngle))° device=\(self.currentDeviceOrientation.rawValue)")
    }

    // MARK: - 4. 对焦 / 曝光补偿

    private var isExposing: Bool {
        captureAdmission.withLock { $0.isBusy } || capturePreparationTask != nil ||
            inFlightCaptures.values.contains { !$0.shutterReleased }
    }

    private func updateCaptureControls() {
        let enabled = entryPreparation.isRevealed && readiness == .ready && !isExposing
        focalLengthPicker?.isEnabled = enabled
        exposureBiasSlider?.isEnabled = enabled
    }

    /// Freeze hardware settings before the view awaits storage reservation.
    func beginCaptureAdmission() -> CameraCaptureAdmission.Token? {
        guard entryPreparation.isRevealed, readiness == .ready, isCaptureAvailable, !isExposing,
              sessionIntent.withLock({ $0.wantsRunning }) else { return nil }
        let generation = diagnosticGeneration
        let focalSequence = applyFocalToken
        let focalLength = currentFocalLength.rawValue
        let userBias = exposureBias
        let flashEnabled = flashMode == .on
        let rotationAngle = rotationCoordinator.map { Double($0.videoRotationAngleForHorizonLevelCapture) }
        latestFocalRequest.withLock { $0 = focalSequence }
        let token = captureAdmission.withLock {
            $0.begin(sessionGeneration: generation, focalSequence: focalSequence,
                focalLength: focalLength, exposureBias: userBias,
                flashEnabled: flashEnabled, rotationAngle: rotationAngle)
        }
        updateCaptureControls()
        return token
    }

    func isCaptureAdmissionValid(_ token: CameraCaptureAdmission.Token) -> Bool {
        let generation = diagnosticGeneration
        return sessionIntent.withLock { $0.permitsStart(token.sessionGeneration) } &&
            captureAdmission.withLock { $0.permits(token, generation: generation) }
    }

    func cancelCaptureAdmission(_ token: CameraCaptureAdmission.Token) {
        captureAdmission.withLock { _ = $0.cancel(token) }
        updateCaptureControls()
    }

    /// Exposed bytes keep their checkpoint path. Pending reservations and native invocations
    /// are cancelled instead of being carried into a later session generation.
    private func cancelUnexposedCapture() {
        capturePreparationTask?.cancel()
        guard let cancelled = captureAdmission.withLock({ $0.cancelUnissued() }) else { return }
        for id in inFlightCaptures.keys.filter({ inFlightCaptures[$0]?.admission == cancelled }) {
            deliverCaptureIfReady(id: id, terminal: true)
        }
        updateCaptureControls()
    }

    private func configureDevice(_ operation: @escaping @Sendable (AVCaptureDevice) -> Void) {
        guard let device = videoCaptureDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                operation(device)
            } catch {
                Log.session.error("device_configuration_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setFocusAndExposure(normalizedPoint: CGPoint, resetExposure: Bool = true) {
        diagnostics.event("focus_requested", "readiness=\(readiness.logValue) exposing=\(isExposing)")
        guard !isExposing, videoCaptureDevice != nil else { return }
        configureDevice { device in
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = normalizedPoint }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = normalizedPoint }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
        }
        if resetExposure { setExposureBias(0) }
        isFocusLocked = true
        startFocusHoldTimer()
    }

    /// Coalesce touch updates; completion confirms native application, not full AE convergence.
    func setExposureBias(_ bias: Float) {
        guard !isExposing, let device = videoCaptureDevice,
              let clamped = exposureRange.clamp(bias) else { return }
        exposureBias = clamped
        let shouldSchedule = exposureApplication.withLock { $0.request(clamped) }
        guard shouldSchedule else { return }
        let application = exposureApplication
        let intent = sessionIntent
        let generation = diagnosticGeneration
        let trace = diagnostics
        sessionQueue.async {
            guard let request = application.withLock({ $0.takePending() }),
                  application.withLock({ $0.permits(request) }),
                  intent.withLock({ $0.permitsStart(generation) }) else { return }
            let applying = trace.span("exposure_bias_apply", "ev=\(request.bias) sequence=\(request.sequence)")
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard application.withLock({ $0.permits(request) }),
                      intent.withLock({ $0.permitsStart(generation) }) else {
                    applying.end("superseded")
                    return
                }
                device.setExposureTargetBias(request.bias) { time in
                    application.withLock { $0.acknowledge(request) }
                    applying.end("applied", "buffer_time=\(time.seconds)")
                }
            } catch {
                application.withLock { $0.fail(request) }
                applying.end("error", Diagnostics.errorFields(error))
            }
        }
    }

    func beginExposureAdjustment() {
        isEditingExposure = true
        focusHoldTimer?.invalidate()
        focusHoldTimer = nil
    }

    func endExposureAdjustment() {
        guard isEditingExposure else { return }
        isEditingExposure = false
        refreshFocusHold()
    }

    private func waitForExposureApplication() async -> Bool {
        let waiting = diagnostics.span("exposure_bias_wait", "ev=\(exposureBias)")
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !Task.isCancelled, !exposureApplication.withLock({ $0.isReady || $0.hasFailed }),
              ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        let ready = !Task.isCancelled && exposureApplication.withLock { $0.isReady }
        waiting.end(ready ? "ready" : "not_applied")
        return ready
    }

    /// 对焦完成回调（KVO isAdjustingFocus → false）
    private func onFocusCompleted() {
        diagnostics.event("focus_completed")
        // 对焦完成后可用于触发 UI 更新（如对焦框缩小动画）
        // 注意：此回调对 continuousAutoFocus 的每次重收敛也会触发，不只是 tap-to-focus。
        // 日志主要用于诊断 tap 是否真的让镜组动了——lensPosition 会从原值收敛到目标。
        if let device = videoCaptureDevice {
            Log.session.debug("focus_completed device=\(device.localizedName, privacy: .public) lens_position=\(String(format: "%.3f", device.lensPosition)) mode=\(device.focusMode.rawValue) locked=\(self.isFocusLocked)")
        }
        NotificationCenter.default.post(name: .focusDidComplete, object: nil)
    }

    private func startFocusHoldTimer() {
        focusHoldTimer?.invalidate()
        guard !isEditingExposure else { return }
        focusHoldTimer = Timer.scheduledTimer(withTimeInterval: tapFocusHoldDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.restoreContinuousFocus()
            }
        }
    }

    /// 用户结束 EV 调整后重置 3s 保持计时器，
    /// 让 reticle 不会在用户还在交互时突然消失。仅在已锁定状态下生效，避免无端续期。
    func refreshFocusHold() {
        guard isFocusLocked else { return }
        startFocusHoldTimer()
    }

    /// Restore continuous AF/AE after the temporary point hold, preserving the user EV.
    func restoreContinuousFocus() {
        guard !isExposing, !isEditingExposure else { startFocusHoldTimer(); return }
        focusHoldTimer?.invalidate()
        focusHoldTimer = nil
        isFocusLocked = false
        configureDevice { device in
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
    }

    // MARK: - 5. Flash (native metering and white balance)

    func toggleFlashMode() {
        guard !isExposing else { return }
        flashMode = (flashMode == .on) ? .off : .on
    }

    // MARK: - 6. 权限

    func requestCameraPermission() {
        diagnostics.event("camera_open_requested", "app_state=\(UIApplication.shared.applicationState.rawValue)")
        isCameraVisible = true
        guard UIApplication.shared.applicationState != .background else {
            sessionIntent.withLock { _ = $0.request(running: false) }
            startupTask?.cancel()
            return
        }
        let token = sessionIntent.withLock { $0.request(running: true) }
        beginEntryPreparation(generation: token)
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            self.diagnostics.event("camera_permission_status", "status=\(status.rawValue)")
            Log.session.info("permission_camera_status status=\(status.rawValue)")
            switch status {
            case .authorized:
                self.setCameraDenied(false)
                await self.configureAndStartSession(token: token)
                if Task.isCancelled { return }
                self.startLocationServices()
            case .notDetermined:
                self.setReadiness(.requestingPermission)
                let permission = self.diagnostics.span("camera_permission_wait")
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                permission.end(granted ? "granted" : "denied")
                Log.session.info("permission_camera_result granted=\(granted)")
                if Task.isCancelled { return }
                if granted {
                    self.setCameraDenied(false)
                    await self.configureAndStartSession(token: token)
                    if Task.isCancelled { return }
                    self.startLocationServices()
                } else {
                    self.setCameraDenied(true)
                    self.setReadiness(.failed)
                }
            case .denied, .restricted:
                Log.session.error("permission_camera_denied")
                self.setCameraDenied(true)
                self.setReadiness(.failed)
            @unknown default:
                self.setReadiness(.failed)
                break
            }
        }
    }

    // MARK: - 6b. Live Photo 录音（麦克风输入 + 混音音频会话）

    /// CameraView 在入页 / 切换 Live 或声音开关时调用，告知期望的录音状态。
    /// `live` = 顶栏 Live Photo 开关；`sound` = 设置页「Live Photo 声音」开关。
    /// 两者皆开且麦克风已授权时才把麦克风挂上 session；据此 reconcile（幂等，状态未变即 no-op）。
    func setLivePhotoAudio(live: Bool, sound: Bool) {
        diagnostics.event("audio_requested", "live=\(live) sound=\(sound) permission=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        livePhotoAudioDesired = live && sound
        livePhotoCaptureDesired = live
        reconcilePhotoDelivery()
        reconcileAudioInput()
    }

    /// Deferred delivery is an output-wide option. Switch it only between captures;
    /// Live Photo retains its existing still/movie pipeline and native supported size.
    private func reconcilePhotoDelivery() {
        guard isCameraVisible, sessionConfigured, let device = videoCaptureDevice,
              sessionIntent.withLock({ $0.wantsRunning }) else { return }
        guard inFlightCaptures.isEmpty, !photoDeliveryConfigurationPending else {
            photoDeliveryReconciliationPending = true
            return
        }
        photoDeliveryReconciliationPending = false
        let live = livePhotoCaptureDesired
        let authorized = PhotoLibrary.isAuthorized
        let enabled = CameraCapturePolicy.usesDeferredDelivery(
            supported: photoOutput.isAutoDeferredPhotoDeliverySupported
                && device.activeFormat.supportedMaxPhotoDimensions.contains(where: CameraCapturePolicy.requiresDeferredDelivery),
            photosAuthorized: authorized, livePhoto: live)
        let reconfigurePreview = live != previewConfiguredForLivePhoto
        guard enabled != photoOutput.isAutoDeferredPhotoDeliveryEnabled || reconfigurePreview else {
            usesDeferredPhotoDelivery = enabled
            return
        }
        photoDeliveryConfigurationPending = true
        if reconfigurePreview {
            // Invalidate an already-admitted old frame before hardware work can
            // race the output change. Fresh frames are gated again after commit.
            let stamp = focalRequestStamp()
            lensSourceStability.withLock { source in
                _ = source.record(stamp: stamp, observationEpoch: source.observationEpoch,
                    at: ProcessInfo.processInfo.systemUptime)
            }
        }
        let generation = diagnosticGeneration
        let output = photoOutput
        let videoOutput = videoDataOutput
        let captureSession = session
        let trace = diagnostics
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.sessionIntent.withLock({ $0.permitsStart(generation) }) {
                let switching = trace.span("photo_delivery_apply", "live=\(live) deferred=\(enabled)")
                captureSession.beginConfiguration()
                self.configurePhotoDelivery(output: output, device: device, live: live, photosAuthorized: authorized)
                if reconfigurePreview {
                    CameraPerformancePolicy.configurePreviewOutput(videoOutput,
                        sourceDimensions: CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription),
                        livePhoto: live)
                    self.applyPreviewStabilization(output: videoOutput, device: device)
                }
                captureSession.commitConfiguration()
                // Dimension/output negotiation can clear Live enablement. Recheck at
                // this idle capture boundary before exposing the new mode to the UI.
                Self.prepareLivePhotoOutput(output, trace: trace, stage: "photo_delivery_changed")
                switching.end("configured", "live_supported=\(output.isLivePhotoCaptureSupported) live_enabled=\(output.isLivePhotoCaptureEnabled) preview_proxy=\(videoOutput.deliversPreviewSizedOutputBuffers)")
            }
            Task { @MainActor in
                guard self.diagnosticGeneration == generation else { return }
                self.photoDeliveryConfigurationPending = false
                self.usesDeferredPhotoDelivery = output.isAutoDeferredPhotoDeliveryEnabled
                self.previewConfiguredForLivePhoto = live
                self.usesPreviewProxyBuffers = videoOutput.deliversPreviewSizedOutputBuffers
                if reconfigurePreview {
                    // In-flight callbacks from the old output cannot authorize the
                    // first capture in the new mode, even at the same focal length.
                    let stamp = self.focalRequestStamp()
                    self.lensSourceStability.withLock { source in
                        _ = source.record(stamp: stamp, observationEpoch: source.observationEpoch,
                            at: ProcessInfo.processInfo.systemUptime)
                    }
                    self.pixelBufferLock.withLockUnchecked { $0.buffer = nil; $0.renderedFrame = nil }
                    self.beginLensSwitch(zoom: self.currentZoomFactor, zslGraceMs: 250, maxWaitMs: 2_500)
                }
                self.updateLivePhotoCaptureState(reason: "photo_delivery_changed")
                self.prepareForFirstCapture()
                self.reconcilePhotoDelivery()
                self.updateCaptureControls()
            }
        }
    }

    /// 把 session 的音频输入收敛到 `livePhotoAudioDesired`。session 未配置完成时 no-op
    /// （configureAndStartSession 末尾会再调一次）。需要麦克风但未授权时按需申请权限。
    private func reconcileAudioInput() {
        guard isCameraVisible, sessionConfigured, sessionIntent.withLock({ $0.wantsRunning }) else { return }
        guard inFlightCaptures.isEmpty else { audioReconciliationPending = true; return }
        audioReconciliationPending = false
        guard livePhotoAudioDesired else {
            applyAudioInput(enabled: false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionDenied = false
            applyAudioInput(enabled: true)
        case .notDetermined:
            guard !audioPermissionRequestPending else { return }
            audioPermissionRequestPending = true
            updateEntryClock()
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard let self else { return }
                self.audioPermissionRequestPending = false
                self.updateEntryClock()
                self.microphonePermissionDenied = !granted
                Log.session.info("permission_mic_result granted=\(granted)")
                // Permission can finish after navigation/backgrounding or during a capture.
                // Re-enter the same lifecycle/in-flight gate instead of changing the graph here.
                self.reconcileAudioInput()
            }
        case .denied, .restricted:
            // 权限被拒：降级为静音 Live Photo（不挂麦克风），设置页据 flag 提示去开。绝不阻断拍摄。
            microphonePermissionDenied = true
            applyAudioInput(enabled: false)
            Log.session.info("permission_mic_denied → silent_live_photo")
        @unknown default:
            applyAudioInput(enabled: false)
        }
    }

    /// 把麦克风输入增删收敛到 `enabled`，全程串行在 sessionQueue 上、以 session 当前 inputs 为**真值**
    /// 判断（不依赖可能滞后的主线程 flag），所以快速连按开关也不会出现「该关没关 / 重复挂」的竞态。
    private func applyAudioInput(enabled: Bool) {
        let generation = diagnosticGeneration
        let intent = sessionIntent
        let captureSession = session
        let trace = diagnostics
        let queuedAt = ProcessInfo.processInfo.systemUptime
        // 设备解析放在主线程（与现有 video input 一致），再带进 sessionQueue。
        let mic = enabled ? AVCaptureDevice.default(for: .audio) : nil
        if enabled && mic == nil {
            Log.session.error("audio_input_no_device")
            entryAudioConfigurationFinished(generation: generation, requested: enabled, attached: false)
            return
        }
        sessionQueue.async { [weak self] in
            guard let manager = self, intent.withLock({ $0.permitsStart(generation) }) else { return }
            let applying = trace.span("audio_input_apply", "enabled=\(enabled) queue_wait_ms=\(Diagnostics.milliseconds(since: queuedAt))")
            defer {
                let attached = Self.audioInput(in: captureSession) != nil
                applying.end("finished", "attached=\(attached)")
                Task { @MainActor in
                    manager.entryAudioConfigurationFinished(generation: generation, requested: enabled, attached: attached)
                }
            }
            let existing = Self.audioInput(in: captureSession)
            if enabled {
                guard let mic else { return }
                // 已挂则只确保音频会话激活，不重复加。
                guard existing == nil else { Self.configureMixAudioSession(active: true); return }
                Self.configureMixAudioSession(active: true)
                guard let input = try? AVCaptureDeviceInput(device: mic) else {
                    trace.event("audio_input_failed", "reason=create_input")
                    Log.session.error("audio_input_create_failed")
                    return
                }
                captureSession.beginConfiguration()
                let added = captureSession.canAddInput(input)
                if added { captureSession.addInput(input) }
                captureSession.commitConfiguration()
                Log.session.info("audio_input_added ok=\(added) inputs=\(captureSession.inputs.count)")
            } else {
                guard let existing else { return }
                captureSession.beginConfiguration()
                captureSession.removeInput(existing)
                captureSession.commitConfiguration()
                Self.configureMixAudioSession(active: false)
                Log.session.info("audio_input_removed inputs=\(captureSession.inputs.count)")
            }
        }
    }

    private func entryAudioConfigurationFinished(generation: UInt64, requested: Bool, attached: Bool) {
        guard !audioPermissionRequestPending, sessionIntent.withLock({ $0.permitsStart(generation) }) else { return }
        let desired = livePhotoAudioDesired && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard desired == requested else { return }
        diagnostics.event("camera_entry_audio_settled", "generation=\(generation) requested=\(requested) attached=\(attached) silent_fallback=\(requested && !attached)")
        var next = entryPreparation
        next.preparedAudio(generation: generation)
        publishEntry(next)
        refreshEntryReadiness()
    }

    /// 当前 session 里已挂的麦克风输入（无则 nil）。nonisolated：供 sessionQueue 闭包做真值判断。
    nonisolated private static func audioInput(in session: AVCaptureSession) -> AVCaptureDeviceInput? {
        session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.audio) }
    }

    /// 配置/停用 app 的 AVAudioSession。`.playAndRecord` + `.mixWithOthers` 让用户的背景音乐
    /// 继续播放（用户选定行为）；`.defaultToSpeaker` 防止录音类目把音乐路由到听筒；`.allowBluetoothHFP`
    /// 让蓝牙耳麦也能录。停用时 `.notifyOthersOnDeactivation` 让被压低音量的其它 app 恢复。
    /// nonisolated static：只碰全局 AVAudioSession 单例，可在 sessionQueue 上安全调用。
    nonisolated private static func configureMixAudioSession(active: Bool) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            if active {
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .videoRecording,
                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
                )
                try audioSession.setActive(true)
            } else {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            Log.session.error("audio_session_config_failed active=\(active) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 7. Session 配置

    /// 在专用串行队列上配置并启动 AVCaptureSession。虚拟设备模式（iOS 26 推荐）：
    /// 单 input（如 .builtInTripleCamera），constituent 切换由系统在内部完成，不再需要 swap。
    private func configureAndStartSession(token: UInt64) async {
        let trace = diagnostics
        trace.event("camera_configuration_requested", "generation=\(token)")
        if sessionConfigured { resumeSessionIfPossible(); return }
        if captureDevice == nil {
            captureDevice = await withCheckedContinuation { continuation in
                let queuedAt = ProcessInfo.processInfo.systemUptime
                sessionQueue.async {
                    trace.event("device_discovery_dequeued", "wait_ms=\(Diagnostics.milliseconds(since: queuedAt))")
                    let device = trace.measure("device_discovery") { Self.discoverBestCaptureDevice() }
                    continuation.resume(returning: device)
                }
            }
        }
        guard !Task.isCancelled, sessionIntent.withLock({ $0.permitsStart(token) }) else { return }
        guard let device = captureDevice else {
            diagnostics.event("camera_unavailable", "reason=no_capture_device generation=\(token)")
            setReadiness(.failed)
            return
        }
        // Native 24 MP processing must round-trip through Photos. Request the same
        // read/write permission already used by saving, before configuring this output.
        let supports24MP = await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: device.formats.contains {
                    $0.supportedMaxPhotoDimensions.contains(where: CameraCapturePolicy.requiresDeferredDelivery)
                })
            }
        }
        if supports24MP { try? await PhotoLibrary.ensureAuthorized(trace: trace) }
        guard !Task.isCancelled, sessionIntent.withLock({ $0.permitsStart(token) }) else { return }
        setupOrientationMonitoring()
        beginCameraPreparation()
        let configTimer = Log.perf("session_configure", logger: Log.session)
        Log.session.info("session_config_begin device=\(device.localizedName, privacy: .public)")

        let captureSession = session
        let output = photoOutput
        let videoOutput = videoDataOutput
        // 把 MainActor 上的 currentFocalLength 抓到 closure 里——sessionQueue 上不能跨回主 actor 读
        let initialFocal = currentFocalLength
        // 建图期挂麦克风的期望状态同样在 MainActor 上快照；快照后的变化由 reconcile 收敛。
        let audioDesired = livePhotoAudioDesired
        let liveDesired = livePhotoCaptureDesired
        let photosAuthorized = PhotoLibrary.isAuthorized
        let intent = sessionIntent
        let queuedAt = Log.now()
        let hardwareCompletedAt = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

        let configuredFocalInfo: DeviceFocalInfo? = await withCheckedContinuation { continuation in
            sessionQueue.async {
                var preparedFocalInfo: DeviceFocalInfo?
                var focalFormat: AVCaptureDevice.Format?
                defer {
                    hardwareCompletedAt.withLock { $0 = ProcessInfo.processInfo.systemUptime }
                    continuation.resume(returning: preparedFocalInfo)
                }
                guard intent.withLock({ $0.permitsStart(token) }) else {
                    trace.event("session_start_discarded", "generation=\(token) reason=stale_intent")
                    return
                }
                let configurationStarted = Log.now()
                Log.session.info("session_queue_wait ms=\(Log.ms(since: queuedAt))")
                trace.event("session_queue_acquired", "generation=\(token) wait_ms=\(Log.ms(since: queuedAt))")
                trace.measure("session_begin_configuration") { captureSession.beginConfiguration() }
                trace.measure("session_preset") { captureSession.sessionPreset = .photo }
                // 自管 AVAudioSession（混音保活背景音乐）——不让 AVCapture 在加麦克风时独占式抢占音频。
                // 无麦克风输入时本设置无副作用：我们压根不激活任何音频会话，背景音乐照常播放。
                captureSession.automaticallyConfiguresApplicationAudioSession = false

                do {
                    let videoInput = try trace.measure("session_input_create") { try AVCaptureDeviceInput(device: device) }
                    if captureSession.canAddInput(videoInput) {
                        trace.measure("session_input_add") { captureSession.addInput(videoInput) }
                    }

                    // 麦克风在**初始建图期**一并挂上（Live+声音开且已授权）：此刻 session 尚未
                    // startRunning，addInput 只是建图的一部分、不触发「运行中重配」断流——
                    // 代价是启动到出画稍慢，但那时画面还没出来、无可感知窗口。首启权限
                    // notDetermined 不在此等待：权限回调后由 session 就绪处的 reconcile 补挂。
                    if audioDesired, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                        if let microphone = AVCaptureDevice.default(for: .audio),
                           let audioInput = try? AVCaptureDeviceInput(device: microphone),
                           captureSession.canAddInput(audioInput) {
                            trace.measure("session_audio_input_add") { captureSession.addInput(audioInput) }
                            Self.configureMixAudioSession(active: true)
                            trace.event("audio_input_builtin", "inputs=\(captureSession.inputs.count)")
                        } else {
                            trace.event("audio_input_builtin_failed", "reason=create_or_add")
                        }
                    }

                    trace.measure("session_format") { self.applyBestFormatAndModes(on: device) }
                    let info = trace.measure("session_focal_info") { DeviceFocalInfo.from(virtualDevice: device) }
                    preparedFocalInfo = info
                    focalFormat = device.activeFormat
                    // 关键：在 startRunning 之前把 videoZoomFactor 设到目标焦段，让 ZSL ring 一开始就
                    // 只收正确 constituent 的帧——见 setInitialFocalLength 注释里的 race 根因 + 修复。
                    trace.measure("session_initial_focal") { self.setInitialFocalLength(on: device, focal: initialFocal, info: info) }

                    let photoSetup = trace.span("session_photo_output")
                    if captureSession.canAddOutput(output) {
                        captureSession.addOutput(output)

                        // Quality is preferred at both output and request.
                        // 预热与每次拍摄使用同一策略；具体计算摄影算法仍由系统按场景选择。
                        output.maxPhotoQualityPrioritization = CameraCapturePolicy.current.qualityPrioritization
                        if output.isResponsiveCaptureSupported {
                            output.isResponsiveCaptureEnabled = true
                        }
                        if output.isFastCapturePrioritizationSupported {
                            output.isFastCapturePrioritizationEnabled = false
                        }
                        if output.isZeroShutterLagSupported {
                            output.isZeroShutterLagEnabled = true
                        }

                        // Still-photo dimensions remain independent of preview proxy size.
                        self.configurePhotoDelivery(output: output, device: device, live: liveDesired, photosAuthorized: photosAuthorized)
                    }

                    photoSetup.end()
                    let previewSetup = trace.span("session_preview_output")
                    CameraPerformancePolicy.configurePreviewOutput(videoOutput,
                        sourceDimensions: CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription),
                        livePhoto: liveDesired)
                    trace.event("preview_output_policy", "strategy=\(videoOutput.automaticallyConfiguresOutputBufferDimensions ? "automatic_proxy" : "scaled_video") live=\(liveDesired)")
                    if captureSession.canAddOutput(videoOutput) {
                        captureSession.addOutput(videoOutput)
                        // connection 在 addOutput 后才存在；必须在 commitConfiguration 前/后任意时机设置。
                        // 这里紧跟 addOutput 设置，与其他输出配置一起原子提交，避免首帧抖动可见。
                        self.applyPreviewStabilization(output: videoOutput, device: device)
                    }
                    previewSetup.end()
                    // Opt in only after the final format, photo dimensions and preview output.
                    // Enabling earlier can be undone by the remaining graph changes.
                    Self.prepareLivePhotoOutput(output, trace: trace, stage: "outputs_configured")
                    if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = true }
                    self.configurePhotoDelivery(output: output, device: device, live: liveDesired, photosAuthorized: photosAuthorized)
                } catch {
                    trace.event("session_configuration_error", Diagnostics.errorFields(error))
                    Log.session.error("session_setup_error error=\(error.localizedDescription, privacy: .public)")
                }

                trace.measure("session_commit_configuration") { captureSession.commitConfiguration() }
                Log.session.info("session_configuration_done ms=\(Log.ms(since: configurationStarted)) preview_proxy=\(videoOutput.deliversPreviewSizedOutputBuffers)")
                guard intent.withLock({ $0.permitsStart(token) }) else { return }
                // commitConfiguration can renegotiate support and clear enablement. Recheck
                // before startRunning, when this cannot interrupt a capture or freeze a preview.
                Self.prepareLivePhotoOutput(output, trace: trace, stage: "before_start")
                let startTimer = Log.perf("session_start_running", logger: Log.session)
                trace.measure("session_start_running") { captureSession.startRunning() }
                startTimer.end()
                // Reuse the initial-focal snapshot unless AVFoundation renegotiated its format.
                // Device metadata reads stay on the hardware queue in either case.
                if focalFormat !== device.activeFormat || preparedFocalInfo == nil {
                    preparedFocalInfo = trace.measure("session_focal_info_refresh") {
                        DeviceFocalInfo.from(virtualDevice: device)
                    }
                }
                trace.event("session_output_ready", "running=\(captureSession.isRunning) inputs=\(captureSession.inputs.count) outputs=\(captureSession.outputs.count) photo=\(output.maxPhotoDimensions.width)x\(output.maxPhotoDimensions.height) live_supported=\(output.isLivePhotoCaptureSupported) live=\(output.isLivePhotoCaptureEnabled) preset=\(captureSession.sessionPreset.rawValue) preview_auto=\(videoOutput.automaticallyConfiguresOutputBufferDimensions) preview_proxy=\(videoOutput.deliversPreviewSizedOutputBuffers)")
                trace.event("camera_configuration_snapshot", "generation=\(token) stabilization=\(videoOutput.connection(with: .video)?.activeVideoStabilizationMode.rawValue ?? -1) \(Self.deviceDiagnosticFields(device))")
                Log.session.info("session_started running=\(captureSession.isRunning) inputs=\(captureSession.inputs.count) outputs=\(captureSession.outputs.count) max_dims=\(output.maxPhotoDimensions.width)x\(output.maxPhotoDimensions.height)")
                // HDR 预览能力探测（只读，不改变交付格式）：预览底图与成片计算摄影的差距
                // （预览所见即所得的剩余缺口）要靠 HDR 预览收敛，落地 EDR 渲染分支前需要
                // 真机事实。两条路径按 SDK 头文件区分：10-bit HLG BT.2020（常开 HDR，需解锁
                // 现在主动锁定的 sRGB 色彩空间 + 10-bit 双平面交付格式 + 渲染器 HLG 解码）；
                // 8-bit EDR 流融合（device.isVideoHDREnabled，半帧率翻倍的代价）。探测三项：
                // 交付格式支持列表、当前 format 的 EDR 能力、系统自动 EDR 的实际状态。
                let availableFormats = Set(videoOutput.availableVideoPixelFormatTypes)
                let hdrFormats: [OSType] = [
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                ]
                let format10BitAvailable = hdrFormats.contains { availableFormats.contains($0) }
                trace.event("preview_hdr_probe", "format_10bit=\(format10BitAvailable) format_edr_supported=\(device.activeFormat.isVideoHDRSupported) device_edr_auto=\(device.isVideoHDREnabled)")
            }
        }

        if let completed = hardwareCompletedAt.withLock({ $0 }) {
            trace.event("session_main_actor_return", "generation=\(token) wait_ms=\(Diagnostics.milliseconds(since: completed))")
        }
        guard !Task.isCancelled, sessionIntent.withLock({ $0.permitsStart(token) }) else {
            trace.event("session_configuration_discarded", "generation=\(token)")
            return
        }
        guard captureSession.isRunning, let configuredFocalInfo else {
            setReadiness(.failed)
            return
        }
        setReadiness(.waitingForFirstFrame)
        usesPreviewProxyBuffers = videoOutput.deliversPreviewSizedOutputBuffers
        previewConfiguredForLivePhoto = liveDesired

        // Back on MainActor — set up delegates and properties that need main thread
        let rotationSetup = trace.span("main_rotation_setup")
        currentVideoInput = captureSession.inputs.first as? AVCaptureDeviceInput
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        observeCaptureRotationAngle()
        rotationSetup.end()
        trace.measure("main_preview_delegate") { videoDataOutput.setSampleBufferDelegate(self, queue: previewQueue) }

        updateLivePhotoCaptureState(reason: "session_ready")
        updateRAWCaptureState()
        usesDeferredPhotoDelivery = photoOutput.isAutoDeferredPhotoDeliveryEnabled
        rawFormatsObservation = photoOutput.observe(\.isAppleProRAWEnabled, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateRAWCaptureState() }
        }
        observeLivePhotoCaptureState()

        focalInfo = configuredFocalInfo
        if !focalInfo.options.contains(currentFocalLength) {
            currentFocalLength = focalInfo.defaultOption
        }

        // 初始 zoom 已在 sessionQueue 配置阶段设好（setInitialFocalLength），这里不再重复
        // applyFocalLength（会多发一次 ramp）。仅同步 MainActor 上的 currentZoomFactor 反映已生效的
        // zoom，让 UI 的焦距条立刻准。
        currentZoomFactor = focalInfo.virtualZoomFactor(for: currentFocalLength)
        lastObservedDeviceZoom = device.videoZoomFactor
        // 启动期同样登记一次镜头切换：让前 ~250ms 的 startRunning warmup 帧被 isReadyToCapture 挡在外面
        // 排空。zoom 启动即在 target（setInitialFocalLength 已设），到位即起 250ms ZSL grace；600ms 兜底。
        beginLensSwitch(zoom: currentZoomFactor, zslGraceMs: 250, maxWaitMs: 600)
        applyVideoOrientationToOutputs()
        configTimer.end("zoom=\(String(format: "%.2f", currentZoomFactor))x")

        #if DEBUG
        // 默认 Debug 也不刷 70+ 行。需要设备诊断时在 Scheme 环境变量加入
        // JUSTSHOOT_LENS_DUMP=1；Release 编译时整个分支不存在。
        if ProcessInfo.processInfo.environment["JUSTSHOOT_LENS_DUMP"] == "1" {
            let args = CameraDeviceDiagnostics.Snapshot(
                device: device,
                focalInfo: focalInfo,
                photoOutput: photoOutput,
                videoDataOutput: videoDataOutput
            )
            Task.detached(priority: .background) {
                CameraDeviceDiagnostics.dump(args)
            }
        }
        #endif

        let controlsSetup = trace.span("main_camera_controls")
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
                updateCaptureControls()
                Log.session.info("camera_control_index_picker_added options=\(titles)")
            }
            // 系统 EV 滑块（绑当前设备）。机身 Camera Control 长按可在 picker / slider 间切换。
            if let device = videoCaptureDevice {
                installExposureBiasSlider(for: device)
            }
            session.setControlsDelegate(self, queue: .main)
        }

        controlsSetup.end()
        let observersSetup = trace.span("main_camera_observers")
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
                self.diagnostics.event("session_interrupted", "reason=\(reason)")
                self.sessionInterrupted = true
                self.sessionIntent.withLock { _ = $0.request(running: false) }
                self.cancelEntryPreparation()
                self.cancelUnexposedCapture()
                self.lensSettleTask?.cancel()
                self.lensSettleTask = nil
                self.beginCameraPreparation()
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
                self.diagnostics.event("session_interruption_ended")
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
                self.diagnostics.event("session_runtime_error", "code=\(code)")
                Log.session.error("session_runtime_error code=\(code) desc=\(desc, privacy: .public)")
                // 大多数 runtime error 是 mediaServicesWereReset / sessionWasInterrupted 类，重启即可恢复
                self.resumeSessionIfPossible()
            }
        }

        observersSetup.end()
        // 上一轮 session 的对齐状态（旧 PTS/上限）不跨周期复用
        cropCeilingSync.withLock { $0.reset() }
        updateActiveConstituentZoomCeiling()
        // 与 setInitialFocalLength 内的设备侧归零对应：冷启动 UI 状态也回 0
        exposureApplication.withLock { $0.reset() }
        exposureBias = 0
        sessionConfigured = true
        trace.event("camera_configuration_complete", "generation=\(token)")

        // session 就绪——按 CameraView 入页时记下的期望状态，决定是否挂麦克风（Live+声音默认开）。
        // 麦克风已在初始建图期随视频输入一并挂上（正常路径），此处 reconcile 幂等：
        // 已挂则只确认音频会话激活，不做 beginConfiguration 重配。
        reconcilePhotoDelivery()
        reconcileAudioInput()

        // ZSL / Deep Fusion / Smart HDR / Photonic Engine 第一次 capture 时会同步初始化 pipeline,
        // 让用户第一张照片 dt_from_tap 出现 1-3 秒延迟（实测 2988ms vs 第二张 186ms）。
        // setPreparedPhotoSettingsArray 是 Apple 官方解决方案：用与正式 capture 完全一致的 settings
        // 提前喂给 AVF，系统会预分配 ring buffer + Smart HDR 多帧融合所需缓冲，第一张瞬间走热路径。
        prepareForFirstCapture()
        // 流式期**首次** device.lockForConfiguration 会阻塞调用线程数百 ms（系统等采集
        // 管线到安全配置点）——用户第一次切焦距/压力调帧率时「点了没反应、随后才动」的
        // 冷启动成本就来自这里。会话刚起跑、用户尚未交互，在 sessionQueue 上预付。
        //
        // 只做同值写入不够（2026-10-08 真机日志实锤）：同值写不触发任何 zoom 变更条件，
        // `.restricted+[.videoZoomChanged]` 的 constituent 重评估 + 流式期首次 ramp 下发
        // 这条真正的大头（首次 focal_hardware_apply 735ms vs 之后 1-3ms，预览停帧 ~1.9s）
        // 只有真实的 zoom 变更才会走到——账单落在用户第一次切焦距上。这里做**出-回微
        // ramp**（±0.02 = 0.7% 视野，随即直接写回瞬时归位）：把首次变更的全套成本付在
        // 入场门控（entryPreparation）放行之前，用户不可见；快门在 ready 前被 gate，
        // ZSL ring 不会流出脏帧。
        if let device = videoCaptureDevice {
            let warmTrace = diagnostics
            let warmIntent = sessionIntent
            sessionQueue.async { [weak self] in
                guard let manager = self, warmIntent.withLock({ $0.permitsStart(token) }) else { return }
                let warming = warmTrace.span("device_config_warmup", "")
                var status = "fallback"
                defer {
                    let completedAt = ProcessInfo.processInfo.systemUptime
                    let completedStatus = status
                    Task { @MainActor in
                        manager.entryDeviceConfigurationFinished(generation: token,
                            completedAt: completedAt, status: completedStatus)
                    }
                }
                do {
                    try device.lockForConfiguration()
                    guard warmIntent.withLock({ $0.permitsStart(token) }) else {
                        device.unlockForConfiguration()
                        status = "superseded"
                        warming.end("superseded")
                        return
                    }
                    _ = Self.applyConstituentSwitchingPolicy(to: device)
                    let base = device.videoZoomFactor
                    let maxZoom = device.activeFormat.videoMaxZoomFactor
                    device.ramp(toVideoZoomFactor: min(maxZoom, base + 0.02), withRate: 32)
                    device.unlockForConfiguration()
                    // 直接写回目标值：取消 ramp 并瞬时归位
                    try device.lockForConfiguration()
                    device.videoZoomFactor = base
                    device.unlockForConfiguration()
                    status = "ok"
                    warming.end("ok", "zoom=\(device.videoZoomFactor)")
                } catch {
                    warming.end("failed", Diagnostics.errorFields(error))
                }
            }
        } else {
            entryDeviceConfigurationFinished(generation: token,
                completedAt: ProcessInfo.processInfo.systemUptime, status: "missing_device_fallback")
        }
        promoteReadinessIfPossible()
    }

    /// 用与 `capturePhoto` 完全一致的 codec / dims / quality settings 预热 photo pipeline。
    /// settings 必须与真实拍摄完全匹配，否则系统按"模板未命中"重走冷启动路径。
    private func prepareForFirstCapture() {
        func makeWarmSettings(flash: AVCaptureDevice.FlashMode) -> AVCapturePhotoSettings {
            let s: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                s = AVCapturePhotoSettings()
            }
            s.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            s.photoQualityPrioritization = CameraCapturePolicy.current.qualityPrioritization(supportedMax: photoOutput.maxPhotoQualityPrioritization)
            if let device = videoCaptureDevice, device.hasFlash {
                s.flashMode = flash
            }
            return s
        }
        // Entry waits for the current flash mode, rather than allocating every mode. Live
        // capture support and its audio graph are prepared separately with the session.
        let selectedFlash: AVCaptureDevice.FlashMode = flashMode == .on ? .on : .off
        let templates = [makeWarmSettings(flash: selectedFlash)]

        let output = photoOutput
        let generation = diagnosticGeneration
        let intent = sessionIntent
        let trace = diagnostics
        sessionQueue.async { [weak self] in
            guard intent.withLock({ $0.permitsStart(generation) }) else { return }
            output.setPreparedPhotoSettingsArray(templates) { prepared, error in
                trace.event("camera_entry_photo_template", "generation=\(generation) prepared=\(prepared) fallback_to_system_ready=\(error != nil || !prepared)")
                if let error {
                    Log.session.error("photo_pipeline_prepare_failed error=\(error.localizedDescription, privacy: .public)")
                } else {
                    Log.session.info("photo_pipeline_prepared ready=\(prepared) templates=\(templates.count)")
                }
                Task { @MainActor in
                    guard let self, intent.withLock({ $0.permitsStart(generation) }) else { return }
                    var next = self.entryPreparation
                    // Preallocation is an optimization; failure can still use the normal
                    // capture path, whose native readiness is an independent requirement.
                    next.preparedPhotoTemplate(generation: generation)
                    self.publishEntry(next)
                    self.refreshEntryReadiness()
                }
            }
        }
    }

    /// Prefer a supported ordinary photo format. Preview buffers and still dimensions are
    /// negotiated separately; choosing a large video format must not imply HEIF Max output.
    nonisolated private func applyBestFormatAndModes(on device: AVCaptureDevice) {
        let candidates = device.formats.filter { fmt in
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard d.width > 0, d.height > 0 else { return false }
            let aspect = Float(d.width) / Float(d.height)
            let supports30 = fmt.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30.0 && $0.maxFrameRate >= 30.0 }
            return abs(aspect - 4.0 / 3.0) < 0.02 && supports30
        }

        let bestFormat = candidates.max { lhs, rhs in
            // Compare the dimensions ordinary mode would actually request.
            let lp = CameraCapturePolicy.automaticPhotoFormatScore(from: lhs.supportedMaxPhotoDimensions)
            let rp = CameraCapturePolicy.automaticPhotoFormatScore(from: rhs.supportedMaxPhotoDimensions)
            if lp != rp { return lp < rp }
            // Tiebreaker：video dim（保高分辨率预览）
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }

        do {
            try device.lockForConfiguration()
            if let bestFormat {
                let current = device.activeFormat
                let keepCurrent = candidates.contains(where: { $0 === current }) &&
                    CameraCapturePolicy.automaticPhotoFormatScore(from: current.supportedMaxPhotoDimensions) ==
                    CameraCapturePolicy.automaticPhotoFormatScore(from: bestFormat.supportedMaxPhotoDimensions)
                let fmt = keepCurrent ? current : bestFormat
                let newDims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                if device.activeFormat !== fmt {
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

            // Cover the early format-ready window; focal configuration then applies
            // the existing 1/max(focalMm, 24) limit (when Safe Shutter Limit is enabled).
            let formatMin = device.activeFormat.minExposureDuration
            let formatMax = device.activeFormat.maxExposureDuration
            device.activeMaxExposureDuration = CameraCapturePolicy.current.exposureDurationCap(
                focalMm: 30, minimum: formatMin, maximum: formatMax)

            let ranges = device.activeFormat.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
            if let targetFPS = CameraPerformancePolicy.frameRate(in: ranges) {
                nominalFPSLock.withLock { $0 = targetFPS }
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            }

            device.unlockForConfiguration()
        } catch {
            Log.session.error("apply_format_lock_failed device=\(device.localizedName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private func configurePhotoDelivery(output: AVCapturePhotoOutput, device: AVCaptureDevice,
                                                   live: Bool, photosAuthorized: Bool) {
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        let deferred = CameraCapturePolicy.usesDeferredDelivery(
            supported: output.isAutoDeferredPhotoDeliverySupported
                && supported.contains(where: CameraCapturePolicy.requiresDeferredDelivery),
            photosAuthorized: photosAuthorized, livePhoto: live)
        if output.isAutoDeferredPhotoDeliveryEnabled != deferred { output.isAutoDeferredPhotoDeliveryEnabled = deferred }
        let selected = CameraCapturePolicy.automaticPhotoDimensions(from: supported, deferredDeliveryEnabled: deferred)
        if let selected, selected.width != output.maxPhotoDimensions.width
            || selected.height != output.maxPhotoDimensions.height {
            output.maxPhotoDimensions = selected
        }
        let supportedText = supported.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
        let selectedText = selected.map { "\($0.width)x\($0.height)" } ?? "none"
        let reason = selected.map { _ in
            CameraCapturePolicy.automaticPhotoFormatScore(from: supported) > 0 ? "ordinary_supported" : "smallest_supported_fallback"
        } ?? "no_supported_4_3_dimensions"
        diagnostics.event("photo_dimensions_selected", "supported=[\(supportedText)] selected=\(selectedText) deferred=\(deferred) live=\(live) reason=\(reason)")
    }

    /// A preview-only stabilization transform can move/crop the viewfinder without
    /// applying the same transform to the still. Keep its framing fixed; native
    /// optical stabilization and photo processing remain owned by the camera.
    nonisolated private func applyPreviewStabilization(output: AVCaptureVideoDataOutput, device: AVCaptureDevice) {
        guard let conn = output.connection(with: .video) else {
            Log.session.info("📷 stabilization_skip reason=no_video_connection device=\(device.localizedName, privacy: .public)")
            return
        }
        conn.preferredVideoStabilizationMode = .off
        Log.session.info("preview_stabilization_applied preferred=off active=\(conn.activeVideoStabilizationMode.rawValue)")
    }

    /// Keep zoom-driven physical switching without scene-driven fallback at a fixed zoom.
    /// The helper avoids rewriting an unchanged policy and explicitly unlocks per-device locks.
    nonisolated private static func applyConstituentSwitchingPolicy(to device: AVCaptureDevice) -> String {
        CameraConstituentSwitchingPolicy.applyRestricted(to: device)
    }

    /// Optional iOS 27 per-device lock. The supported system path remains usable when
    /// this capability is unavailable; the diagnostic result explains each skip.
    nonisolated private static func lockTeleConstituent(_ tele: AVCaptureDevice, on device: AVCaptureDevice,
        permitsRequest: @Sendable () -> Bool) -> String {
        guard #available(iOS 27.0, *) else { return "unsupported_os" }
        guard device.isPrimaryConstituentDeviceSwitchingBehaviorLockedWithDeviceSupported else { return "unsupported_device" }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            guard permitsRequest() else { return "superseded" }
            guard !device.isRampingVideoZoom else { return "ramping" }
            guard device.constituentDevices.contains(where: { $0 === tele }) else { return "target_not_member" }
            guard device.isPrimaryConstituentDeviceSwitchingBehaviorLockedWithDeviceSupported else { return "unsupported_device" }
            if device.primaryConstituentDeviceSwitchingBehavior == .locked,
               device.activePrimaryConstituent === tele { return "already_locked_target" }
            device.setPrimaryConstituentDeviceSwitchingBehaviorLockedWith(tele)
            return "locked"
        } catch {
            Log.session.error("tele_lock_failed error=\(error.localizedDescription, privacy: .public)")
            return "lock_failed"
        }
    }

    private func scheduleTeleLockAfterSettle() {
        let focalSequence = applyFocalToken
        let generation = diagnosticGeneration
        let target = focalInfo.constituent(for: currentFocalLength)
        let tele = focalInfo.teleConstituent
        let device = videoCaptureDevice
        var lockSupported = false
        var reason = "unsupported_os"
        let mapping = focalInfo.constituents.map {
            "\($0.device.deviceType.rawValue):\($0.nativeMm):\($0.virtualZoomRange.lowerBound)-\($0.virtualZoomRange.upperBound)"
        }.joined(separator: ",")
        defer {
            diagnostics.event("focal_tele_lock_decision",
                "focal_seq=\(focalSequence) generation=\(generation) focal_mm=\(currentFocalLength.rawValue) reason=\(reason) lock_supported=\(lockSupported) behavior=\(device.map { String(describing: $0.primaryConstituentDeviceSwitchingBehavior) } ?? "none") target=\(target?.device.deviceType.rawValue ?? "none") tele=\(tele?.device.deviceType.rawValue ?? "none") mapping=[\(mapping)] \(device.map(Self.deviceDiagnosticFields) ?? "device=none")")
        }
        guard #available(iOS 27.0, *) else { return }
        guard let device else { reason = "no_device"; return }
        lockSupported = device.isPrimaryConstituentDeviceSwitchingBehaviorLockedWithDeviceSupported
        guard lockSupported else { reason = "unsupported_device"; return }
        guard let tele else { reason = "no_tele_mapping"; return }
        guard let target else { reason = "no_target_mapping"; return }
        guard target.device === tele.device else { reason = "target_not_tele"; return }
        guard let targetZoom = lensCaptureGate.targetZoom,
              tele.virtualZoomRange.contains(targetZoom) else { reason = "target_zoom_out_of_range"; return }
        if device.primaryConstituentDeviceSwitchingBehavior == .locked,
           device.activePrimaryConstituent === tele.device { reason = "already_locked_target"; return }
        guard permitsFocalRequest(focalSequence, generation: generation) else { reason = "superseded"; return }
        let stamp = CameraLensCaptureGate.RequestStamp(generation: generation, focalSequence: focalSequence)
        guard lastTeleLockAttempt != stamp else { reason = "already_attempted_for_request"; return }
        lastTeleLockAttempt = stamp
        reason = device.primaryConstituentDeviceSwitchingBehavior == .locked ? "replace_other_lock" : "scheduled"
        let activeBefore = device.activePrimaryConstituent?.deviceType.rawValue ?? "none"
        // A lock can change the source after zoom settles. Acknowledge the hardware before
        // starting its own grace, and let source KVO extend that grace if selection arrives later.
        beginLensSwitch(zoom: targetZoom, zslGraceMs: 150, maxWaitMs: 2800, hardwarePending: true)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let state = Self.lockTeleConstituent(tele.device, on: device) {
                self.permitsFocalRequest(focalSequence, generation: generation)
            }
            self.diagnostics.event("focal_tele_lock", "focal_seq=\(focalSequence) generation=\(generation) state=\(state) from=\(activeBefore) \(Self.deviceDiagnosticFields(device))")
            Task { @MainActor [weak self] in
                guard let self, self.permitsFocalRequest(focalSequence, generation: generation),
                      !self.lensCaptureGate.hasFailed else { return }
                // This lock is an optional quality enhancement. A refusal leaves ordinary
                // capture available; it does not require the system to select a specific lens.
                self.lensCaptureGate.hardwareApplied()
                self.evaluateLensSettle()
            }
        }
    }

    /// 在 session config block 内（startRunning 之前）设好初始焦段的虚拟 zoom。
    ///
    /// **为什么在 startRunning 之前设**：让 startRunning 产出的第一帧就来自正确的 constituent，
    /// ZSL ring buffer 从生下来就干净——否则用户在启动早期按快门，AVF 可能从 ring 里挑到启动
    /// 默认 zoom 的帧出片，照片记成错的镜头/焦段。
    ///
    /// 用 `.restricted`（与 applyFocalLength 一致）：设 videoZoomFactor，硬件在
    /// startRunning 时按它选 constituent；固定 zoom 后系统不再做场景驱动的 fallback 换镜头。
    /// 走 nonisolated：从 sessionQueue.async 直接调用，不跨回 MainActor。
    nonisolated private func setInitialFocalLength(on device: AVCaptureDevice, focal: FocalLengthOption,
                                                 info: DeviceFocalInfo) {
        let resolved: FocalLengthOption = info.options.contains(focal) ? focal : info.defaultOption
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
            // constituent 切换策略（见 applyConstituentSwitchingPolicy 头注释）：zoom 必需的切换
            // 不受限，固定 zoom 下禁止场景驱动 fallback。与 zoom 写在同一 lock 块内幂等安全。
            let switchingPolicy = Self.applyConstituentSwitchingPolicy(to: device)
            device.videoZoomFactor = targetZoom
            // 重开相机的 EV 重置（iPhone 相机同款语义）：bias 是设备级状态，会跨
            // stopRunning 存活——新会话一律归零。
            device.setExposureTargetBias(0) { _ in }
            // 安全快门也在此处一并下，避免 startRunning 后第一帧 AE 跑到 1s 上限
            let safeShutter = self.exposureDurationCap(focalMm: resolved.rawValue, format: device.activeFormat)
            device.activeMaxExposureDuration = safeShutter
            device.unlockForConfiguration()
            Log.session.info("focal_init_at_config option=\(resolved.rawValue)mm zoom=\(String(format: "%.2f", targetZoom)) policy=\(switchingPolicy, privacy: .public) target=\(target.device.localizedName, privacy: .public)")
        } catch {
            Log.session.error("focal_init_lock_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 安装/重装系统 EV 滑块（绑定到指定设备）。AVCaptureSystemExposureBiasSlider 是 device-bound 的,
    /// 设备 swap 后必须先 remove 旧的再 add 新的，否则滑块仍调旧设备的 exposureTargetBias，新设备无效。
    /// 安全在 MainActor 调用：和 picker 一样不强制 begin/commitConfiguration（与现有 picker 逻辑一致）。
    private func installExposureBiasSlider(for device: AVCaptureDevice) {
        if let old = exposureBiasSlider {
            session.removeControl(old)
            exposureBiasSlider = nil
        }
        exposureControlEpoch &+= 1
        let controlEpoch = exposureControlEpoch
        exposureRange = CameraExposureRange(minimum: device.minExposureTargetBias, maximum: device.maxExposureTargetBias,
            recommended: device.activeFormat.systemRecommendedExposureBiasRange)
        let slider = AVCaptureSystemExposureBiasSlider(device: device) { [weak self] bias in
            // Camera Control has already applied this change. Do not write it back.
            guard let self, bias.isFinite,
                  self.exposureControlEpoch == controlEpoch,
                  self.videoCaptureDevice === device else { return }
            guard !self.isExposing else { return }
            self.exposureApplication.withLock { $0.acceptSystemChange() }
            self.exposureBias = bias
        }
        if session.canAddControl(slider) {
            session.addControl(slider)
            exposureBiasSlider = slider
            updateCaptureControls()
            Log.session.info("camera_control_bias_slider_added device=\(device.localizedName, privacy: .public) range=\(String(format: "%.1f", device.minExposureTargetBias))–\(String(format: "%.1f", device.maxExposureTargetBias))ev")
        } else {
            Log.session.info("camera_control_bias_slider_skip device=\(device.localizedName, privacy: .public) reason=can_not_add")
        }
    }

    /// 把 zoom / focus / pressure / activePrimaryConstituent KVO 绑到 capture device。
    /// 虚拟设备架构下整个 session 生命周期内 device 实例不变，只在 configureAndStartSession 末尾调一次。
    private func bindDeviceObservers(to device: AVCaptureDevice) {
        let observationEpoch = lensSourceStability.withLock { $0.invalidateObservations() }
        zoomObservation?.invalidate()
        focusObservation?.invalidate()
        pressureObservation?.invalidate()
        constituentObservation?.invalidate()
        whiteBalanceReadingObservation?.invalidate()
        whiteBalanceReadingObservation = device.observe(\.deviceWhiteBalanceGains, options: [.initial, .new]) { [weak self] device, _ in
            self?.scheduleAutomaticWhiteBalanceRead(from: device)
        }

        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] dev, change in
            guard let self, let newZoom = change.newValue else { return }
            let stamp = self.focalRequestStamp()
            let isRamping = dev.isRampingVideoZoom
            self.flowDiagnostics.zoom(Double(newZoom), ramping: isRamping)
            Task { @MainActor in
                guard self.lensSourceStability.withLock({ $0.observationEpoch == observationEpoch }),
                      self.permitsFocalRequest(stamp.focalSequence, generation: stamp.generation) else { return }
                self.currentZoomFactor = newZoom
                self.lastObservedDeviceZoom = CGFloat(newZoom)
                // ramp 推进/停止都戳一下镜头稳定评估（基于设备真值，含 isRampingVideoZoom + zoom 命中）
                self.evaluateLensSettle()
                if isRamping || self.lensCaptureGate.isTransitioning || self.lensCaptureGate.hasFailed { return }
                // 等效焦距按当前活跃 constituent 的原生焦距 + 数字裁切倍率反推（与 virtualZoomFactor
                // 正向同一模型、与 iPhone 原相机一致）。比 primaryNativeMm × zoom 准——后者把最广镜头的
                // 取整标称外推到长焦端会累积误差（200mm 档会被读成 208mm，可能误跳档）。
                let active = self.videoCaptureDevice?.activePrimaryConstituent
                let mm = self.focalInfo.equivalentMm(forZoom: newZoom, activeConstituent: active)
                guard mm > 0 else { return }
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

        // Source selection may complete after zoom settles. Any physical source change starts
        // a fresh ZSL grace; it never requires a particular lens or revives a failed request.
        constituentObservation = device.observe(\.activePrimaryConstituent, options: [.old, .new]) { [weak self] dev, change in
            guard let self else { return }
            let oldID = change.oldValue.flatMap { $0?.uniqueID }
            let newID = change.newValue.flatMap { $0?.uniqueID }
            guard oldID != newID else { return }
            let stamp = self.focalRequestStamp()
            guard self.permitsFocalRequest(stamp.focalSequence, generation: stamp.generation),
                  self.lensSourceStability.withLock({
                      $0.record(stamp: stamp, observationEpoch: observationEpoch,
                          at: ProcessInfo.processInfo.systemUptime)
                  }) else { return }
            let logName = change.newValue.flatMap { $0?.localizedName } ?? "nil"
            let rampingAtFlip = dev.isRampingVideoZoom
            self.diagnostics.event("focal_constituent_changed", "focal_seq=\(stamp.focalSequence) generation=\(stamp.generation) \(Self.deviceDiagnosticFields(dev))")
            Task { @MainActor in
                guard self.lensSourceStability.withLock({ $0.observationEpoch == observationEpoch }),
                      self.permitsFocalRequest(stamp.focalSequence, generation: stamp.generation) else { return }
                if self.activeConstituentName != logName {
                    self.activeConstituentName = logName
                    Log.session.info("constituent_active_changed name=\(logName, privacy: .public)")
                }
                // 静止期翻转（非 ramp 中）= 病理性双跳 → 底衬遮罩窗口（见 underlayFlipMaskUntil）。
                // 与跨镜头预遮罩共用遮罩窗口,只延长不缩短——两者触发条件互斥（翻转遮罩只打
                // 非 ramp 状态,预遮罩只打 ramp 中的跨镜头拉远）,max 合并纯保险。
                if !rampingAtFlip {
                    self.underlayFlipMaskUntil = max(self.underlayFlipMaskUntil, CFAbsoluteTimeGetCurrent() + 0.45)
                    self.diagnostics.event("preview_flip_mask", "lens=\(logName) reason=flip_at_rest")
                }
                self.updateActiveConstituentZoomCeiling()
                if self.lensCaptureGate.sourceDidChange(stamp: stamp) {
                    self.diagnostics.event("focal_source_grace", "focal_seq=\(stamp.focalSequence) generation=\(stamp.generation) grace_ms=150")
                    self.pollLensSettle(maxWaitMs: 2800, preservingDeadline: true)
                }
                self.evaluateLensSettle()
            }
        }
    }

    /// 解析当前活跃 constituent 的区间上限（预览流取景钳制点）。活跃镜头不属于任何
    /// 已知 constituent（物理设备等边缘情况）时设为无界——禁用扩展裁切，行为与原始流一致。
    /// 只更新 KVO 侧登记值；渲染侧上限由 cropCeilingSync 在帧流断裂处对齐生效。
    private func updateActiveConstituentZoomCeiling() {
        let previous = activeConstituentZoomCeiling
        if let active = videoCaptureDevice?.activePrimaryConstituent,
           let range = focalInfo.constituents.first(where: { $0.device === active })?.virtualZoomRange {
            activeConstituentZoomCeiling = range.upperBound
        } else {
            activeConstituentZoomCeiling = .greatestFiniteMagnitude
        }
        if activeConstituentZoomCeiling != previous {
            let ceiling = activeConstituentZoomCeiling
            // 换轨超时随切换策略自适应：.restricted 无缝切换（帧流不断裂）用短超时，
            // 否则上限升向的滞留窗口产生 zoom/旧上限 的虚假裁切——35mm 显示成 ~50mm、
            // 超时换轨再跳回，即「画面大小来回切换」（2026-10-08 真机日志实锤）。
            // .auto 停帧切换保持长超时：断裂信号才是换轨点，超时只兜底无缝假想情形。
            let behavior = videoCaptureDevice?.primaryConstituentDeviceSwitchingBehavior
            let acceptTimeout = behavior == .restricted
                ? PreviewCropCeilingSynchronizer.seamlessAcceptTimeoutSeconds
                : PreviewCropCeilingSynchronizer.stallingAcceptTimeoutSeconds
            cropCeilingSync.withLock {
                $0.kvCeilingDidChange(to: ceiling, at: ProcessInfo.processInfo.systemUptime, acceptTimeout: acceptTimeout)
            }
            diagnostics.event("preview_stream_ceiling",
                "ceiling=\(ceiling.isFinite ? String(format: "%.2f", ceiling) : "unbounded") lens=\(activeConstituentName) accept_ms=\(Int(acceptTimeout * 1_000))")
        }
    }

    /// Ordinary scaled video already carries device zoom. Only an automatically
    /// negotiated proxy fallback may use the legacy, frame-aligned compensation.
    func previewZoomCrop() -> CGFloat {
        ExtendedPreviewZoom.cropFactor(zoom: lastObservedDeviceZoom,
            streamCeiling: cropCeilingSync.withLock { $0.renderCeiling }, usesPreviewProxy: usesPreviewProxyBuffers)
    }

    /// 预览渲染器每 vsync 调用的过渡入口（LensTransitionCompositor 架构的单一接线点）：
    /// - crop：扩展数字变焦倍率（≥1，`previewZoomCrop()`，帧对齐后的分母）；
    /// - metalOpacity：主源视图透明度（停顿窗口内淡出、露出系统预览底衬，恢复后淡回）。
    func previewTransitionPlan() -> (crop: CGFloat, metalOpacity: CGFloat) {
        let crop = previewZoomCrop()
        var mainFrameAge: TimeInterval = pixelBufferLock.withLockUnchecked { state in
            guard let last = state.lastFrameAt else { return .infinity }
            return ProcessInfo.processInfo.systemUptime - last
        }
        // 静止期镜头翻转的遮罩窗口内视主源为「过期」：主源淡出、露出系统预览层的
        // crossfade，窗口结束且帧流新鲜后自然淡回（见 underlayFlipMaskUntil）。
        if CFAbsoluteTimeGetCurrent() < underlayFlipMaskUntil {
            mainFrameAge = .infinity
        }
        let underlayAvailable = previewUnderlayLayer != nil && sessionConfigured
        // An ordinary capture stall must keep the graded frame opaque. The ungraded
        // system stream may cover a lens handoff, but cannot replace the film look
        // whenever disk/system work briefly delays the video delegate.
        let lensTransitionActive = CFAbsoluteTimeGetCurrent() < underlayFlipMaskUntil
            || lensCaptureGate.isTransitioning
        underlayBlender.transitionFloor = LensTransitionPremask.tintFloor
        let opacity = underlayBlender.update(
            mainFrameAge: mainFrameAge,
            underlayAvailable: underlayAvailable,
            lensTransitionActive: lensTransitionActive,
            now: CFAbsoluteTimeGetCurrent()
        )
        recordPreviewUnderlayBlend(1 - opacity, frameAge: mainFrameAge)
        updateUnderlayFramingAlignment(crop: crop)
        return (crop, opacity)
    }

    /// 底衬取景与主源对齐：低光长焦被钳制时，主源用 ExtendedPreviewZoom 居中裁切补足
    ///（200mm 请求预览流钳在 100mm 取景，渲染器裁 2× 补回）；底衬若不跟着放大，停顿
    /// 窗口淡入时会瞬间跳回 100mm 取景。按同一倍率把底衬层绕中心放大——与渲染器的
    /// 居中裁切语义一致（anchorPoint 默认即中心）。禁用隐式动画：每 vsync 直写 transform。
    private func updateUnderlayFramingAlignment(crop: CGFloat) {
        guard let layer = previewUnderlayLayer, crop.isFinite, crop >= 1 else { return }
        guard abs(crop - lastUnderlayAlignmentCrop) > 0.003 else { return }
        lastUnderlayAlignmentCrop = crop
        let active = crop > 1.0005
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(active ? CGAffineTransform(scaleX: crop, y: crop) : .identity)
        CATransaction.commit()
        if active != underlayAlignmentActive {
            underlayAlignmentActive = active
            diagnostics.event("preview_underlay_alignment", "state=\(active ? "scaled" : "identity") crop=\(String(format: "%.2f", crop))")
        }
    }

    /// 记录底衬的可见贡献（1 - Metal alpha）。底衬自身始终不透明，
    /// 仅上层 Metal 淡入淡出，避免两层同时透明时漏出黑底。
    private func recordPreviewUnderlayBlend(_ value: CGFloat, frameAge: TimeInterval) {
        guard abs(value - lastUnderlayOpacity) > 0.003 else { return }
        lastUnderlayOpacity = value
        let revealing = value > 0.5
        if revealing != underlayBlendLogged {
            underlayBlendLogged = revealing
            // 帧龄可为 .infinity（无帧或翻转遮罩窗口强制过期）：Int() 会 fatal，按 watchdog 惯例记 -1。
            diagnostics.event("preview_underlay_blend",
                "state=\(revealing ? "reveal" : "conceal") contribution=\(String(format: "%.2f", value)) main_frame_age_ms=\(frameAge.isFinite ? Int(frameAge * 1_000) : -1)")
        }
    }

    /// 挂载系统预览底衬层（CameraPreviewUnderlayView 生命周期内调用一次）。
    /// 底衬不参与会话连接结构、不影响 sessionPreset 与照片采集链路——它只是 AVFoundation
    /// 自行合成的显示层，镜头切换时拿到系统 crossfade 而非停帧（LensTransitionCompositor.swift）。
    func attachPreviewUnderlay(_ layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        // Only the upper Metal view fades. Fading both layers exposes the black background.
        layer.opacity = 1
        // app UI 锁竖屏：底衬固定 90°（与主源 Metal 渲染的 portrait 旋转一致）。
        // 旋转角设置在 layer.connection 上（iOS 17+ API）；session 尚未连接时 connection
        // 为 nil，90° 本就是 portrait 默认，跳过即可。
        if let connection = layer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            connection.preferredVideoStabilizationMode = .off
        }
        previewUnderlayLayer = layer
        lastUnderlayOpacity = 0
        underlayBlendLogged = false
        diagnostics.event("preview_underlay_attached")
    }

    /// 根据系统压力等级动态调整预览帧率，防止过热降频
    nonisolated private func adjustFrameRateForPressure(device: AVCaptureDevice, level: AVCaptureDevice.SystemPressureState.Level) {
        diagnostics.event("camera_pressure_changed", "level=\(level.rawValue)")
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

        let ranges = device.activeFormat.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
        guard let supportedFPS = CameraPerformancePolicy.frameRate(in: ranges, ceiling: adjustedFPS) else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(supportedFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(supportedFPS))
            device.unlockForConfiguration()
            Log.session.info("pressure_adjusted fps=\(Int(supportedFPS))")
            diagnostics.event("camera_pressure_applied", "fps=\(supportedFPS)")
        } catch {
            Log.session.error("pressure_adjust_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 8. 镜头切换（.restricted 策略）+ 安全快门

    /// Reads only. Never call the custom-gains or temperature/tint setters on a virtual camera.
    nonisolated private func scheduleAutomaticWhiteBalanceRead(from device: AVCaptureDevice) {
        let generation = diagnosticGeneration
        guard sessionIntent.withLock({ $0.permitsStart(generation) }),
              whiteBalanceReadingGate.withLock({ $0.begin(at: ProcessInfo.processInfo.systemUptime) }) else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            var awaitingPublication = false
            defer { if !awaitingPublication { self.whiteBalanceReadingGate.withLock { $0.finish() } } }
            guard self.sessionIntent.withLock({ $0.permitsStart(generation) }) else { return }
            let gains = device.deviceWhiteBalanceGains
            // Zero/invalid startup gains would raise an Objective-C exception in the converter.
            guard CameraWhiteBalancePolicy.canReadGains(red: gains.redGain, green: gains.greenGain,
                blue: gains.blueGain, maximum: device.maxWhiteBalanceGain) else { return }
            let values = device.temperatureAndTintValues(for: gains)
            guard let reading = CameraWhiteBalanceReading(temperature: values.temperature, tint: values.tint) else { return }
            awaitingPublication = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.whiteBalanceReadingGate.withLock { $0.finish() } }
                guard self.isCameraVisible, !self.isExposing,
                      self.sessionIntent.withLock({ $0.permitsStart(generation) }),
                      self.automaticWhiteBalanceReading != reading else { return }
                self.automaticWhiteBalanceReading = reading
                self.diagnostics.event("auto_white_balance_reading", "kelvin=\(reading.temperature) tint=\(reading.tint) source=camera")
            }
        }
    }

    nonisolated private static func prepareLivePhotoOutput(_ output: AVCapturePhotoOutput, trace: DiagnosticTrace, stage: String) {
        let before = LivePhotoCaptureState(output)
        let preparing = trace.span("live_photo_prepare", "stage=\(stage) supported_before=\(before.supported) enabled_before=\(before.enabled)")
        let after = LivePhotoCaptureState.prepare(output)
        preparing.end(after.canCapture ? "enabled" : "unavailable", "stage=\(stage) supported=\(after.supported) enabled=\(after.enabled)")
    }

    private func updateLivePhotoCaptureState(reason: String) {
        let state = LivePhotoCaptureState(photoOutput)
        if state != livePhotoCaptureState {
            livePhotoCaptureState = state
            diagnostics.event("live_photo_state", "reason=\(reason) supported=\(state.supported) enabled=\(state.enabled)")
        }
    }

    private func updateRAWCaptureState() {
        let format = CameraRAWCapturePolicy.format(output: photoOutput, zoom: videoCaptureDevice?.videoZoomFactor ?? 0)
        if format != rawCaptureFormat { rawCaptureFormat = format }
    }

    private func observeLivePhotoCaptureState() {
        livePhotoSupportObservation?.invalidate()
        livePhotoEnabledObservation?.invalidate()
        livePhotoSupportObservation = photoOutput.observe(\.isLivePhotoCaptureSupported, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCameraVisible else { return }
                self.updateLivePhotoCaptureState(reason: "support_changed")
            }
        }
        livePhotoEnabledObservation = photoOutput.observe(\.isLivePhotoCaptureEnabled, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCameraVisible else { return }
                self.updateLivePhotoCaptureState(reason: "enablement_changed")
            }
        }
    }

    /// Hardware state, not localized names or identifiers. Called only at configuration/zoom boundaries.
    nonisolated private static func deviceDiagnosticFields(_ device: AVCaptureDevice) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let gains = device.deviceWhiteBalanceGains
        let duration = device.activeVideoMinFrameDuration.seconds
        return "device=\(device.deviceType.rawValue) constituent=\(device.activePrimaryConstituent?.deviceType.rawValue ?? "none") " +
            "zoom=\(String(format: "%.3f", Double(device.videoZoomFactor))) ramping=\(device.isRampingVideoZoom) format=\(dimensions.width)x\(dimensions.height) " +
            "fov=\(device.activeFormat.videoFieldOfView) binned=\(device.activeFormat.isVideoBinned) fps=\(duration > 0 ? 1 / duration : 0) " +
            "iso=\(device.iso) iso_max=\(device.activeFormat.maxISO) exposure_ms=\(device.exposureDuration.seconds * 1_000) exposure_cap_ms=\(device.activeMaxExposureDuration.seconds * 1_000) ev=\(device.exposureTargetBias) exposure_offset=\(device.exposureTargetOffset) adjusting_ae=\(device.isAdjustingExposure) adjusting_af=\(device.isAdjustingFocus) " +
            "wb=\(gains.redGain),\(gains.greenGain),\(gains.blueGain) pressure=\(device.systemPressureState.level.rawValue)"
    }

    // MARK: 就绪谓词（单一真相）+ 镜头稳定状态机
    //
    // 「能不能拍」不再是被多处回调翻转的布尔标志，而是对设备真值的派生谓词。两层语义分开：
    //   - isCaptureAvailable：session + connection 这类「根本能力」。CameraView 快门入口读它，
    //     false 时静默忽略 tap（权限未授予 / 未配置 / 已离开）。镜头切换中仍为 true（tap 该等、不该丢）。
    //   - isReadyToCapture：在前者基础上再要求镜头到位 + ZSL grace。capturePhoto 内部 await 它。
    // P1（connection）、P2（ramp/zoom）都被收进这两处判定，任何调用方都不可能漏条件。

    /// 根本可用性：session 已配置 + photo connection active。无 active connection 时
    /// photoOutput.capturePhoto 会抛 NSException 崩溃（Obj-C 异常无法 catch），用它在入口兜住。
    var isCaptureAvailable: Bool {
        sessionConfigured && !photoDeliveryConfigurationPending && !photoDeliveryReconciliationPending
            && (photoOutput.connection(with: .video)?.isActive == true)
    }

    /// 完全就绪：根本可用 + 镜头到位 + ZSL grace 走完。capturePhoto 内部 await 它。
    var isReadyToCapture: Bool {
        guard isCaptureAvailable, photoOutput.captureReadiness == .ready,
              let device = videoCaptureDevice else { return false }
        let stamp = focalRequestStamp()
        guard lensSourceStability.withLock({ $0.remainingGrace(stamp: stamp, at: ProcessInfo.processInfo.systemUptime) == 0 }) else { return false }
        return lensCaptureGate.isReady(zoom: device.videoZoomFactor,
            isRamping: device.isRampingVideoZoom)
    }

    /// 镜头取景是否到位：zoom ramp 已停 && zoom 命中目标。**只看 zoom（取景），不看 constituent**——
    /// 用哪颗物理镜头由系统在 zoom 变化时按条件决定（能切长焦就切、近物/暗光裁主摄），都是合法结果，
    /// capture 不该等某颗特定镜头（否则系统拒绝长焦时快门假死）。zoom ramp 总会停，所以这总会到位。
    private func lensIsOnTarget() -> Bool {
        guard let device = videoCaptureDevice else { return false }
        return lensCaptureGate.isOnTarget(zoom: device.videoZoomFactor, isRamping: device.isRampingVideoZoom)
    }

    /// 重新评估镜头是否稳定。由 constituent/zoom KVO 与 lensSettleTask 轮询「戳一下」触发——
    /// 它们不再各自翻转状态，只让这里基于设备真值重新判断（单一判定点）。到位即打点 since、
    /// 回退（又开始 ramp）即清空 since 让 grace 重新计时、到位且 grace 走完即 finishLensSwitch。
    private func evaluateLensSettle() {
        guard let device = videoCaptureDevice,
              lensCaptureGate.evaluate(zoom: device.videoZoomFactor, isRamping: device.isRampingVideoZoom,
                now: ProcessInfo.processInfo.systemUptime) else { return }
        finishLensSwitch(reason: "on_target", failed: false)
    }

    /// 标记一次镜头切换彻底结束（幂等）。on-target + grace 命中，或 maxWait 兜底超时调用。
    private func finishLensSwitch(reason: String, failed: Bool) {
        updateRAWCaptureState()
        guard let targetZoom = lensCaptureGate.targetZoom else { return }
        lensSwitchFailed = failed
        framingSettledAt = failed ? nil : ProcessInfo.processInfo.systemUptime
        if failed {
            lensCaptureGate.fail()
            cancelUnexposedCapture()
        }
        lensSettleTask?.cancel(); lensSettleTask = nil
        lensSettleDeadline = nil
        let active = videoCaptureDevice?.activePrimaryConstituent?.localizedName ?? "nil"
        Log.session.info("lens_settled reason=\(reason, privacy: .public) active=\(active, privacy: .public) zoom=\(String(format: "%.2f", targetZoom)) failed=\(failed)")
        diagnostics.event("focal_settled", "focal_seq=\(applyFocalToken) reason=\(reason) failed=\(failed) target_zoom=\(targetZoom) \(videoCaptureDevice.map(Self.deviceDiagnosticFields) ?? "device=none")")
        flowDiagnostics.flush(reason: "focal_settled", force: true)
        promoteReadinessIfPossible()
        // Evaluate the optional telephoto lock without requiring a particular source to capture.
        if !failed { scheduleTeleLockAfterSettle() }
    }

    /// 开始一次镜头切换：登记目标 zoom + 启动稳定轮询。capture 就绪只看 zoom 到位（见 lensIsOnTarget）。
    /// - zslGraceMs: zoom 到位后给系统 constituent crossfade 收尾的额外等待。
    /// - maxWaitMs: 兜底放弃时刻，超时终结本次请求并拒绝拍摄；重新选焦距后可重试。
    private func beginLensSwitch(zoom: CGFloat, zslGraceMs: Int, maxWaitMs: Int, hardwarePending: Bool = false) {
        framingSettledAt = nil
        let stamp = CameraLensCaptureGate.RequestStamp(generation: diagnosticGeneration, focalSequence: applyFocalToken)
        latestFocalRequest.withLock { $0 = stamp.focalSequence }
        lensCaptureGate.begin(zoom: zoom, graceMs: zslGraceMs, hardwarePending: hardwarePending, stamp: stamp)
        lensSwitchFailed = false
        pollLensSettle(maxWaitMs: maxWaitMs)
    }

    private func pollLensSettle(maxWaitMs: Int, preservingDeadline: Bool = false) {
        guard let stamp = lensCaptureGate.requestStamp else { return }
        let newDeadline = ProcessInfo.processInfo.systemUptime + Double(maxWaitMs) / 1_000
        let deadline = preservingDeadline ? lensSettleDeadline ?? newDeadline : newDeadline
        lensSettleDeadline = deadline
        lensSettleTask?.cancel()
        lensSettleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.permitsFocalRequest(stamp.focalSequence, generation: stamp.generation),
                      self.lensCaptureGate.requestStamp == stamp else { return }
                self.evaluateLensSettle()
                if !self.lensCaptureGate.isTransitioning { return }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    self.finishLensSwitch(reason: "max_wait(\(maxWaitMs)ms)", failed: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// capturePhoto 在 issue 前 await 直到 isReadyToCapture 或超时。唯一闸门，取代旧的
    /// waitForLensSettled + waitForConstituentMatch 两段分散判定。timeoutMs 仅异常兜底——
    /// 正常路径下镜头到位 + grace 走完即放行。超时返回 false，由调用方释放快门并提示重试；
    /// 不能在 zoom 尚未停止时拍出错误焦段。4000 ms 只作异常兜底。
    func waitForReadyToCapture(timeoutMs: Int = 4000) async -> Bool {
        guard !lensCaptureGate.hasFailed else { return false }
        if isReadyToCapture { return !Task.isCancelled }
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + Double(timeoutMs) / 1000.0
        while !Task.isCancelled, !lensCaptureGate.hasFailed, !isReadyToCapture, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        let waited = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if isReadyToCapture {
            Log.capture.info("capture_ready_wait waited=\(String(format: "%.0f", waited))ms")
        } else {
            Log.capture.error("capture_ready_timeout waited=\(String(format: "%.0f", waited))ms on_target=\(self.lensIsOnTarget()) avail=\(self.isCaptureAvailable)")
        }
        return !Task.isCancelled && isReadyToCapture
    }

    /// 安全快门：限制 AE 最长曝光时间，严格走经典 1/focal（35mm 等效）防手持模糊。
    /// 35mm 等效焦距 = `FocalLengthOption.rawValue`，已折算 W/T 物理镜头 + 数码裁切。
    ///   24mm → 1/24s, 35mm → 1/35s, 50mm → 1/50s, 100mm → 1/100s, 200mm → 1/200s
    /// 不再叠加 OIS 放宽 / 主体运动地板——经验表明手持快照"宁可抬 ISO 出噪点、不可拉快门糊掉",
    /// 1/focal 是这条原则下的经典基线，OIS 在该基线之上只是锦上添花的额外余量。
    /// activeMaxExposureDuration 是无侵入做法：不破坏 .continuousAutoExposure，AE 在上限内自由调节；
    /// 触顶时自动改抬 ISO，符合"保锐优先"。
    /// 上下界用 format.min/maxExposureDuration 兜底，避免越界。
    nonisolated private func exposureDurationCap(focalMm: Int, format: AVCaptureDevice.Format) -> CMTime {
        CameraCapturePolicy.current.exposureDurationCap(focalMm: focalMm,
            minimum: format.minExposureDuration, maximum: format.maxExposureDuration)
    }

    /// 把 CMTime 曝光时长格式化为人类可读字符串（"1/Ns" / "X.XXXs"）。
    /// nil / invalid 返回 "n/a"。capture_dispatch 等多处日志复用。
    nonisolated private func formatExposureCMTime(_ time: CMTime?) -> String {
        guard let time, time.isValid, !time.isIndefinite else { return "n/a" }
        let s = CMTimeGetSeconds(time)
        guard s > 0, s.isFinite else { return "n/a" }
        if s < 1 { return "1/\(Int(round(1.0 / s)))s" }
        return String(format: "%.3fs", s)
    }

    /// 外部入口：切换等效焦距
    func setFocalLength(_ option: FocalLengthOption, animated: Bool = true) {
        diagnostics.event("focal_change_requested", "from_mm=\(currentFocalLength.rawValue) focal_mm=\(option.rawValue) animated=\(animated) exposing=\(isExposing) readiness=\(readiness.logValue)")
        guard !isExposing, focalInfo.options.contains(option) else {
            diagnostics.event("focal_rejected", "focal_mm=\(option.rawValue) reason=\(isExposing ? "exposing" : "unsupported")")
            return
        }
        if option == currentFocalLength, let device = videoCaptureDevice,
           lensCaptureGate.canReuseSelection(generation: diagnosticGeneration,
               zoom: device.videoZoomFactor, isRamping: device.isRampingVideoZoom) {
            diagnostics.event("focal_change_reused", "focal_seq=\(applyFocalToken) focal_mm=\(option.rawValue)")
            return
        }
        syncCurrentFocalLength(option)
        applyFocalLength(option, animated: animated)
    }

    /// 单点更新 currentFocalLength 并同步 Camera Control picker 的选中索引。
    /// 程序化设置 selectedIndex 不会回调 picker action，因此安全无重入。
    private func syncCurrentFocalLength(_ option: FocalLengthOption) {
        if currentFocalLength != option {
            currentFocalLength = option
        }
        if let picker = focalLengthPicker,
           let idx = focalInfo.options.firstIndex(of: option),
           picker.selectedIndex != idx {
            picker.selectedIndex = idx
        }
    }

    /// Ramp to the selected zoom under the restricted switching policy. Request tokens discard
    /// superseded hardware work; the capture gate waits for acknowledgement, zoom and ZSL grace.
    /// Supported iOS 27 telephoto selections then lock their constituent with a separate grace.
    private func applyFocalLength(_ option: FocalLengthOption, animated: Bool = true) {
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
        let focalSequence = applyFocalToken
        let focalGeneration = diagnosticGeneration
        latestFocalRequest.withLock { $0 = focalSequence }
        flowDiagnostics.beginFocal(focalSequence)

        // Ramp rate is computed on the hardware queue from the actual zoom, not the optimistic UI target.

        // 单一路径：只把 videoZoomFactor 平滑 ramp 到目标。系统在 ramp 跨越 switchover 阈值时自己做
        // 硬件 crossfade 切 constituent（能切长焦就切、近物/暗光裁主摄）；固定 zoom 下 .restricted 禁止
        // 场景驱动 fallback（见 applyConstituentSwitchingPolicy）。长焦焦段在 settle 后按设备锁定
        //（scheduleTeleLockAfterSettle——iOS 27 per-device lock，仅在 zoom 已入长焦区间后锁定，无旧式
        // 全局 .locked 的钳制瞬跳）；离开长焦焦段的 ramp 由策略重申解锁。不再 deep-ramp
        // 过冲 → 无前后抖动；不再等特定 constituent → 系统拒长焦不假死（锁定仅锦上添花）。
        let maxZoom = device.activeFormat.videoMaxZoomFactor
        let finalZoom = max(1.0, min(maxZoom, targetZoom))
        // The hardware queue records the full snapshot when it applies this request.
        diagnostics.event("focal_begin", "focal_seq=\(focalSequence) generation=\(focalGeneration) focal_mm=\(option.rawValue) target_zoom=\(finalZoom) animated=\(animated)")

        // 乐观更新 UI 焦距 + 立即登记镜头切换目标。此刻设备 zoom 仍是旧值，lensIsOnTarget() 因
        // |旧 zoom − finalZoom| > 0.1 而为 false，isReadyToCapture 仍正确 gate（不会误判已就绪而
        // 让 ZSL 选到旧帧）——所以可以安全地先登记、再异步配置设备。
        self.currentZoomFactor = finalZoom
        // capture 就绪只等 zoom ramp 停（取景到位）+ 一点 ZSL grace 给系统的 constituent crossfade 收尾；
        // 不再等特定 constituent（系统说了算）——所以系统拒绝长焦时快门不假死。maxWait 仅异常兜底。
        // 跨 switchover 的切换实测会停帧 2s+（真机日志：35→13mm 全程 2.1-2.5s），maxWait 放宽到
        // 2.8s 让 settle 判定覆盖真实切换窗口，避免「max_wait 超时但设备仍在 ramp」的假 settle。
        let hardwareNow = max(1, videoCaptureDevice.map { CGFloat($0.videoZoomFactor) } ?? currentZoomFactor)
        let crossesConstituent = focalInfo.crossesConstituentBoundary(fromZoom: hardwareNow, toZoom: finalZoom)
        beginLensSwitch(zoom: finalZoom, zslGraceMs: 150, maxWaitMs: crossesConstituent ? 2800 : 1200, hardwarePending: true)
        // 跨镜头拉远从第 0ms 预遮主源(见 LensTransitionPremask):消除停顿开头的冻结
        // 窗口与淡出重影,底衬的系统 crossfade 直接接管切换;拉近可能无缝,不遮。
        if LensTransitionPremask.shouldMask(crossesConstituent: crossesConstituent, fromZoom: hardwareNow, toZoom: finalZoom) {
            let deadline = CFAbsoluteTimeGetCurrent() + LensTransitionPremask.windowSeconds
            underlayFlipMaskUntil = max(underlayFlipMaskUntil, deadline)
            diagnostics.event("preview_premask",
                "focal_seq=\(focalSequence) to_mm=\(option.rawValue) from_zoom=\(String(format: "%.2f", hardwareNow)) to_zoom=\(String(format: "%.2f", finalZoom)) window_ms=\(Int(LensTransitionPremask.windowSeconds * 1_000))")
        }
        // 同 constituent 内的短跳用**高速短 ramp**：立即设置（上一版）消除了 ramp 死启动的
        // 迟滞感，但真机观感反馈「跳变生硬」——离散跳切对连续取景的视觉冲击大于 ~200-300ms
        // 的连续运动（同镜头跳变 ≤1 档光变，高速率 32 下实际时长与此相当）。跨 switchover
        // 仍走速率阶梯 ramp——渐进逼近让系统从容做 constituent crossfade，避免立即越过阈值
        // 触发更重的管线重配。
        let usesRamp = animated
        let usesFastRamp = !crossesConstituent
        // 目标焦段的承载镜头是长焦 → settle 后锁定该物理镜头（scheduleTeleLockAfterSettle）
        let teleTarget = focalInfo.constituent(for: option)?.device === focalInfo.teleConstituent?.device
        let teleDevice = focalInfo.teleConstituent?.device

        // 设备 I/O（lockForConfiguration + ramp + 安全快门）移到 sessionQueue 执行。streaming 中
        // **首次** lockForConfiguration 会阻塞调用线程数百 ms（系统等采集管线到安全配置点）；放在
        // 主线程就会卡住预览/手势 → 用户感知的「第一次切焦距卡顿」。与 adjustFrameRateForPressure
        // 同款「设备配置走 sessionQueue」模式（Apple AVCam 惯例）。.auto + ramp 单一路径逻辑不变。
        let focalQueuedAt = ProcessInfo.processInfo.systemUptime
        sessionQueue.async { [weak self] in
            self?.diagnostics.event("focal_dequeued", "focal_seq=\(focalSequence) wait_ms=\(Diagnostics.milliseconds(since: focalQueuedAt))")
            self?.configureFocalOnSessionQueue(
                device: device, finalZoom: finalZoom,
                animated: usesRamp, fastRamp: usesFastRamp, teleTarget: teleTarget,
                teleDevice: teleDevice,
                focalMm: option.rawValue, focalSequence: focalSequence, generation: focalGeneration
            )
        }
    }

    /// applyFocalLength 的设备配置段，在 sessionQueue 上执行（nonisolated，不触碰 @MainActor 状态）。
    /// 把 lockForConfiguration/ramp 从主线程移走，避免首次配置阻塞主线程导致预览掉帧。
    nonisolated private func configureFocalOnSessionQueue(
        device: AVCaptureDevice, finalZoom: CGFloat, animated: Bool, fastRamp: Bool, teleTarget: Bool,
        teleDevice: AVCaptureDevice?, focalMm: Int, focalSequence: UInt64, generation: UInt64
    ) {
        let configuring = diagnostics.span("focal_hardware_apply", "focal_seq=\(focalSequence) focal_mm=\(focalMm)")
        var configurationStatus = "error"
        defer {
            configuring.end(configurationStatus, "focal_seq=\(focalSequence)")
            let succeeded = configurationStatus == "ok"
            Task { @MainActor [weak self] in
                guard let self, self.permitsFocalRequest(focalSequence, generation: generation) else { return }
                if succeeded {
                    self.lensCaptureGate.hardwareApplied()
                    self.evaluateLensSettle()
                } else {
                    self.finishLensSwitch(reason: "hardware_apply_failed", failed: true)
                }
            }
        }
        guard permitsFocalRequest(focalSequence, generation: generation) else {
            configurationStatus = "superseded"
            return
        }
        do {
            let lockStart = ProcessInfo.processInfo.systemUptime
            try device.lockForConfiguration()
            let lockWaitMS = (ProcessInfo.processInfo.systemUptime - lockStart) * 1_000
            // lockForConfiguration may wait while the user selects another focal length or leaves.
            guard permitsFocalRequest(focalSequence, generation: generation) else {
                device.unlockForConfiguration()
                configurationStatus = "superseded"
                return
            }
            // Keep a lock only when it holds the intended telephoto source. Other locks
            // are explicitly released before restoring the zoom-driven restricted policy.
            let policyState: String
            let policySpan = diagnostics.span("focal_policy_apply", "focal_seq=\(focalSequence)")
            if teleTarget && device.primaryConstituentDeviceSwitchingBehavior == .locked,
               device.activePrimaryConstituent === teleDevice {
                policyState = "kept_tele_lock"
            } else {
                policyState = Self.applyConstituentSwitchingPolicy(to: device)
            }
            policySpan.end("ok", "policy=\(policyState)")
            guard let transition = CameraZoomTransition(currentZoom: device.videoZoomFactor, targetZoom: finalZoom,
                isRamping: device.isRampingVideoZoom, animated: animated, fastRamp: fastRamp) else {
                device.unlockForConfiguration()
                configurationStatus = "invalid_zoom"
                return
            }
            let zoomSpan = diagnostics.span("focal_zoom_apply", "focal_seq=\(focalSequence)")
            if let anchor = transition.anchorZoom { device.videoZoomFactor = anchor }
            if transition.usesRamp {
                device.ramp(toVideoZoomFactor: transition.targetZoom, withRate: transition.rate)
            } else {
                device.videoZoomFactor = transition.targetZoom
            }
            zoomSpan.end()
            let exposureSpan = diagnostics.span("focal_exposure_limit", "focal_seq=\(focalSequence)")
            let safeShutter = exposureDurationCap(focalMm: focalMm, format: device.activeFormat)
            device.activeMaxExposureDuration = safeShutter
            exposureSpan.end()
            device.unlockForConfiguration()
            diagnostics.event("focal_transition_plan", "focal_seq=\(focalSequence) anchor_zoom=\(transition.anchorZoom.map { String(format: "%.3f", Double($0)) } ?? "none") target_zoom=\(transition.targetZoom) rate=\(transition.rate) ramp=\(transition.usesRamp) policy=\(policyState)")
            diagnostics.event("focal_device_locked", "focal_seq=\(focalSequence) wait_ms=\(String(format: "%.2f", lockWaitMS))")
            diagnostics.event("focal_ramp_issued", "focal_seq=\(focalSequence) \(Self.deviceDiagnosticFields(device))")
            configurationStatus = "ok"
            let active = device.activePrimaryConstituent?.localizedName ?? "nil"
            Log.session.info("focal_applied option=\(focalMm)mm target_zoom=\(String(format: "%.2f", finalZoom))x active=\(active, privacy: .public) animated=\(animated)")
        } catch {
            Log.session.error("focal_apply_lock_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private func permitsFocalRequest(_ sequence: UInt64, generation: UInt64) -> Bool {
        latestFocalRequest.withLock { $0 == sequence } && sessionIntent.withLock { $0.permitsStart(generation) }
    }

    nonisolated private func focalRequestStamp() -> CameraLensCaptureGate.RequestStamp {
        CameraLensCaptureGate.RequestStamp(generation: diagnosticGeneration,
            focalSequence: latestFocalRequest.withLock { $0 })
    }

    // MARK: - 9. 拍照

    func capturePhoto(
        admission suppliedAdmission: CameraCaptureAdmission.Token? = nil,
        live: Bool = false,
        raw: Bool = false,
        expectedRAWFormat: CameraRAWFormat? = nil,
        previewFrame: CameraPreviewFrame? = nil,
        trace: DiagnosticTrace? = nil,
        onWillCapture: (() -> Void)? = nil,
        onExposureComplete: (() -> Void)? = nil,
        onShutterReady: @escaping () -> Void = {},
        onStillCaptured: (@MainActor (CaptureStill) async -> Void)? = nil,
        completion: @escaping (CaptureResult?) -> Void
    ) {
        let captureTrace = trace ?? DiagnosticTrace()
        let rawFormat = raw ? CameraRAWCapturePolicy.format(output: photoOutput, zoom: videoCaptureDevice?.videoZoomFactor ?? 0) : nil
        guard !raw || (rawFormat != nil && !live && (expectedRAWFormat == nil || expectedRAWFormat == rawFormat)) else {
            if let suppliedAdmission { cancelCaptureAdmission(suppliedAdmission) }
            updateRAWCaptureState()
            captureTrace.event("raw_capture_unavailable")
            onShutterReady()
            completion(nil)
            return
        }
        // A requested Live Photo must not silently turn into a still when capability is lost.
        guard !live || LivePhotoCaptureState(photoOutput).canCapture else {
            if let suppliedAdmission { cancelCaptureAdmission(suppliedAdmission) }
            updateLivePhotoCaptureState(reason: "capture_guard")
            captureTrace.event("live_photo_request_unavailable", "supported=\(photoOutput.isLivePhotoCaptureSupported) enabled=\(photoOutput.isLivePhotoCaptureEnabled)")
            onShutterReady()
            completion(nil)
            return
        }
        guard let admission = suppliedAdmission ?? beginCaptureAdmission(),
              isCaptureAdmissionValid(admission) else {
            if let suppliedAdmission { cancelCaptureAdmission(suppliedAdmission) }
            onShutterReady()
            completion(nil)
            return
        }
        if let previewFrame {
            guard previewFrame.generation == admission.sessionGeneration,
                  previewFrame.focalSequence == admission.focalSequence,
                  previewFrame.sourceRevision == lensSourceStability.withLock({ $0.revision }) else {
                cancelCaptureAdmission(admission)
                captureTrace.event("capture_skip", "reason=preview_source_changed")
                onShutterReady()
                completion(nil)
                return
            }
        }
        guard captureAdmission.withLock({ $0.beginPreparation(admission, generation: admission.sessionGeneration) }) else {
            onShutterReady()
            completion(nil)
            return
        }
        let wantsLive = live
        let request = CaptureRequest(
            admission: admission,
            trace: captureTrace,
            onData: completion,
            onShutterReady: onShutterReady,
            onStillCaptured: onStillCaptured,
            onWillCapture: onWillCapture,
            onExposureComplete: onExposureComplete,
            expectsLiveMovie: wantsLive,
            rawFormat: rawFormat,
            previewSourceRevision: previewFrame?.sourceRevision
        )

        // 唯一闸门：await 直到 isReadyToCapture（根本可用 + 镜头到位 + ZSL grace）再 issue 给 AVF。
        // 取代旧的 isLensTransitioning + waitForLensSettled + waitForConstituentMatch 三段分散判定——
        // 三者现在都收敛进 isReadyToCapture 这一处谓词。修的根因：ZSL ring 里上一颗 constituent /
        // 过冲 zoom 的旧帧被选作出片源 → 用户选 35mm / 100mm 拍出的照片元数据/视野是错的镜头/焦段。
        // waitForReadyToCapture 内有 4s 兜底，不会让快门永久卡住。
        captureGeneration &+= 1
        let generation = captureGeneration
        capturePreparationTask = Task { @MainActor [weak self] in
            guard let self else { request.onShutterReady(); request.onData(nil); return }
            defer {
                if self.captureGeneration == generation {
                    self.capturePreparationTask = nil
                    self.updateCaptureControls()
                }
            }
            let waiting = request.trace.span("capture_ready_wait")
            let ready = await self.waitForReadyToCapture()
            waiting.end(ready ? "ok" : "not_ready")
            let exposureReady = ready ? await self.waitForExposureApplication() : false
            guard exposureReady, self.isCaptureAdmissionValid(admission) else {
                self.cancelCaptureAdmission(admission)
                request.onShutterReady(); request.onData(nil); return
            }
            await self.issueCapturePhoto(request)
        }
    }

    /// capturePhoto 主体——拆出来是为了让外层 capturePhoto 能 await waitForReadyToCapture。
    /// 必须 @MainActor：访问 photoOutput / videoCaptureDevice / inFlightCaptures / flashMode。
    /// Native flash metering remains owned by AVFoundation.
    private func issueCapturePhoto(_ request: CaptureRequest) async {
        var request = request
        guard !Task.isCancelled, isCaptureAdmissionValid(request.admission) else {
            cancelCaptureAdmission(request.admission)
            request.onShutterReady()
            request.onData(nil)
            return
        }
        guard !request.expectsLiveMovie || LivePhotoCaptureState(photoOutput).canCapture else {
            updateLivePhotoCaptureState(reason: "capture_issue_guard")
            request.trace.event("live_photo_request_unavailable", "stage=issue supported=\(photoOutput.isLivePhotoCaptureSupported) enabled=\(photoOutput.isLivePhotoCaptureEnabled)")
            cancelCaptureAdmission(request.admission)
            request.onShutterReady()
            request.onData(nil)
            return
        }
        request.trace.event("capture_issue", "camera=\(diagnostics.id)")
        // 防御性兜底：waitForReadyToCapture 返回 ready 到这里之间仍隔着调度边界，其间 session 可能被
        // 切后台 / stopSession 拆掉 connection。无 active connection 时 photoOutput.capturePhoto 会抛
        // NSException 崩溃——这里改为优雅终结：放开快门 + 以 nil 释放后处理槽位。
        guard photoOutput.connection(with: .video)?.isActive == true else {
            Log.capture.error("capture_skip reason=no_active_connection")
            cancelCaptureAdmission(request.admission)
            request.onShutterReady()
            request.onData(nil)
            return
        }
        // Prefer HEIF when supported, with JPEG as the system fallback.
        let settings: AVCapturePhotoSettings
        if let rawFormat = request.rawFormat {
            guard rawFormat == CameraRAWCapturePolicy.format(output: photoOutput, zoom: videoCaptureDevice?.videoZoomFactor ?? 0) else {
                updateRAWCaptureState()
                cancelCaptureAdmission(request.admission)
                request.onShutterReady(); request.onData(nil)
                return
            }
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat.pixelFormat, processedFormat: nil)
        } else if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        // Per-capture settings must explicitly use the ordinary dimensions selected for this
        // output; AVFoundation may still deliver a different final size for the current scene.
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        // Prioritize image quality, bounded by the output capability.
        settings.photoQualityPrioritization = CameraCapturePolicy.current.qualityPrioritization(supportedMax: photoOutput.maxPhotoQualityPrioritization)
        if request.rawFormat?.kind == .bayerRAW { settings.photoQualityPrioritization = .speed }

        if let device = videoCaptureDevice, device.hasFlash {
            settings.flashMode = request.admission.flashEnabled ? .on : .off
        }

        settings.embedsDepthDataInPhoto = false
        settings.embedsPortraitEffectsMatteInPhoto = false
        settings.embedsSemanticSegmentationMattesInPhoto = false

        // Live Photo：本次拍照要求动态视频时，给 settings 挂一个唯一临时 .mov 路径。
        // **不要**自己写 content identifier——AVCapture 会自动生成并写进静态图与视频原始字节，
        // 通过 livePhotoMovieMetadata 指定它会直接抛 NSInvalidArgumentException 崩溃。配对 id 由后处理
        // 阶段从原始视频读出后，统一写进重编码的视频与静态图（见 LivePhotoProcessor / CameraView）。
        // 视频在 didFinishProcessingLivePhotoToMovieFileAt 回调里到达（约 shutter 后 ~1.5s，因为 Live
        // 视频是 shutter 前后各 ~1.5s 的环形缓冲）。
        let wantsLive = request.expectsLiveMovie
        if wantsLive {
            let movieURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("livephoto_src_\(UUID().uuidString).mov")
            settings.livePhotoMovieFileURL = movieURL
            request.pendingMovieURL = movieURL
        }

        // 闪光灯下恒定色彩（Constant Color）减少白平衡偏移。Live Photo 与 Constant Color（内部走
        // bracketed capture）不兼容——live 时跳过，避免 AVF 拒绝 settings。
        if request.rawFormat == nil, photoOutput.isConstantColorSupported, request.admission.flashEnabled, !wantsLive {
            settings.isConstantColorEnabled = true
        }

        // 抓取当前 rotation 角度（避免在 sessionQueue 跨 actor 访问）。
        // 出片随物理朝向：横握出横片、竖握出竖片，与 iPhone 系统相机一致。
        // 见 applyVideoOrientationToOutputs 的"预览/出片解耦"说明。
        let rotationAngle = request.admission.rotationAngle.map { CGFloat($0) }
        let output = photoOutput
        let delegate = self

        // 登记进 inFlightCaptures：以 settings.uniqueID 为键，delegate 回调按 resolvedSettings.uniqueID
        // 找回本 request。必须在 dispatch capturePhoto **之前**登记，否则 willCapture/didFinishProcessing
        // 可能先于登记到达而丢失。
        inFlightCaptures[settings.uniqueID] = request
        let nativeTraceID = settings.uniqueID
        let nativeTrace = request.trace
        captureTraces.withLock { $0[nativeTraceID] = nativeTrace }
        request.trace.event("capture_registered", "av_id=\(settings.uniqueID) live=\(wantsLive)")
        request.trace.event("capture_input_format", "format=\(request.rawFormat?.kind.rawValue ?? "processed")")
        request.trace.event("capture_configuration", "camera=\(diagnostics.id) focal_seq=\(request.admission.focalSequence) focal_mm=\(request.admission.focalLength) flash=\(request.admission.flashEnabled ? "on" : "off") live=\(wantsLive) prioritization=\(settings.photoQualityPrioritization.rawValue) max_prioritization=\(photoOutput.maxPhotoQualityPrioritization.rawValue) photo=\(settings.maxPhotoDimensions.width)x\(settings.maxPhotoDimensions.height)")
        let watchedID = settings.uniqueID
        captureWatchdogs[watchedID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(request.rawFormat == nil ? 15 : 30)) } catch { return }
            Log.capture.error("capture_delivery_timeout id=\(watchedID)")
            self?.deliverCaptureIfReady(id: watchedID, terminal: true)
        }
        if Task.isCancelled || !isCaptureAdmissionValid(request.admission) {
            deliverCaptureIfReady(id: watchedID, terminal: true)
            return
        }

        // 调度到 sessionQueue：AVCapturePhotoOutput 操作不占用主线程，快门响应更快
        let reqDims = settings.maxPhotoDimensions
        // 安全快门可观测性：抓 device 的 activeMaxExposureDuration（我们设的 cap）和 exposureDuration
        // (AE 当前一帧的实际曝光时间)。两者对比能一眼看出 cap 是否在咬：
        //   live=cap → AE 顶到上限了（低光场景）
        //   live<cap → 光线足够，AE 自由调，cap 没起作用
        let snapshotDevice = videoCaptureDevice
        let snapshotFocalInfo = focalInfo
        let snapshotAdmission = request.admission
        let snapshotTrace = request.trace
        sessionQueue.async { [self] in
            // Verbose hardware reads and formatting must not hold up shutter feedback on MainActor.
            snapshotTrace.event("capture_device_snapshot", "main_thread=\(Thread.isMainThread) \(snapshotDevice.map(Self.deviceDiagnosticFields) ?? "device=none")")
            let capStr = formatExposureCMTime(snapshotDevice?.activeMaxExposureDuration)
            let liveStr = formatExposureCMTime(snapshotDevice?.exposureDuration)
            Log.capture.info("capture_dispatch flash=\(snapshotAdmission.flashEnabled ? "on" : "off", privacy: .public) rotation=\(rotationAngle.map { "\(Int($0))°" } ?? "nil", privacy: .public) max_dims=\(reqDims.width)x\(reqDims.height) safe_shutter=\(capStr, privacy: .public) live_exposure=\(liveStr, privacy: .public)")
            let activeLens = snapshotDevice?.activePrimaryConstituent
            let lensName = activeLens?.localizedName ?? "nil"
            let lensNativeMm = activeLens?.nominalFocalLengthIn35mmFilm ?? 0
            let liveZoom = snapshotDevice?.videoZoomFactor ?? 0
            let equivSet = snapshotAdmission.focalLength
            let equivLive = snapshotFocalInfo.equivalentMm(forZoom: liveZoom, activeConstituent: activeLens)
            let digiCrop = lensNativeMm > 0 ? Float(equivSet) / lensNativeMm : 0
            Log.capture.info("capture_focal equiv_set=\(equivSet)mm equiv_live=\(String(format: "%.1f", equivLive))mm lens=\(lensName, privacy: .public)/\(String(format: "%.0f", lensNativeMm))mm zoom=\(String(format: "%.2f", liveZoom))x digi_crop=\(String(format: "%.2f", digiCrop))x")
        }
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        let invocation = NativeCaptureInvocation(output: output, settings: settings,
            admission: request.admission, trace: request.trace, rotationAngle: rotationAngle,
            expectsLiveMovie: wantsLive, rawFormat: request.rawFormat,
            previewSourceRevision: request.previewSourceRevision, enqueuedAt: enqueuedAt, deadline: enqueuedAt + 4)
        sessionQueue.async { delegate.invokeCapturePhoto(invocation) }
    }

    /// Runs only on the hardware queue. Source KVO updates the native grace synchronously,
    /// so an already-prepared capture cannot outrun its main-actor source-change callback.
    nonisolated private func invokeCapturePhoto(_ invocation: NativeCaptureInvocation) {
        let admission = invocation.admission
        let id = invocation.settings.uniqueID
        func finish() {
            Task { @MainActor in self.deliverCaptureIfReady(id: id, terminal: true) }
        }
        guard permitsFocalRequest(admission.focalSequence, generation: admission.sessionGeneration),
              captureAdmission.withLock({ $0.permits(admission, generation: admission.sessionGeneration) }) else {
            invocation.trace.event("capture_skip", "reason=admission_cancelled")
            finish()
            return
        }
        guard invocation.output.connection(with: .video)?.isActive == true else {
            invocation.trace.event("capture_skip", "reason=connection_inactive_at_invoke")
            finish()
            return
        }
        if let rawFormat = invocation.rawFormat {
            let device = invocation.output.connection(with: .video)?.inputPorts.first?.input as? AVCaptureDeviceInput
            guard rawFormat == CameraRAWCapturePolicy.format(output: invocation.output, zoom: device?.device.videoZoomFactor ?? 0) else {
                invocation.trace.event("capture_skip", "reason=raw_capability_changed")
                finish()
                return
            }
        }
        guard !invocation.expectsLiveMovie || LivePhotoCaptureState(invocation.output).canCapture else {
            invocation.trace.event("live_photo_request_unavailable", "stage=invoke")
            Task { @MainActor in
                self.updateLivePhotoCaptureState(reason: "capture_invoke_guard")
                self.deliverCaptureIfReady(id: id, terminal: true)
            }
            return
        }
        let stamp = CameraLensCaptureGate.RequestStamp(generation: admission.sessionGeneration,
            focalSequence: admission.focalSequence)
        let now = ProcessInfo.processInfo.systemUptime
        if let revision = invocation.previewSourceRevision,
           lensSourceStability.withLock({ $0.revision != revision }) {
            invocation.trace.event("capture_skip", "reason=preview_source_changed")
            finish()
            return
        }
        let sourceWait = lensSourceStability.withLock { $0.remainingGrace(stamp: stamp, at: now) }
        if sourceWait > 0 || invocation.output.captureReadiness != .ready || !exposureApplication.withLock({ $0.isReady }) {
            guard now < invocation.deadline else {
                invocation.trace.event("capture_skip", "reason=native_readiness_timeout")
                finish()
                return
            }
            let delay = max(0.015, sourceWait)
            invocation.trace.event("capture_native_wait", "reason=source_or_output_readiness wait_ms=\(Int(delay * 1_000))")
            Self.hardwareQueue.asyncAfter(deadline: .now() + delay) { self.invokeCapturePhoto(invocation) }
            return
        }
        if let angle = invocation.rotationAngle,
           let connection = invocation.output.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        // Lock ordering is lifecycle -> source -> admission. A pause or source change before
        // this commit keeps the request unissued and eligible for cancellation/retry.
        let committed = sessionIntent.withLock { intent in
            intent.permitsStart(admission.sessionGeneration) && lensSourceStability.withLock { source in
                source.remainingGrace(stamp: stamp, at: ProcessInfo.processInfo.systemUptime) == 0 &&
                    (invocation.previewSourceRevision == nil || invocation.previewSourceRevision == source.revision) &&
                    captureAdmission.withLock { $0.markIssued(admission, generation: admission.sessionGeneration) }
            }
        }
        guard committed else {
            if ProcessInfo.processInfo.systemUptime < invocation.deadline,
               permitsFocalRequest(admission.focalSequence, generation: admission.sessionGeneration),
               captureAdmission.withLock({ $0.permits(admission, generation: admission.sessionGeneration) }) {
                Self.hardwareQueue.asyncAfter(deadline: .now() + 0.015) { self.invokeCapturePhoto(invocation) }
            } else { finish() }
            return
        }
        invocation.trace.event("capture_invoke", "av_id=\(id) hardware_wait_ms=\(Diagnostics.milliseconds(since: invocation.enqueuedAt))")
        invocation.output.capturePhoto(with: invocation.settings, delegate: self)
    }

    // MARK: - 10. 后台 / 前台 / 停止

    /// 进入后台时调用：停止 capture session 释放摄像头硬件，但**保留** observers / KVO /
    /// rotationCoordinator / videoInput 的配置——回前台时 resumeSessionIfPossible 只需 startRunning,
    /// 不需要重新走整套 configureAndStartSession（节省 ~150ms 启动延迟 + 避免触发权限/format 重选）。
    /// 同时清空 stale pixel buffer，避免回前台瞬间 MTKView 显示老画面。
    func pauseSessionForBackground() {
        flowDiagnostics.flush(reason: "camera_pause", force: true)
        diagnostics.event("camera_pause_requested")
        sessionIntent.withLock { _ = $0.request(running: false) }
        cancelEntryPreparation()
        cancelUnexposedCapture()
        startupTask?.cancel()
        lensSettleTask?.cancel()
        lensSettleTask = nil
        lensSettleDeadline = nil
        stopLocationServices()
        beginCameraPreparation()
        let captureSession = session
        let pause = diagnostics.span("session_pause")
        sessionQueue.async {
            defer { pause.end() }
            let timer = Log.perf("session_pause", logger: Log.session)
            if captureSession.isRunning { captureSession.stopRunning() }
            if Self.audioInput(in: captureSession) != nil { Self.configureMixAudioSession(active: false) }
            timer.end()
        }
    }

    func resumeSessionIfPossible() {
        diagnostics.event("camera_resume_requested", "visible=\(isCameraVisible) interrupted=\(sessionInterrupted)")
        guard isCameraVisible, !sessionInterrupted,
              UIApplication.shared.applicationState != .background else { return }
        guard sessionConfigured else { requestCameraPermission(); return }
        let pendingFocal = lensCaptureGate.isTransitioning ? currentFocalLength : nil
        lensSettleTask?.cancel()
        lensSettleTask = nil
        let token = sessionIntent.withLock { $0.request(running: true) }
        beginEntryPreparation(generation: token)
        let intent = sessionIntent
        beginCameraPreparation()
        let captureSession = session
        let resume = diagnostics.span("session_resume")
        sessionQueue.async { [weak self] in
            defer { resume.end() }
            guard intent.withLock({ $0.permitsStart(token) }) else { return }
            let timer = Log.perf("session_resume", logger: Log.session)
            if Self.audioInput(in: captureSession) != nil { Self.configureMixAudioSession(active: true) }
            if !captureSession.isRunning { captureSession.startRunning() }
            let running = captureSession.isRunning
            timer.end()
            let completedAt = ProcessInfo.processInfo.systemUptime
            let manager = self
            Task { @MainActor in
                guard let self = manager, self.sessionConfigured,
                      intent.withLock({ $0.permitsStart(token) }) else { return }
                self.entryDeviceConfigurationFinished(generation: token,
                    completedAt: completedAt, status: running ? "resumed" : "resume_failed")
                self.setReadiness(running ? .waitingForFirstFrame : .failed)
                if running, let pendingFocal {
                    // A hardware callback from the previous generation is deliberately ignored.
                    // Reissue the pending selection instead of leaving its acknowledgement gate closed.
                    self.applyFocalLength(pendingFocal, animated: false)
                } else if running, !self.lensCaptureGate.hasFailed, let device = self.videoCaptureDevice {
                    self.beginLensSwitch(zoom: self.lensCaptureGate.targetZoom ?? device.videoZoomFactor,
                        zslGraceMs: 150, maxWaitMs: 1200)
                }
                self.promoteReadinessIfPossible()
                self.reconcileAudioInput()
                if running { self.prepareForFirstCapture() }
                self.startLocationServices()
            }
        }
    }

    /// 停止 session 并释放相机资源（导航离开时调用，防止多 session 竞争）
    func stopSession() {
        flowDiagnostics.flush(reason: "camera_close", force: true)
        diagnostics.event("camera_close_requested")
        isCameraVisible = false
        sessionIntent.withLock { _ = $0.request(running: false) }
        cancelEntryPreparation()
        cancelUnexposedCapture()
        // 取消可能仍在 await configureAndStartSession 的启动任务,
        // 避免它在 sessionQueue 上把 startRunning 跑完后我们又得排队 stopRunning。
        startupTask?.cancel()
        startupTask = nil
        captureGeneration &+= 1
        capturePreparationTask?.cancel()
        capturePreparationTask = nil

        stopLocationServices()
        focusHoldTimer?.invalidate()
        focusHoldTimer = nil
        isEditingExposure = false
        exposureApplication.withLock { $0.reset() }
        // 及早失效所有 KVO，避免 session 停止期间仍有回调被派发到已释放的闭包
        lensSourceStability.withLock { _ = $0.invalidateObservations() }
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
        whiteBalanceReadingObservation?.invalidate()
        whiteBalanceReadingObservation = nil
        livePhotoSupportObservation?.invalidate()
        livePhotoSupportObservation = nil
        livePhotoEnabledObservation?.invalidate()
        livePhotoEnabledObservation = nil
        currentVideoInput = nil
        focalLengthPicker = nil
        exposureBiasSlider = nil
        exposureControlEpoch &+= 1
        rotationCoordinator = nil
        // 麦克风输入随 session 一并释放（最后的 sessionQueue 块停用音频会话）；下次入页由
        // reconcileAudioInput 按当时开关重新挂。
        livePhotoAudioDesired = false
        // 清空 buffer（避免 stopRunning 后 MTKView 还显示上次的 frame）
        pixelBufferLock.withLockUnchecked { $0.buffer = nil; $0.renderedFrame = nil }
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
        lensSettleTask?.cancel()
        lensSettleTask = nil
        lensSettleDeadline = nil
        lensCaptureGate.reset()
        lensSwitchFailed = false
        applyFocalToken &+= 1
        sessionConfigured = false
        usesDeferredPhotoDelivery = false
        photoDeliveryConfigurationPending = false
        photoDeliveryReconciliationPending = false
        sessionInterrupted = false
        hasReceivedPreviewFrame = false
        firstFrameFlag.withLock { $0 = false }
        setReadiness(.idle)
        // 停止加速度计读取（与 setupOrientationMonitoring 配对）
        stopAccelerometerOrientationUpdates()
        previewMTKView = nil

        // setSampleBufferDelegate(nil) 与 stopRunning() 都是阻塞调用——主线程同步执行
        // 会让左滑返回动画卡顿。整体下放到 sessionQueue。
        let captureSession = session
        let videoOutput = videoDataOutput
        let trace = diagnostics
        let stopQueuedAt = ProcessInfo.processInfo.systemUptime
        sessionQueue.async {
            trace.event("session_stop_dequeued", "wait_ms=\(Diagnostics.milliseconds(since: stopQueuedAt))")
            let stopping = trace.span("session_stop_release")
            let timer = Log.perf("session_stop_release", logger: Log.session)
            trace.measure("session_detach_delegate") { videoOutput.setSampleBufferDelegate(nil, queue: nil) }
            if captureSession.isRunning { trace.measure("session_stop_running") { captureSession.stopRunning() } }
            if Self.audioInput(in: captureSession) != nil { Self.configureMixAudioSession(active: false) }
            let release = trace.span("session_release_io")
            captureSession.beginConfiguration()
            for input in captureSession.inputs { captureSession.removeInput(input) }
            for output in captureSession.outputs { captureSession.removeOutput(output) }
            for control in captureSession.controls { captureSession.removeControl(control) }
            captureSession.commitConfiguration()
            release.end()
            timer.end()
            stopping.end()
        }

    }

    // MARK: - 12. 位置服务

    /// 获取缓存或当前位置（无阻塞等待，30s 缓存策略）
    func captureLocation(at date: Date) -> CLLocation? {
        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways,
              let location = currentLocation, CaptureLocation.isUsable(location, at: date) else { return nil }
        return location
    }

    private func startLocationServices() {
        guard isCameraVisible, sessionConfigured, sessionIntent.withLock({ $0.wantsRunning }) else { return }
        locationManager.delegate = self
        // 相片地标 ±100m 足够，`Best` 会触发系统更严格的隐私审查并增加功耗
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 20

        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            setLocationDenied(false)
            startLocationUpdates()
        case .notDetermined:
            // 请求授权后等待 delegate 回调 locationManagerDidChangeAuthorization 再启动
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            setLocationDenied(true)
        default:
            break
        }
    }

    private func startLocationUpdates() {
        guard isCameraVisible, sessionConfigured, sessionIntent.withLock({ $0.wantsRunning }) else { return }
        locationManager.startUpdatingLocation()
    }

    private func stopLocationServices() {
        locationManager.stopUpdatingLocation()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate（实时预览样本帧）
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String ?? "unknown"
        flowDiagnostics.captureDropped(reason: reason)
        let now = ProcessInfo.processInfo.systemUptime
        let report = pixelBufferLock.withLockUnchecked { state -> UInt64? in
            state.droppedFrames &+= 1
            state.lastDropReason = reason
            guard now - state.lastDropLogAt >= 2 else { return nil }
            state.lastDropLogAt = now
            return state.droppedFrames
        }
        if let count = report { diagnostics.event("preview_capture_drop", "count=\(count) reason=\(reason)") }
    }

    @preconcurrency nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sessionIntent.withLock({ $0.wantsRunning }),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        self.setLatestPixelBuffer(buffer)
        let framePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        flowDiagnostics.capture(at: ProcessInfo.processInfo.systemUptime, pts: framePTS,
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        // 扩展裁切上限的换轨点：帧流断裂（跨镜头切换停帧后的第一帧）处对齐 KVO 登记
        // 的新上限，保证裁切恰在新镜头内容上生效。KVO/帧内容错位即预览闪跳的根因。
        if let latch = cropCeilingSync.withLock({ $0.frameArrived(pts: framePTS, at: ProcessInfo.processInfo.systemUptime) }) {
            let ceilingText = latch.ceiling.isFinite ? String(format: "%.2f", latch.ceiling) : "unbounded"
            let gapText = latch.gapSeconds.map { String(format: "%.0f", $0 * 1_000) } ?? "first_frame"
            diagnostics.event("preview_stream_ceiling_latched",
                "ceiling=\(ceilingText) gap_ms=\(gapText) age_ms=\(String(format: "%.0f", latch.ageSeconds * 1_000))")
        }
        self.logFirstFrameOnce(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        // 不再 dispatch main 触发 setNeedsDisplay：MTKView 已切换到 CADisplayLink 驱动
        // （MetalPreview.swift），每个 vsync 调一次 draw(in:)，draw 内部按 frameId 去重。
        // 这里只负责把最新帧写入 lock 保护的 buffer，主队列零负担。
    }
}

// MARK: - AVCaptureSessionControlsDelegate（Camera Control 控件激活必需）
extension CameraManager: AVCaptureSessionControlsDelegate {
    nonisolated func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        diagnostics.event("camera_controls_active")
        Log.session.info("camera_controls_active")
    }
    nonisolated func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        diagnostics.event("camera_controls_fullscreen_enter")
    }
    nonisolated func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        diagnostics.event("camera_controls_fullscreen_exit")
    }
    nonisolated func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        diagnostics.event("camera_controls_inactive")
        Log.session.info("camera_controls_inactive")
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
        didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?, error: (any Error)?) {
        guard let proxy = deferredPhotoProxy else { return } // didFinishCaptureFor terminates a failed request.
        let id = proxy.resolvedSettings.uniqueID
        let trace = captureTraces.withLock { $0[id] }
        guard error == nil, let data = proxy.fileDataRepresentation() else {
            trace?.event("deferred_photo_proxy_failed")
            return
        }
        let dimensions = proxy.resolvedSettings.photoDimensions
        let deferred = DeferredPhotoState(width: Int(dimensions.width), height: Int(dimensions.height))
        trace?.event("deferred_photo_proxy_received", "bytes=\(data.count) final=\(dimensions.width)x\(dimensions.height)")
        DispatchQueue.main.async {
            guard let request = self.inFlightCaptures[id], request.rawFormat == nil,
                  !request.expectsLiveMovie, !request.stillArrived else { return }
            self.mutateCapture(id) {
                $0.stillData = data
                $0.deferredPhoto = deferred
                $0.stillArrived = true
            }
            self.deliverCaptureIfReady(id: id, terminal: false)
        }
    }

    /// AVF 主曝光即将开始——开闪光灯时这一刻就是氙气主脉冲发射的瞬间。
    /// Apple 文档明确指引这里做 shutter visual feedback（屏幕白屏 / 快门音）。
    /// UI 白屏挂在这里 → 与真实闪光灯物理同帧，告别"先白屏后亮灯"的脱钩感。
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Log.capture.info("delegate_will_capture")
        let id = resolvedSettings.uniqueID
        captureTraces.withLock { $0[id] }?.event("exposure_begin_native", "av_id=\(id)")
        DispatchQueue.main.async { self.inFlightCaptures[id]?.onWillCapture?() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Log.capture.info("delegate_did_capture dims=\(resolvedSettings.photoDimensions.width)x\(resolvedSettings.photoDimensions.height)")
        let id = resolvedSettings.uniqueID
        captureTraces.withLock { $0[id] }?.event("exposure_end_native", "av_id=\(id) resolved_photo=\(resolvedSettings.photoDimensions.width)x\(resolvedSettings.photoDimensions.height)")
        DispatchQueue.main.async { self.inFlightCaptures[id]?.onExposureComplete?() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let id = resolvedSettings(of: photo)
        let isRAW = photo.isRawPhoto
        let trace = captureTraces.withLock { $0[id] }
        trace?.event("photo_delegate_arrived", "av_id=\(id) error=\(error != nil)")
        if let error = error {
            Log.capture.error("delegate_process_error error=\(error.localizedDescription, privacy: .public)")
            // 静态图失败 = 无可保存内容，立即以终结方式释放（即便还等着 live 视频也不必再等）。
            DispatchQueue.main.async {
                guard let request = self.inFlightCaptures[id],
                      CameraRAWCapturePolicy.acceptsDelivery(expectsRAW: request.rawFormat != nil, isRAW: isRAW) else { return }
                self.mutateCapture(id) { $0.stillArrived = true }
                self.deliverCaptureIfReady(id: id, terminal: true)
            }
            return
        }
        let encoding = trace?.span("photo_file_data")
        guard let imageData = photo.fileDataRepresentation() else {
            encoding?.end("missing_data")
            Log.capture.error("delegate_process_no_data")
            DispatchQueue.main.async {
                guard let request = self.inFlightCaptures[id],
                      CameraRAWCapturePolicy.acceptsDelivery(expectsRAW: request.rawFormat != nil, isRAW: isRAW) else { return }
                self.mutateCapture(id) { $0.stillArrived = true }
                self.deliverCaptureIfReady(id: id, terminal: true)
            }
            return
        }
        encoding?.end("ok", "bytes=\(imageData.count)")
        trace?.event("native_photo_metadata", CameraPhotoDiagnostics.fields(imageData: imageData,
            resolvedDimensions: photo.resolvedSettings.photoDimensions))
        Log.capture.info("delegate_process_ok bytes=\(imageData.count)")

        // CIImage(data:) in applyLUTPreservingMetadata already applies EXIF orientation,
        // so we pass raw data directly — no need for a separate rotate+encode step.
        // 静态图到达：记下数据 + 标记到位，立即尝试交付。**非 live：onData 立即触发，启动后处理；
        // live：onShutterReady 在此触发放开快门，onData 等视频再触发**——deliverCaptureIfReady 内分流。
        DispatchQueue.main.async {
            guard let request = self.inFlightCaptures[id],
                  CameraRAWCapturePolicy.acceptsDelivery(expectsRAW: request.rawFormat != nil, isRAW: isRAW) else { return }
            self.mutateCapture(id) { $0.stillData = imageData; $0.stillArrived = true }
            self.deliverCaptureIfReady(id: id, terminal: false)
        }
    }

    /// Live Photo 动态视频录制结束（约 shutter 后 ~1.5s）——仅 log，文件尚未写完。
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL, resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Log.capture.info("delegate_live_recording_done")
    }

    /// Live Photo 动态视频文件写好——拿到 URL + photoDisplayTime（静态帧对应时刻）。
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        let id = resolvedSettings.uniqueID
        captureTraces.withLock { $0[id] }?.event("live_movie_arrived", "av_id=\(id) error=\(error != nil)")
        if let error = error {
            Log.capture.error("delegate_live_movie_error error=\(error.localizedDescription, privacy: .public)")
            // 视频失败：标记到位但 URL 为 nil → 交付时降级为「只存静态图」，绝不卡死。
            // AVF 失败时仍可能留下半截文件——就地删除（settings 里挂的路径只有这里知道）。
            try? FileManager.default.removeItem(at: outputFileURL)
            DispatchQueue.main.async {
                self.mutateCapture(id) { $0.movieArrived = true }
                self.deliverCaptureIfReady(id: id, terminal: false)
            }
            return
        }
        Log.capture.info("delegate_live_movie_ok dur=\(String(format: "%.2f", duration.seconds))s display=\(String(format: "%.2f", photoDisplayTime.seconds))s")
        DispatchQueue.main.async {
            // 本次拍摄已被终结交付（如静态图失败提前释放）——迟到的视频无人消费，删掉文件，
            // 否则 livephoto_src_*.mov（~2-6MB）会留在 tmp 直到下次启动清扫。
            guard self.inFlightCaptures[id] != nil else {
                try? FileManager.default.removeItem(at: outputFileURL)
                Log.capture.info("late_live_movie_discarded id=\(id)")
                return
            }
            self.mutateCapture(id) {
                $0.movieURL = outputFileURL
                $0.photoDisplayTime = photoDisplayTime
                $0.movieArrived = true
            }
            self.deliverCaptureIfReady(id: id, terminal: false)
        }
    }

    /// AVF 保证的"必然终结"回调——无论 capture 成功、失败、还是被系统中断（来电 / 切后台 /
    /// stopSession 撞期）都会最后调用一次，是 Apple 推荐的拍照清理挂载点。
    /// 正常路径下静态图（+live 视频）已 deliver 并把该 request 移出 inFlightCaptures，此处即为幂等
    /// 空操作；只有当某个交付物从未到达（capture 被 drop）时这里才真正兜底：以 terminal 强制交付当前
    /// 已有内容（或 nil）+ 放开快门 + 还原闪光灯 AE/WB，否则快门会永久卡死、设备 AE/WB 永久锁定。
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        if let error = error {
            Log.capture.error("delegate_finish_capture_error error=\(error.localizedDescription, privacy: .public)")
        }
        let id = resolvedSettings.uniqueID
        DispatchQueue.main.async { self.deliverCaptureIfReady(id: id, terminal: true) }
    }

    /// 从 AVCapturePhoto 取回它所属拍照的 uniqueID（didFinishProcessingPhoto 不直接给 resolvedSettings）。
    nonisolated private func resolvedSettings(of photo: AVCapturePhoto) -> Int64 {
        photo.resolvedSettings.uniqueID
    }

    /// 原地修改某个在途 request（不存在则 no-op）。仅 @MainActor。
    @MainActor
    private func mutateCapture(_ id: Int64, _ body: (inout CaptureRequest) -> Void) {
        guard var req = inFlightCaptures[id] else { return }
        body(&req)
        inFlightCaptures[id] = req
    }

    /// 拍照交付——幂等，按 uniqueID 定位。两个独立信号：
    ///   1. onShutterReady：静态图完成早期落盘（或终结）+ 闪光灯 AE/WB 已还原 → 立即放开快门。**不等 live 视频。**
    ///   2. onData：凑齐本次要求的交付物（非 live：静态图；live：静态图 + 动态视频）→ 启动后处理。
    /// 两者各只触发一次（shutterReleased / resultDelivered 幂等守卫）。一旦 onData 交付即把 request
    /// 移出 inFlightCaptures；多个 delegate 回调重入直接被守卫挡掉。
    /// - terminal: didFinishCaptureFor 兜底调用时为 true，强制交付（即便交付物未齐）。
    @MainActor
    private func deliverCaptureIfReady(id: Int64, terminal: Bool) {
        guard var req = inFlightCaptures[id] else { return }

        req.terminalReceived = req.terminalReceived || terminal
        if req.isCheckpointingStill { inFlightCaptures[id] = req; return }
        if !req.stillCheckpointed, let imageData = req.stillData, let checkpoint = req.onStillCaptured {
            req.isCheckpointingStill = true
            inFlightCaptures[id] = req
            let still = CaptureStill(imageData: imageData, pendingLivePhotoMovieURL: req.pendingMovieURL,
                deferredPhoto: req.deferredPhoto)
            Task { @MainActor [weak self] in
                await checkpoint(still)
                self?.mutateCapture(id) {
                    $0.isCheckpointingStill = false
                    $0.stillCheckpointed = true
                }
                self?.deliverCaptureIfReady(id: id, terminal: false)
            }
            return
        }

        // 放开快门：静态图就绪（或终结）即触发，只一次。这是把「快门可再按」从「完整交付」解耦的关键——
        // live 时静态图 ~300ms 就到，配对视频的 ~1.5s 录制窗口不再卡住下一张。
        if !req.shutterReleased, req.stillArrived || req.terminalReceived {
            req.shutterReleased = true
            let admission = req.admission
            captureAdmission.withLock { _ = $0.release(admission) }
            inFlightCaptures[id] = req
            updateCaptureControls()
            req.onShutterReady()
        }

        let movieReady = !req.expectsLiveMovie || req.movieArrived
        let canDeliver = req.terminalReceived || (req.stillArrived && movieReady)

        guard canDeliver else {
            inFlightCaptures[id] = req   // Keep the shutter-release flag across Live movie delivery
            return
        }

        req.trace.event("capture_delivered", "av_id=\(id) bytes=\(req.stillData?.count ?? 0) live=\(req.movieURL != nil) terminal=\(req.terminalReceived)")
        captureTraces.withLock { $0[id] = nil }
        inFlightCaptures[id] = nil
        captureWatchdogs.removeValue(forKey: id)?.cancel()
        if inFlightCaptures.isEmpty, audioReconciliationPending { reconcileAudioInput() }
        if inFlightCaptures.isEmpty, photoDeliveryReconciliationPending { reconcilePhotoDelivery() }
        guard !req.resultDelivered else { return }
        req.resultDelivered = true
        if let data = req.stillData {
            req.onData(CaptureResult(
                imageData: data,
                livePhotoMovieURL: req.movieURL,
                photoDisplayTime: req.photoDisplayTime,
                requestedLive: req.expectsLiveMovie,
                deferredPhoto: req.deferredPhoto
            ))
        } else {
            // 静态图缺失 = 整次拍摄作废，caller 拿到 nil 提前返回——已到达的 live 源视频
            // 不会随 result 传出去，必须在此就地删除，否则永久滞留 tmp。
            if let movie = req.movieURL {
                try? FileManager.default.removeItem(at: movie)
            }
            req.onData(nil)
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension CameraManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let location = locations.last {
                self.currentLocation = location
                Log.gps.debug("gps_update acc=\(String(format: "%.1f", location.horizontalAccuracy))m")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Log.gps.error("gps_fail error=\(error.localizedDescription, privacy: .public)")
    }

    // iOS 14 起 `didChangeAuthorization:` 已废弃；用现代回调，读 manager.authorizationStatus。
    // CLAuthorizationStatus 是 Sendable，先取标量再跳 @MainActor（与本类其它 KVO/delegate 一致）。
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            Log.gps.info("gps_auth_changed status=\(status.rawValue)")
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.setLocationDenied(false)
                self.startLocationUpdates()
            case .denied, .restricted:
                self.setLocationDenied(true)
                self.currentLocation = nil
                self.stopLocationServices()
            default:
                break
            }
        }
    }
}
