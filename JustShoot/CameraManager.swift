import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import CoreLocation
import CoreMotion
import UIKit
import MetalKit
import ImageIO
import os

// MARK: - 相机管理器
//
// 单文件 AVFoundation 编排：iOS 26 虚拟设备 (`builtInTripleCamera`) + `.auto` 跟随系统的镜头
// 切换 + ZSL × 镜头切换 race 闸门 + CMMotion 方向 + tap-to-focus + 距离感知闪光 + GPS 30s 缓存。
//
// 故意保留为单文件（~1,900 行）：以上每个面向都强耦合于同一 AVCaptureSession 状态机，跨文件
// 拆 extension 会迫使大部分 `private` 提升到 `internal`，反而损失封装性。Apple AVCam 等
// 官方 sample 的 CameraModel 也是单文件 700–800 行；本 app 因为多了一层胶片 LUT + 自定义
// 焦段策略稍长一些，但整体仍是一个内聚的状态机。
//
// 章节顺序（沿 capture 流程的自然走向）：
//   1. 存储属性 + init / deinit
//   2. 帧状态（pixel buffer / first frame）
//   3. 方向（CMMotion + RotationCoordinator KVO + EXIF orientation）
//   4. 对焦 / 曝光补偿
//   5. 闪光灯曝光补偿 + 锁/还原
//   6. 权限
//   7. Session 配置（format / dims / stabilization / 初始焦段 / KVO）
//   8. 镜头切换（.auto 跟随系统 + 安全快门）
//   9. 拍照（capturePhoto + issue）
//  10. 后台 / 前台 / 停止
//  11. 设备数据 dump（调试）
//  12. 位置服务
//  13. AVCapturePhotoCaptureDelegate / CLLocationManagerDelegate / 其它 delegate

/// 一次拍照的完整产出，跨 actor 边界传给 CameraView 的后处理。非 live 时只有 imageData，
/// 其余为 nil/invalid。live 时还带配对视频文件 URL + content identifier + still-image-time，
/// 供 LivePhotoProcessor 套 LUT 并重写配对元数据后存为 Live Photo。
struct CaptureResult: Sendable {
    let imageData: Data
    let livePhotoMovieURL: URL?
    let photoDisplayTime: CMTime
}

@MainActor
class CameraManager: NSObject, ObservableObject {

    // MARK: 1. 存储属性

    /// 虚拟设备 AVCaptureSession（iOS 26 推荐架构）：以 .builtInTripleCamera 等虚拟设备作为
    /// 单一 input；切焦距 = 始终 .auto + 把 videoZoomFactor ramp 到目标 — 系统在内部按 zoom 做
    /// 硬件级 constituent crossfade（能切长焦就切、近物/暗光裁主摄），预览不黑屏，无需 bridgeImage。
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    /// 当前 session 的虚拟（或物理）设备 input —— 整个生命周期只 add 一次，不 swap。
    private var currentVideoInput: AVCaptureDeviceInput?
    /// 当前 video 设备（虚拟或物理）。focus / exposure / zoom 都打在它身上；
    /// constituent 切换由系统在内部完成，对外仍是同一个 device 实例。
    private var videoCaptureDevice: AVCaptureDevice? { currentVideoInput?.device }
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let previewQueue = DispatchQueue(label: "preview.lut.queue")
    /// 专用会话队列（AVCaptureSession 操作必须在同一串行队列）
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")

    /// 线程安全的像素缓冲区（用 os_unfair_lock 保护跨线程访问）
    private struct PreviewState: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var frameId: UInt64 = 0
    }
    private let pixelBufferLock = OSAllocatedUnfairLock(initialState: PreviewState())

    /// 切焦距时用于丢弃过时回调的单调递增 token（用户快速来回点档位时旧任务不会把
    /// 新档位的 lock 撤掉）。
    private var applyFocalToken: UInt64 = 0
    /// 镜头切换的稳定轮询 task：beginLensSwitch 启动，每 ~30ms evaluateLensSettle 一次，直到
    /// 镜头到位 + grace 走完（clearLensTarget），或 maxWait 兜底超时。新一次 beginLensSwitch 取消旧的。
    private var lensSettleTask: Task<Void, Never>?

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
    /// exposureCompleteHandler / willCaptureHandler / pendingFlashRestore 四个分散 optional。
    /// capturePhoto 入口创建、issueCapturePhoto 按 settings.uniqueID 登记进 inFlightCaptures，
    /// deliverCaptureIfReady 消费。每个 closure 只被对应 delegate 触发一次（AVF 保证每个 delegate
    /// 每次 capture 调一次）。
    ///   - onData          : 完整交付（非 live：静态图；live：静态图 + 配对视频）就绪后回调恰好一次
    ///                       （nil = 失败/中断）。**这是后处理的启动信号，不是快门放开信号。**
    ///   - onShutterReady  : 静态图就绪 + 闪光灯 AE/WB 已还原时回调恰好一次——CameraView 据此放开
    ///                       快门让用户拍下一张。**与 onData 解耦**：live 时静态图 ~300ms 就到，而
    ///                       配对视频要等 ~1.5s 环形缓冲；快门只需等前者，视频交给后台后处理。
    ///   - onWillCapture   : 主曝光起始帧——屏幕白屏挂载点（与氙气主脉冲同帧）。
    ///   - onExposureComplete: 曝光物理完成（仅诊断）。
    ///   - flashRestore    : 开闪光时 issue 阶段锁的 AE/WB，capture 终结时还原。随单次拍照走，
    ///                       结构上不可能跨拍照互相覆盖（旧 pendingFlashRestore 共享字段会）。
    private struct CaptureRequest {
        let onData: (CaptureResult?) -> Void
        let onShutterReady: () -> Void
        let onWillCapture: (() -> Void)?
        let onExposureComplete: (() -> Void)?
        var flashRestore: FlashRestoreState?
        /// 本次拍照是否要求 Live Photo（issue 阶段已设 livePhotoMovieFileURL）。true 时 onData 要等
        /// 静态图 + 动态视频两个交付物都到齐（或 didFinishCaptureFor 终结兜底）才回调一次。
        let expectsLiveMovie: Bool
        // —— 两个异步交付物的累积状态（仅 @MainActor 读写）——
        var stillArrived = false
        var stillData: Data?
        var movieArrived = false
        var movieURL: URL?
        var photoDisplayTime: CMTime = .invalid
        /// onShutterReady / onData 各自只触发一次的幂等守卫（多个 delegate 回调会重入 deliver）。
        var shutterReleased = false
        var resultDelivered = false
    }
    /// 在途拍照按 `settings.uniqueID` 分桶——取代旧的单槽 `inFlightCapture?`。分桶后多张拍照可重叠：
    /// 静态图就绪即放开快门，上一张还在等 ~1.5s 配对视频时用户已能按下一张，新旧 capture 各自独立、
    /// 互不覆盖。delegate 回调用 `resolvedSettings.uniqueID` 精确定位到对应 request。
    private var inFlightCaptures: [Int64: CaptureRequest] = [:]
    @Published var flashMode: FlashMode = .off
    /// photoOutput 是否支持 Live Photo。UI 据此显示/隐藏顶栏 Live 开关。
    /// **默认 true**：本 app 目标 iOS 26 设备普遍支持 Live Photo，乐观默认让按钮一开始就显示，
    /// 避免「等 session 配置完才弹出来」的迟显。session 配置完成后由 configureAndStartSession 回填
    /// 真实值（支持设备保持 true，无可见变化；极少数不支持的设备才会隐藏）。真正拍 Live 仍由
    /// 拍摄时 photoOutput.isLivePhotoCaptureEnabled 把关，提前显示是安全的。
    @Published var isLivePhotoSupported: Bool = true

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
    private struct LensTarget {
        let zoom: CGFloat                  // 期望的最终 videoZoomFactor（取景）
        let zslGraceMs: Int                // zoom 到位后给系统 constituent crossfade 收尾的额外等待
    }
    private var lensTarget: LensTarget?
    /// 设备首次满足 lensIsOnTarget() 的时刻。用于判断 ZSL grace 是否走完；设备回退（重新 ramp）时清空。
    private var lensOnTargetSince: CFAbsoluteTime?
    private var zoomObservation: NSKeyValueObservation?
    private var constituentObservation: NSKeyValueObservation?
    private var focalLengthPicker: AVCaptureIndexPicker?
    /// 系统级 EV 滑块（iOS 18+）。虚拟设备架构下 device 实例不变，整生命周期内只装一次。
    private var exposureBiasSlider: AVCaptureSystemExposureBiasSlider?

    // 位置管理器
    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var locationCache: CLLocation?
    private var locationCacheTime: Date = .distantPast
    private let locationCacheExpiry: TimeInterval = 30.0

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
    /// 系统中断仍在进行中（来电/控制中心/录屏），interruptionEnded 后 resume
    private var sessionInterrupted: Bool = false

    // 权限状态
    @Published var cameraPermissionDenied: Bool = false
    /// 定位权限被拒绝或受限时，UI 显示「位置已关闭」提示
    @Published var locationPermissionDenied: Bool = false

    // 闪光灯 AE/WB 还原状态。现在内联在 CaptureRequest.flashRestore 里随单次拍照生命周期走，
    // 不再是 CameraManager 上的共享字段——每次拍照各自持有，结构上不可能跨拍照互相覆盖
    // （旧实现连按两次闪光快门时第二次 lock 会覆盖第一次的还原值，导致 AE 永久跑偏）。
    // didFinishCaptureFor 这个 AVF 保证的终结回调确保 flashRestore 必被消费恰好一次。
    private struct FlashRestoreState {
        let exposureTargetBias: Float
        let wbMode: AVCaptureDevice.WhiteBalanceMode
        let lockedExposure: Bool
        let lockedWB: Bool
    }
    private var focusHoldTimer: Timer?
    private let tapFocusHoldDuration: TimeInterval = 3.0
    private var focusObservation: NSKeyValueObservation?
    private var pressureObservation: NSKeyValueObservation?
    /// 进入相机时启动 session 的任务句柄；离开时取消，避免在 sessionQueue 上做完整 startRunning 后又被立即停止
    private var startupTask: Task<Void, Never>?
    /// 正常情况下的目标帧率；由 sessionQueue 写入、压力回调 KVO 读取，用锁保护避免数据竞争
    private let nominalFPSLock = OSAllocatedUnfairLock<Double>(initialState: 30.0)
    @Published var isFocusLocked = false
    /// 用户曝光补偿（EV）。tap-to-focus 后上下滑动手势驱动；focus 释放（timer / subject-area）时归零。
    /// 与 device.exposureTargetBias 镜像同步——后者在 flash capture 路径里会被临时改写，但 capture
    /// 完成后会通过 CaptureRequest.flashRestore 恢复，对外表现仍等于这里。
    @Published var exposureBias: Float = 0

    /// 虚拟（或物理）设备 — 整个生命周期固定，不 swap。constituent 由系统在 `.auto` 下按 zoom
    /// 在内部切换。session 配置完成前为 nil。
    private var captureDevice: AVCaptureDevice?

    /// AVF 对象 + main-actor 状态打包后跨 actor 边界传递。
    /// 这些 NSObject 在 dumpLensSpecsImpl 里只读 nonisolated 属性，与主 actor 写入无并发；
    /// `@unchecked Sendable` 表达"语义上 Sendable，但编译器无法证明"。
    private struct LensDumpArgs: @unchecked Sendable {
        let device: AVCaptureDevice
        let focalInfo: DeviceFocalInfo
        let photoOutput: AVCapturePhotoOutput
        let videoDataOutput: AVCaptureVideoDataOutput
    }

    // MARK: - init / deinit / 设备发现

    override init() {
        super.init()
        let device = Self.discoverBestCaptureDevice()
        captureDevice = device
        let constituents = device?.constituentDevices.map(\.localizedName).joined(separator: "+") ?? "none"
        Log.session.info("camera_device_discovered device=\(device?.localizedName ?? "nil", privacy: .public) type=\(device?.deviceType.rawValue ?? "nil", privacy: .public) constituents=[\(constituents, privacy: .public)]")
        setupOrientationMonitoring()
    }

    /// 按 iOS 26 推荐顺序选取后置 capture device。优先虚拟设备：让系统在 `.auto` 下按 videoZoomFactor
    /// 在内部完成 constituent 切换（硬件级 crossfade，无黑屏，能切长焦就切、近物/暗光裁主摄）。
    /// 优先级：triple（UW+W+T）→ dual（W+T）→ dualWide（UW+W）→ 单 wide 兜底。
    private static func discoverBestCaptureDevice() -> AVCaptureDevice? {
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
        // @MainActor class 的 deinit 在 Swift 6 中是 nonisolated，无法访问 @MainActor 隔离的属性。
        // observer / KVO 的生命周期已由 stopSession() 在 onDisappear 时托管。
        // 注意：stopRunning() 虽然线程安全，但是**阻塞调用**（Apple 文档：don't call on main thread）。
        // SwiftUI 释放 @StateObject 时 deinit 通常运行在主线程，若同步调用会阻塞导航返回动画。
        // 因此这里只做异步兜底；真正的停止已由 onDisappear → stopSession() 在 sessionQueue 处理。
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    // MARK: - 2. 帧状态（线程安全的 pixelBuffer / first frame）

    /// 获取最新帧（用于 MTKView 渲染）。`nonisolated` 让 Metal 渲染线程直接读，不绕主 actor。
    nonisolated func getLatestFrame() -> (CVPixelBuffer, UInt64)? {
        pixelBufferLock.withLockUnchecked { state in
            guard let buf = state.buffer else { return nil }
            return (buf, state.frameId)
        }
    }

    nonisolated func setLatestPixelBuffer(_ buffer: CVPixelBuffer) {
        pixelBufferLock.withLockUnchecked {
            $0.buffer = buffer
            $0.frameId &+= 1
        }
    }

    nonisolated func logFirstFrameOnce(width: Int, height: Int) {
        let shouldLog = firstFrameFlag.withLock { flagged -> Bool in
            guard !flagged else { return false }
            flagged = true
            return true
        }
        if shouldLog {
            Log.session.info("preview_first_frame w=\(width) h=\(height)")
        }
    }

    /// 仅在值真正变化时写入 @Published 属性，避免无意义的 objectWillChange 发布
    private func setCameraDenied(_ denied: Bool) {
        if cameraPermissionDenied != denied { cameraPermissionDenied = denied }
    }
    private func setLocationDenied(_ denied: Bool) {
        if locationPermissionDenied != denied { locationPermissionDenied = denied }
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

    private func exifOrientationFromRotationAngle(_ rotationAngle: CGFloat) -> Int {
        let normalizedAngle = Int(rotationAngle) % 360
        switch normalizedAngle {
        case 0: return 1
        case 90, -270: return 6
        case 180, -180: return 3
        case 270, -90: return 8
        default: return 1
        }
    }

    private func orientationFromRotationAngle(_ rotationAngle: CGFloat) -> CGImagePropertyOrientation {
        let normalizedAngle = Int(rotationAngle) % 360
        switch normalizedAngle {
        case 0: return .up
        case 90, -270: return .right
        case 180, -180: return .down
        case 270, -90: return .left
        default: return .up
        }
    }

    // MARK: - 4. 对焦 / 曝光补偿

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
    /// 通过 CaptureRequest.flashRestore 还原到本方法写入的值。所以即使在 capture 之间多次拖动也是安全的——
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
    private func onFocusCompleted() {
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

    // MARK: - 5. 闪光灯曝光补偿 + 锁/还原

    private func calculateFlashExposureBias(device: AVCaptureDevice) -> Float {
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
    private func applyFlashRestore(_ state: FlashRestoreState, device: AVCaptureDevice) {
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

    // MARK: - 6. 权限

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

    // MARK: - 7. Session 配置

    /// 在专用串行队列上配置并启动 AVCaptureSession。虚拟设备模式（iOS 26 推荐）：
    /// 单 input（如 .builtInTripleCamera），constituent 切换由系统在内部完成，不再需要 swap。
    private func configureAndStartSession() async {
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
                    // 关键：在 startRunning 之前把 videoZoomFactor 设到目标焦段，让 ZSL ring 一开始就
                    // 只收正确 constituent 的帧——见 setInitialFocalLength 注释里的 race 根因 + 修复。
                    self.setInitialFocalLength(on: device, focal: initialFocal)

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

                        // Live Photo：整生命周期开启捕获能力（与 videoDataOutput 预览共存，现代 iOS 支持）。
                        // 开启≠每张都拍 Live——是否产出动态视频由 per-capture 是否设 livePhotoMovieFileURL
                        // 决定（见 issueCapturePhoto），所以 UI 开关只控制 per-capture，不必重配 session。
                        if output.isLivePhotoCaptureSupported {
                            output.isLivePhotoCaptureEnabled = true
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

        isLivePhotoSupported = photoOutput.isLivePhotoCaptureEnabled

        // 虚拟设备：activeFormat / constituentDevices / virtualDeviceSwitchOverVideoZoomFactors 均已可用
        focalInfo = DeviceFocalInfo.from(virtualDevice: device)
        if !focalInfo.options.contains(currentFocalLength) {
            currentFocalLength = focalInfo.defaultOption
        }

        // 初始 zoom 已在 sessionQueue 配置阶段设好（setInitialFocalLength），这里不再重复
        // applyFocalLength（会多发一次 ramp）。仅同步 MainActor 上的 currentZoomFactor 反映已生效的
        // zoom，让 UI 的焦距条立刻准。
        currentZoomFactor = focalInfo.virtualZoomFactor(for: currentFocalLength)
        // 启动期同样登记一次镜头切换：让前 ~250ms 的 startRunning warmup 帧被 isReadyToCapture 挡在外面
        // 排空。zoom 启动即在 target（setInitialFocalLength 已设），到位即起 250ms ZSL grace；600ms 兜底。
        beginLensSwitch(zoom: currentZoomFactor, zslGraceMs: 250, maxWaitMs: 600)
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
    private func prepareForFirstCapture() {
        func makeWarmSettings(flash: AVCaptureDevice.FlashMode) -> AVCapturePhotoSettings {
            let s: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                s = AVCapturePhotoSettings()
            }
            s.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            s.photoQualityPrioritization = .balanced
            if let device = videoCaptureDevice, device.hasFlash {
                s.flashMode = flash
            }
            return s
        }
        // 预热 flash off + on 两套模板：用户开着闪光灯拍的第一张也能命中热路径。
        // 否则首张闪光照仍会触发 Smart HDR / ZSL pipeline 冷启动（实测 ~2-3s）。
        // settings 字段必须与真实 capture 一致，否则系统按"模板未命中"重走冷路径。
        let templates: [AVCapturePhotoSettings] = {
            var t = [makeWarmSettings(flash: .off)]
            if let device = videoCaptureDevice, device.hasFlash {
                t.append(makeWarmSettings(flash: .on))
            }
            return t
        }()

        let output = photoOutput
        sessionQueue.async {
            output.setPreparedPhotoSettingsArray(templates) { prepared, error in
                if let error {
                    Log.session.error("photo_pipeline_prepare_failed error=\(error.localizedDescription, privacy: .public)")
                } else {
                    Log.session.info("photo_pipeline_prepared ready=\(prepared) templates=\(templates.count)")
                }
            }
        }
    }

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
    nonisolated private func applyBestFormatAndModes(on device: AVCaptureDevice) {
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
    nonisolated private func applyMaxPhotoDimensions(output: AVCapturePhotoOutput, device: AVCaptureDevice) {
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
    nonisolated private func applyPreviewStabilization(output: AVCaptureVideoDataOutput, device: AVCaptureDevice) {
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

    /// 在 session config block 内（startRunning 之前）设好初始焦段的虚拟 zoom。
    ///
    /// **为什么在 startRunning 之前设**：让 startRunning 产出的第一帧就来自正确的 constituent，
    /// ZSL ring buffer 从生下来就干净——否则用户在启动早期按快门，AVF 可能从 ring 里挑到启动
    /// 默认 zoom 的帧出片，照片记成错的镜头/焦段。
    ///
    /// 用 `.auto`（与 applyFocalLength 一致，全程不 `.locked`）：设 videoZoomFactor，硬件在
    /// startRunning 时按它选 constituent，之后系统按条件自动 crossfade。
    /// 走 nonisolated：从 sessionQueue.async 直接调用，不跨回 MainActor。
    nonisolated private func setInitialFocalLength(on device: AVCaptureDevice, focal: FocalLengthOption) {
        let info = DeviceFocalInfo.from(virtualDevice: device)
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
            // .auto 跟随系统（与 applyFocalLength 一致，全程不 .locked）：设初始 zoom，系统据此选 constituent。
            // 启动时默认就是 .auto，所以 .auto + zoom 写在同一 lock 块内安全（无「转出 .locked」的夹取坑）。
            device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            device.videoZoomFactor = targetZoom
            // 安全快门也在此处一并下，避免 startRunning 后第一帧 AE 跑到 1s 上限
            let safeShutter = self.computeSafeShutterDuration(focalMm: resolved.rawValue, format: device.activeFormat)
            device.activeMaxExposureDuration = safeShutter
            device.unlockForConfiguration()
            Log.session.info("focal_init_at_config option=\(resolved.rawValue)mm zoom=\(String(format: "%.2f", targetZoom)) target=\(target.device.localizedName, privacy: .public)")
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
    private func bindDeviceObservers(to device: AVCaptureDevice) {
        zoomObservation?.invalidate()
        focusObservation?.invalidate()
        pressureObservation?.invalidate()
        constituentObservation?.invalidate()

        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] dev, change in
            guard let self, let newZoom = change.newValue else { return }
            let isRamping = dev.isRampingVideoZoom
            Task { @MainActor in
                self.currentZoomFactor = newZoom
                // ramp 推进/停止都戳一下镜头稳定评估（基于设备真值，含 isRampingVideoZoom + zoom 命中）
                self.evaluateLensSettle()
                if isRamping { return }
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

        // activePrimaryConstituentDevice：记录系统当前实际用哪颗物理镜头（`.auto` 下由系统按 zoom +
        // 条件决定），并在 active 变化时戳一下 evaluateLensSettle 重新评估取景是否到位。
        // 到位判定本身只看 zoom（见 lensIsOnTarget），不看 constituent——系统用哪颗都是合法结果。
        // 用 localizedName 只为打日志：AVCaptureDevice 非 Sendable，捕获进 Task @MainActor 会报
        // sending 警告；String 是 Sendable。
        constituentObservation = device.observe(\.activePrimaryConstituent, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            let logName = change.newValue.flatMap { $0?.localizedName } ?? "nil"
            Task { @MainActor in
                if self.activeConstituentName != logName {
                    self.activeConstituentName = logName
                    Log.session.info("constituent_active_changed name=\(logName, privacy: .public)")
                }
                self.evaluateLensSettle()
            }
        }
    }

    /// 根据系统压力等级动态调整预览帧率，防止过热降频
    nonisolated private func adjustFrameRateForPressure(device: AVCaptureDevice, level: AVCaptureDevice.SystemPressureState.Level) {
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

    // MARK: - 8. 镜头切换（.auto 跟随系统）+ 安全快门

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
        sessionConfigured && (photoOutput.connection(with: .video)?.isActive == true)
    }

    /// 完全就绪：根本可用 + 镜头到位 + ZSL grace 走完。capturePhoto 内部 await 它。
    var isReadyToCapture: Bool {
        guard isCaptureAvailable else { return false }
        guard lensTarget != nil else { return true }      // 无进行中的切换 = 已稳定
        return lensIsOnTarget() && lensGracePassed()
    }

    /// 镜头取景是否到位：zoom ramp 已停 && zoom 命中目标。**只看 zoom（取景），不看 constituent**——
    /// `.auto` 下用哪颗物理镜头由系统按条件决定（能切长焦就切、近物/暗光裁主摄），都是合法结果，
    /// capture 不该等某颗特定镜头（否则系统拒绝长焦时快门假死）。zoom ramp 总会停，所以这总会到位。
    private func lensIsOnTarget() -> Bool {
        guard let t = lensTarget else { return true }
        guard let device = videoCaptureDevice else { return false }
        return !device.isRampingVideoZoom && abs(device.videoZoomFactor - t.zoom) < 0.1
    }

    /// 镜头到位后 ZSL grace 是否走完。lensOnTargetSince 由 evaluateLensSettle 在「首次到位」时打点。
    private func lensGracePassed() -> Bool {
        guard let t = lensTarget, let since = lensOnTargetSince else { return false }
        return (CFAbsoluteTimeGetCurrent() - since) * 1000 >= Double(t.zslGraceMs)
    }

    /// 重新评估镜头是否稳定。由 constituent/zoom KVO 与 lensSettleTask 轮询「戳一下」触发——
    /// 它们不再各自翻转状态，只让这里基于设备真值重新判断（单一判定点）。到位即打点 since、
    /// 回退（又开始 ramp）即清空 since 让 grace 重新计时、到位且 grace 走完即 clearLensTarget。
    private func evaluateLensSettle() {
        guard lensTarget != nil else { return }
        if lensIsOnTarget() {
            if lensOnTargetSince == nil { lensOnTargetSince = CFAbsoluteTimeGetCurrent() }
            if lensGracePassed() { clearLensTarget(reason: "on_target") }
        } else {
            lensOnTargetSince = nil
        }
    }

    /// 标记一次镜头切换彻底结束（幂等）。on-target + grace 命中，或 maxWait 兜底超时调用。
    private func clearLensTarget(reason: String) {
        guard let t = lensTarget else { return }
        lensSettleTask?.cancel(); lensSettleTask = nil
        let active = videoCaptureDevice?.activePrimaryConstituent?.localizedName ?? "nil"
        Log.session.info("lens_settled reason=\(reason, privacy: .public) active=\(active, privacy: .public) zoom=\(String(format: "%.2f", t.zoom))")
        lensTarget = nil
        lensOnTargetSince = nil
    }

    /// 开始一次镜头切换：登记目标 zoom + 启动稳定轮询。capture 就绪只看 zoom 到位（见 lensIsOnTarget）。
    /// - zslGraceMs: zoom 到位后给系统 constituent crossfade 收尾的额外等待。
    /// - maxWaitMs: 兜底放弃时刻，即便始终没到位也强制 clearLensTarget，绝不让快门永久卡住。
    private func beginLensSwitch(zoom: CGFloat, zslGraceMs: Int, maxWaitMs: Int) {
        lensTarget = LensTarget(zoom: zoom, zslGraceMs: zslGraceMs)
        lensOnTargetSince = nil
        let token = applyFocalToken
        lensSettleTask?.cancel()
        lensSettleTask = Task { @MainActor [weak self] in
            let deadline = CFAbsoluteTimeGetCurrent() + Double(maxWaitMs) / 1000.0
            while !Task.isCancelled {
                guard let self, self.applyFocalToken == token else { return }
                self.evaluateLensSettle()
                if self.lensTarget == nil { return }            // 已稳定
                if CFAbsoluteTimeGetCurrent() >= deadline {
                    self.clearLensTarget(reason: "max_wait(\(maxWaitMs)ms)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// capturePhoto 在 issue 前 await 直到 isReadyToCapture 或超时。唯一闸门，取代旧的
    /// waitForLensSettled + waitForConstituentMatch 两段分散判定。timeoutMs 仅异常兜底——
    /// 正常路径下镜头到位 + grace 走完即放行（实测几十 ms）。超时也放行（绝不永久卡快门），
    /// 但打 error 便于排查；4000 是异常兜底，远大于一次 zoom ramp 实际所需（百 ms 级）。
    func waitForReadyToCapture(timeoutMs: Int = 4000) async {
        if isReadyToCapture { return }
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + Double(timeoutMs) / 1000.0
        while !isReadyToCapture, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        let waited = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if isReadyToCapture {
            Log.capture.info("capture_ready_wait waited=\(String(format: "%.0f", waited))ms")
        } else {
            Log.capture.error("capture_ready_timeout waited=\(String(format: "%.0f", waited))ms on_target=\(self.lensIsOnTarget()) avail=\(self.isCaptureAvailable)")
        }
    }

    /// 安全快门：限制 AE 最长曝光时间，严格走经典 1/focal（35mm 等效）防手持模糊。
    /// 35mm 等效焦距 = `FocalLengthOption.rawValue`，已折算 W/T 物理镜头 + 数码裁切。
    ///   24mm → 1/24s, 35mm → 1/35s, 50mm → 1/50s, 100mm → 1/100s, 200mm → 1/200s
    /// 不再叠加 OIS 放宽 / 主体运动地板——经验表明手持快照"宁可抬 ISO 出噪点、不可拉快门糊掉",
    /// 1/focal 是这条原则下的经典基线，OIS 在该基线之上只是锦上添花的额外余量。
    /// activeMaxExposureDuration 是无侵入做法：不破坏 .continuousAutoExposure，AE 在上限内自由调节；
    /// 触顶时自动改抬 ISO，符合"保锐优先"。
    /// 上下界用 format.min/maxExposureDuration 兜底，避免越界。
    nonisolated private func computeSafeShutterDuration(focalMm: Int, format: AVCaptureDevice.Format) -> CMTime {
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
    nonisolated private func formatExposureCMTime(_ time: CMTime?) -> String {
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

    /// 切焦距（`.auto` 跟随系统，iPhone 同款）。**单一路径**：始终保持
    /// `setPrimaryConstituentDeviceSwitchingBehavior(.auto)`，只把 videoZoomFactor 平滑 ramp 到目标
    /// 焦段对应的虚拟 zoom；系统在 ramp 跨越 switchover 阈值时自己做硬件 crossfade 切 constituent。
    ///
    /// **不再 `.locked`、不再 deep-ramp 过冲**——这是把多轮真机教训收敛后的终点：强锁 + 过冲既会
    /// 抖动（过冲到 ~10x 再退回），又会在系统拒绝长焦时假死。长焦用不用最终由系统按光线/距离/画质
    /// 判定（近物/暗光裁主摄），任何代码强求不来——`.auto` 直接接受系统决定，和 iPhone 行为一致。
    ///
    /// 边界焦距（24mm zoom=2.0、100mm zoom=8.0）仍加 0.05 ε 推进区间内部，鼓励系统选目标 constituent。
    /// capture 就绪（isReadyToCapture）只等 zoom ramp 停 + ZSL grace，不再等特定 constituent，所以
    /// 系统拒长焦时快门不假死。`applyFocalToken` 让快速连点时旧 lensSettleTask 轮询失效。
    private func applyFocalLength(_ option: FocalLengthOption, animated: Bool = true, fromZoom: CGFloat? = nil) {
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

        // 自适应 ramp 速率：跨度越大越快，小幅切换更柔和（同 iPhone 原相机）
        let ratio = fromZoom.map { max(targetZoom / $0, $0 / targetZoom) } ?? 2.0
        let rampRate: Float = if ratio < 1.5 { 4.0 } else if ratio < 3.0 { 8.0 } else { 16.0 }

        // 单一路径：始终 .auto，只把 videoZoomFactor 平滑 ramp 到目标。系统在 ramp 跨越 switchover
        // 阈值时自己做硬件 crossfade 切 constituent（能切长焦就切、近物/暗光裁主摄）。device 全程不
        // .locked，所以 .auto + zoom 写在同一 lock 块内安全（无「转出 .locked 时 zoom 被旧 min/max
        // 夹住」的老坑）。不再 deep-ramp 过冲 → 无前后抖动；不再等特定 constituent → 系统拒长焦不假死。
        let maxZoom = device.activeFormat.videoMaxZoomFactor
        let finalZoom = max(1.0, min(maxZoom, targetZoom))

        // 乐观更新 UI 焦距 + 立即登记镜头切换目标。此刻设备 zoom 仍是旧值，lensIsOnTarget() 因
        // |旧 zoom − finalZoom| > 0.1 而为 false，isReadyToCapture 仍正确 gate（不会误判已就绪而
        // 让 ZSL 选到旧帧）——所以可以安全地先登记、再异步配置设备。
        self.currentZoomFactor = finalZoom
        // capture 就绪只等 zoom ramp 停（取景到位）+ 一点 ZSL grace 给系统的 constituent crossfade 收尾；
        // 不再等特定 constituent（系统说了算）——所以系统拒绝长焦时快门不假死。maxWait 仅异常兜底。
        beginLensSwitch(zoom: finalZoom, zslGraceMs: 150, maxWaitMs: 1200)

        // 设备 I/O（lockForConfiguration + ramp + 安全快门）移到 sessionQueue 执行。streaming 中
        // **首次** lockForConfiguration 会阻塞调用线程数百 ms（系统等采集管线到安全配置点）；放在
        // 主线程就会卡住预览/手势 → 用户感知的「第一次切焦距卡顿」。与 adjustFrameRateForPressure
        // 同款「设备配置走 sessionQueue」模式（Apple AVCam 惯例）。.auto + ramp 单一路径逻辑不变。
        sessionQueue.async { [weak self] in
            self?.configureFocalOnSessionQueue(
                device: device, finalZoom: finalZoom, rampRate: rampRate,
                animated: animated, focalMm: option.rawValue
            )
        }
    }

    /// applyFocalLength 的设备配置段，在 sessionQueue 上执行（nonisolated，不触碰 @MainActor 状态）。
    /// 把 lockForConfiguration/ramp 从主线程移走，避免首次配置阻塞主线程导致预览掉帧。
    nonisolated private func configureFocalOnSessionQueue(
        device: AVCaptureDevice, finalZoom: CGFloat, rampRate: Float, animated: Bool, focalMm: Int
    ) {
        do {
            try device.lockForConfiguration()
            device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            if animated {
                device.ramp(toVideoZoomFactor: finalZoom, withRate: rampRate)
            } else {
                device.videoZoomFactor = finalZoom
            }
            let safeShutter = computeSafeShutterDuration(focalMm: focalMm, format: device.activeFormat)
            device.activeMaxExposureDuration = safeShutter
            device.unlockForConfiguration()
            let active = device.activePrimaryConstituent?.localizedName ?? "nil"
            Log.session.info("focal_applied option=\(focalMm)mm target_zoom=\(String(format: "%.2f", finalZoom))x active=\(active, privacy: .public) animated=\(animated)")
        } catch {
            Log.session.error("focal_apply_lock_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 9. 拍照

    func capturePhoto(
        live: Bool = false,
        onWillCapture: (() -> Void)? = nil,
        onExposureComplete: (() -> Void)? = nil,
        onShutterReady: @escaping () -> Void = {},
        completion: @escaping (CaptureResult?) -> Void
    ) {
        // 只有 photoOutput 真支持 Live Photo 时才认这次为 live。配对 content id 不在此生成——
        // 由 AVCapture 自动写入原始字节，后处理阶段读出后统一写进重编码产物。
        let wantsLive = live && photoOutput.isLivePhotoCaptureEnabled
        let request = CaptureRequest(
            onData: completion,
            onShutterReady: onShutterReady,
            onWillCapture: onWillCapture,
            onExposureComplete: onExposureComplete,
            flashRestore: nil,
            expectsLiveMovie: wantsLive
        )

        // 唯一闸门：await 直到 isReadyToCapture（根本可用 + 镜头到位 + ZSL grace）再 issue 给 AVF。
        // 取代旧的 isLensTransitioning + waitForLensSettled + waitForConstituentMatch 三段分散判定——
        // 三者现在都收敛进 isReadyToCapture 这一处谓词。修的根因：ZSL ring 里上一颗 constituent /
        // 过冲 zoom 的旧帧被选作出片源 → 用户选 35mm / 100mm 拍出的照片元数据/视野是错的镜头/焦段。
        // waitForReadyToCapture 内有 4s 兜底，不会让快门永久卡住。
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForReadyToCapture()
            self.issueCapturePhoto(request)
        }
    }

    /// capturePhoto 主体——拆出来是为了让外层 capturePhoto 能 await waitForReadyToCapture。
    /// 必须 @MainActor：访问 photoOutput / videoCaptureDevice / inFlightCaptures / flashMode。
    /// request 在此填好 flashRestore 后，按 settings.uniqueID 登记进 inFlightCaptures。
    private func issueCapturePhoto(_ request: CaptureRequest) {
        var request = request
        let issueTime = Log.now()
        // 防御性兜底：waitForReadyToCapture 返回 ready 到这里之间仍隔着调度边界，其间 session 可能被
        // 切后台 / stopSession 拆掉 connection。无 active connection 时 photoOutput.capturePhoto 会抛
        // NSException 崩溃——这里改为优雅终结：放开快门 + 以 nil 释放后处理槽位。
        guard photoOutput.connection(with: .video)?.isActive == true else {
            Log.capture.error("capture_skip reason=no_active_connection")
            request.onShutterReady()
            request.onData(nil)
            return
        }
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
                // 距离感知 flash bias 是"用户未表达意图时的智能默认"；用户若在 sun rail 上主动
                // 拨过 EV（exposureBias != 0），把它叠加到 flash bias 上——与 iPhone 原相机一致：
                // EV 补偿在含闪光的测光结果之上继续生效。userBias=0 时 combinedBias==flashBias，
                // 与旧行为完全等价。savedBias 读的是 device.exposureTargetBias（已镜像等于 userBias），
                // capture 完成后经 CaptureRequest.flashRestore 还原回 userBias，@Published exposureBias 全程不变。
                let flashBias = calculateFlashExposureBias(device: device)
                let combinedBias = flashBias + exposureBias
                do {
                    try device.lockForConfiguration()
                    let savedBias = device.exposureTargetBias
                    let savedWBMode = device.whiteBalanceMode
                    var didLockExposure = false
                    var didLockWB = false

                    let clamped = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, combinedBias))
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

                    // 还原状态写进本次拍照的 CaptureRequest——随单次拍照走，不会跨拍照覆盖。
                    // 不再需要旧的「stale pendingFlashRestore 自愈」分支：per-request 结构上无法泄漏，
                    // 且 didFinishCaptureFor 终结回调保证 flashRestore 必被消费恰好一次。
                    request.flashRestore = FlashRestoreState(
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

        // Live Photo：本次拍照要求动态视频时，给 settings 挂一个唯一临时 .mov 路径。
        // **不要**自己写 content identifier——AVCapture 会自动生成并写进静态图与视频原始字节，
        // 通过 livePhotoMovieMetadata 指定它会直接抛 NSInvalidArgumentException 崩溃。配对 id 由后处理
        // 阶段从原始视频读出后，统一写进重编码的视频与静态图（见 LivePhotoProcessor / CameraView）。
        // 视频在 didFinishProcessingLivePhotoToMovieFileAt 回调里到达（约 shutter 后 ~1.5s，因为 Live
        // 视频是 shutter 前后各 ~1.5s 的环形缓冲）。
        let wantsLive = request.expectsLiveMovie
        if wantsLive, photoOutput.isLivePhotoCaptureEnabled {
            let movieURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("livephoto_src_\(UUID().uuidString).mov")
            settings.livePhotoMovieFileURL = movieURL
        }

        // 闪光灯下恒定色彩（Constant Color）减少白平衡偏移。Live Photo 与 Constant Color（内部走
        // bracketed capture）不兼容——live 时跳过，避免 AVF 拒绝 settings。
        if photoOutput.isConstantColorSupported, flashMode == .on, !wantsLive {
            settings.isConstantColorEnabled = true
        }

        // 抓取当前 rotation 角度（避免在 sessionQueue 跨 actor 访问）。
        // 出片随物理朝向：横握出横片、竖握出竖片，与 iPhone 系统相机一致。
        // 见 applyVideoOrientationToOutputs 的"预览/出片解耦"说明。
        let rotationAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let output = photoOutput
        let delegate = self
        // 闪光灯路径需要 200ms 延迟让 lockExposure + setExposureTargetBias 真正生效。
        let needsFlashDelay = (request.flashRestore?.lockedExposure ?? false)

        // 登记进 inFlightCaptures：以 settings.uniqueID 为键，delegate 回调按 resolvedSettings.uniqueID
        // 找回本 request。必须在 dispatch capturePhoto **之前**登记，否则 willCapture/didFinishProcessing
        // 可能先于登记到达而丢失。
        inFlightCaptures[settings.uniqueID] = request

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

        // 焦距可观测性：把"用户选的等效焦距 / 系统实际选用的物理镜头 / 当前变焦倍率 / 在该镜头上的
        // 数码裁切倍率"一行打全。说明：
        //   equiv_set   = 用户档位的 35mm 等效焦距，也是写进 EXIF(FocalLenIn35mmFilm) 的值
        //   lens        = 系统 `.auto` 下实际激活的物理 constituent + 它的 Apple 标称 35mm 等效
        //                 （UW=13 / W=24 / T=100）。系统可能在弱光/近摄时给主摄裁切而非长焦——这里能看出
        //   zoom        = 虚拟设备当前 videoZoomFactor
        //   equiv_live  = 由 zoom×当前镜头反推的实际等效焦距（理论上≈equiv_set，偏差说明镜头没切到位）
        //   digi_crop   = equiv_set / 镜头标称，即在这颗物理镜头上又做了多少数码裁切（1.0=原生无裁切）
        let activeLens = self.videoCaptureDevice?.activePrimaryConstituent
        let lensName = activeLens?.localizedName ?? "nil"
        let lensNativeMm = activeLens?.nominalFocalLengthIn35mmFilm ?? 0
        let liveZoom = self.videoCaptureDevice?.videoZoomFactor ?? 0
        let equivSet = self.currentFocalLength.rawValue
        let equivLive = self.focalInfo.equivalentMm(forZoom: liveZoom, activeConstituent: activeLens)
        let digiCrop = lensNativeMm > 0 ? Float(equivSet) / lensNativeMm : 0
        Log.capture.info("capture_focal equiv_set=\(equivSet)mm equiv_live=\(String(format: "%.1f", equivLive))mm lens=\(lensName, privacy: .public)/\(String(format: "%.0f", lensNativeMm))mm zoom=\(String(format: "%.2f", liveZoom))x digi_crop=\(String(format: "%.2f", digiCrop))x")
        let captureID = settings.uniqueID
        sessionQueue.asyncAfter(deadline: deadline) { [weak self] in
            // 重查 connection：登记（1585）到这里之间隔着 flash 的 200ms 延迟窗口，期间 stopSession /
            // pauseSessionForBackground 可能已把 session 停掉。对非活跃 connection 调 capturePhoto 会抛
            // NSException，且 delegate 终结回调永不到达 → inFlightCaptures 条目、flashRestore（AE/WB
            // 保持 .locked）、onShutterReady 全部永久泄漏。这里改为优雅终结：还原 AE/WB + 放开快门 +
            // 以 nil 释放后处理槽位。
            guard output.connection(with: .video)?.isActive == true else {
                Log.capture.error("capture_skip reason=connection_inactive_at_invoke")
                Task { @MainActor in self?.deliverCaptureIfReady(id: captureID, terminal: true) }
                return
            }
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

    // MARK: - 10. 后台 / 前台 / 停止

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

    // MARK: - 11. 设备数据 dump（调试用）
    //
    // 一次性打印当前后置虚拟设备 / 会话的所有可读数据，便于调试与设备适配。
    // 必须在 session 配置完成后调用，否则 activeFormat / 缩放范围 / maxPhotoDimensions 会读到默认值。
    // nonisolated + 所有依赖通过 LensDumpArgs 传入：可在 background QoS task 上跑，不占用主 actor。

    nonisolated private static func dumpLensSpecsImpl(args: LensDumpArgs) {
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
    nonisolated private static func hardwareModelIdentifier() -> String {
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

    // MARK: - 12. 位置服务

    /// 获取缓存或当前位置（无阻塞等待，30s 缓存策略）
    func cachedOrFreshLocation() async -> CLLocation? {
        let now = Date()

        // 1. 检查 30s 内的缓存
        if let cached = locationCache,
           now.timeIntervalSince(locationCacheTime) < locationCacheExpiry {
            return cached
        }

        // 2. 使用当前位置并更新缓存
        if let fresh = currentLocation {
            locationCache = fresh
            locationCacheTime = now
            return fresh
        }

        // startUpdatingLocation 已在持续更新，无需额外请求
        return nil
    }

    private func startLocationServices() {
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
        locationManager.startUpdatingLocation()
    }

    private func stopLocationServices() {
        locationManager.stopUpdatingLocation()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate（实时预览样本帧）
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    @preconcurrency nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        self.setLatestPixelBuffer(buffer)
        self.logFirstFrameOnce(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        // 不再 dispatch main 触发 setNeedsDisplay：MTKView 已切换到 CADisplayLink 驱动
        // （MetalPreview.swift），每个 vsync 调一次 draw(in:)，draw 内部按 frameId 去重。
        // 这里只负责把最新帧写入 lock 保护的 buffer，主队列零负担。
    }
}

// MARK: - AVCaptureSessionControlsDelegate（Camera Control 控件激活必需）
extension CameraManager: AVCaptureSessionControlsDelegate {
    nonisolated func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        Log.session.info("camera_controls_active")
    }
    nonisolated func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    nonisolated func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    nonisolated func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        Log.session.info("camera_controls_inactive")
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    /// AVF 主曝光即将开始——开闪光灯时这一刻就是氙气主脉冲发射的瞬间。
    /// Apple 文档明确指引这里做 shutter visual feedback（屏幕白屏 / 快门音）。
    /// UI 白屏挂在这里 → 与真实闪光灯物理同帧，告别"先白屏后亮灯"的脱钩感。
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Log.capture.info("delegate_will_capture")
        let id = resolvedSettings.uniqueID
        Task { @MainActor in self.inFlightCaptures[id]?.onWillCapture?() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Log.capture.info("delegate_did_capture dims=\(resolvedSettings.photoDimensions.width)x\(resolvedSettings.photoDimensions.height)")
        let id = resolvedSettings.uniqueID
        Task { @MainActor in self.inFlightCaptures[id]?.onExposureComplete?() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let id = resolvedSettings(of: photo)
        if let error = error {
            Log.capture.error("delegate_process_error error=\(error.localizedDescription, privacy: .public)")
            // 静态图失败 = 无可保存内容，立即以终结方式释放（即便还等着 live 视频也不必再等）。
            Task { @MainActor in
                self.mutateCapture(id) { $0.stillArrived = true }
                self.deliverCaptureIfReady(id: id, terminal: true)
            }
            return
        }
        guard let imageData = photo.fileDataRepresentation() else {
            Log.capture.error("delegate_process_no_data")
            Task { @MainActor in
                self.mutateCapture(id) { $0.stillArrived = true }
                self.deliverCaptureIfReady(id: id, terminal: true)
            }
            return
        }
        Log.capture.info("delegate_process_ok bytes=\(imageData.count)")

        // CIImage(data:) in applyLUTPreservingMetadata already applies EXIF orientation,
        // so we pass raw data directly — no need for a separate rotate+encode step.
        // 静态图到达：记下数据 + 标记到位，立即尝试交付。**非 live：onData 立即触发，启动后处理；
        // live：onShutterReady 在此触发放开快门，onData 等视频再触发**——deliverCaptureIfReady 内分流。
        Task { @MainActor in
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
        if let error = error {
            Log.capture.error("delegate_live_movie_error error=\(error.localizedDescription, privacy: .public)")
            // 视频失败：标记到位但 URL 为 nil → 交付时降级为「只存静态图」，绝不卡死。
            Task { @MainActor in
                self.mutateCapture(id) { $0.movieArrived = true }
                self.deliverCaptureIfReady(id: id, terminal: false)
            }
            return
        }
        Log.capture.info("delegate_live_movie_ok dur=\(String(format: "%.2f", duration.seconds))s display=\(String(format: "%.2f", photoDisplayTime.seconds))s")
        Task { @MainActor in
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
        Task { @MainActor in self.deliverCaptureIfReady(id: id, terminal: true) }
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
    ///   1. onShutterReady：静态图就绪（或终结）+ 闪光灯 AE/WB 已还原 → 立即放开快门。**不等 live 视频。**
    ///   2. onData：凑齐本次要求的交付物（非 live：静态图；live：静态图 + 动态视频）→ 启动后处理。
    /// 两者各只触发一次（shutterReleased / resultDelivered 幂等守卫）。一旦 onData 交付即把 request
    /// 移出 inFlightCaptures；多个 delegate 回调重入直接被守卫挡掉。
    /// - terminal: didFinishCaptureFor 兜底调用时为 true，强制交付（即便交付物未齐）。
    @MainActor
    private func deliverCaptureIfReady(id: Int64, terminal: Bool) {
        guard var req = inFlightCaptures[id] else { return }

        // 还原闪光灯 AE/WB：静态图一就绪（或终结）就做，不被 live 视频录制窗口拖累。只做一次。
        if let restore = req.flashRestore, req.stillArrived || terminal {
            if let device = videoCaptureDevice { applyFlashRestore(restore, device: device) }
            req.flashRestore = nil
        }

        // 放开快门：静态图就绪（或终结）即触发，只一次。这是把「快门可再按」从「完整交付」解耦的关键——
        // live 时静态图 ~300ms 就到，配对视频的 ~1.5s 录制窗口不再卡住下一张。
        if !req.shutterReleased, req.stillArrived || terminal {
            req.shutterReleased = true
            req.onShutterReady()
        }

        let movieReady = !req.expectsLiveMovie || req.movieArrived
        let canDeliver = terminal || (req.stillArrived && movieReady)

        guard canDeliver else {
            inFlightCaptures[id] = req   // 回写已清空的 flashRestore / 已置位的 shutterReleased
            return
        }

        inFlightCaptures[id] = nil
        guard !req.resultDelivered else { return }
        req.resultDelivered = true
        if let data = req.stillData {
            req.onData(CaptureResult(
                imageData: data,
                livePhotoMovieURL: req.movieURL,
                photoDisplayTime: req.photoDisplayTime
            ))
        } else {
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
                self.stopLocationServices()
            default:
                break
            }
        }
    }
}
