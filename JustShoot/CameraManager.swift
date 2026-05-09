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
// 单文件 AVFoundation 编排：iOS 26 虚拟设备 (`builtInTripleCamera`) + `.locked` constituent
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
//   7. Session 配置（format / dims / stabilization / 初始焦段锁 / KVO）
//   8. 镜头切换（fast / slow path + 安全快门）
//   9. 拍照（capturePhoto + issue）
//  10. 后台 / 前台 / 停止
//  11. 设备数据 dump（调试）
//  12. 位置服务
//  13. AVCapturePhotoCaptureDelegate / CLLocationManagerDelegate / 其它 delegate

@MainActor
class CameraManager: NSObject, ObservableObject {

    // MARK: 1. 存储属性

    /// 虚拟设备 AVCaptureSession（iOS 26 推荐架构）：以 .builtInTripleCamera 等虚拟设备作为
    /// 单一 input；切焦距通过 setPrimaryConstituentDeviceSwitchingBehavior(.locked, ...) +
    /// videoZoomFactor 完成 — 系统在内部做硬件级 constituent 切换，预览不黑屏，无需 bridgeImage。
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
    /// beginLensTransition 启动的 grace 超时 task；新一次进入或外部 markLensSettled 时取消旧的。
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

    private var photoDataHandler: ((Data?) -> Void)?
    private var exposureCompleteHandler: (() -> Void)?
    /// AVF 在主曝光（含闪光灯主脉冲）即将开始那一帧 fire 的回调，由
    /// `photoOutput(_:willCapturePhotoFor:)` 在 main actor 上派发。
    /// 用途：把屏幕白屏覆盖层与真实闪光灯同帧触发——这是 Apple 文档明确推荐的
    /// shutter visual feedback 挂载点，避免"UI 先闪、氙气灯后亮"的脱钩感。
    private var willCaptureHandler: (() -> Void)?
    @Published var flashMode: FlashMode = .off

    // 震动反馈（预创建复用，减少首次延迟）
    let hapticLight = UIImpactFeedbackGenerator(style: .light)
    let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
    let hapticSoft = UIImpactFeedbackGenerator(style: .soft)

    // 等效焦距
    @Published var currentFocalLength: FocalLengthOption = .mm35
    @Published var focalInfo: DeviceFocalInfo = .placeholder
    /// 当前 zoom factor。镜头 ramp 期间被 KVO 每帧写入，UI 不直接读 —— 故意不 @Published,
    /// 避免每帧触发 SwiftUI 全 body 重算（旧实现在 35→100mm slow-path 期间能让 CameraView body
    /// 重算 30+ 次，把主线程交给 SwiftUI 而非预览渲染）。
    var currentZoomFactor: CGFloat = 1.0
    /// 当前实际激活的物理 constituent（KVO 自虚拟设备 activePrimaryConstituentDevice）。
    /// 仅用于 log，UI 不读。
    private var activeConstituentName: String = ""
    /// 镜头切换进行中（slow path Phase 0–3 + 200ms grace period）。
    /// **关键作用**：capturePhoto 在 issue 给 AVF 之前 await 此 flag 归 false——避免
    /// ZSL ring buffer 里上一颗 constituent 的旧帧被选作出片源。等效焦距 35mm 的照片在
    /// 元数据里"被报成 13mm 镜头拍摄"的根因，就是这个 race。Capture 内部由 waitForLensSettled
    /// 串行化，UI 不需要看 —— 不 @Published 避免无谓的 SwiftUI 重算。
    var isLensTransitioning: Bool = false
    /// 当前切换目标 constituent。constituentObservation 命中时（active === expected）即认为
    /// 镜头硬件已切到位，slow path Phase 3 lock 后再加 200ms grace 让 ZSL ring 完全换血。
    private var expectedConstituent: AVCaptureDevice?
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

    // 拍照曝光补偿 / WB 还原
    //
    // 旧实现把 4 个标量散在 CameraManager 上：previousExposureTargetBias、previousWBMode、
    // lockedExposureForFlashCapture、lockedWBForFlashCapture。每次 capturePhoto 直接覆盖。
    // 风险：连按两次闪光灯快门时，第二次 lock 在第一次 didFinishProcessingPhoto 还原之前
    // 就把 previousExposureTargetBias 覆盖成"调整后的偏置"，还原后从此 AE 永远跑偏。
    //
    // 新实现：把"需要还原什么"打包成一个值，pendingFlashRestore 同时只允许 0 或 1 个。
    // capturePhoto 入口若发现 pendingFlashRestore != nil，说明上一次还原没跑完（异常路径），
    // 立即先还原再开新的。配合 isCapturing 全程持有，正常路径下 dict 永远只有 0 或 1 个 entry。
    private struct FlashRestoreState {
        let exposureTargetBias: Float
        let wbMode: AVCaptureDevice.WhiteBalanceMode
        let lockedExposure: Bool
        let lockedWB: Bool
    }
    private var pendingFlashRestore: FlashRestoreState?
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
    /// 完成后会通过 pendingFlashRestore 恢复，对外表现仍等于这里。
    @Published var exposureBias: Float = 0

    /// 虚拟（或物理）设备 — 整个生命周期固定，不 swap。constituent 由系统按 zoom + .locked
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

    /// 按 iOS 26 推荐顺序选取后置 capture device。优先虚拟设备：让系统在内部完成 constituent
    /// 切换（硬件级 crossfade，无黑屏），同时通过 setPrimaryConstituentDeviceSwitchingBehavior(.locked)
    /// 严格控制每个焦距档位实际使用哪颗物理镜头。
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
    private func prepareForFirstCapture() {
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
    nonisolated private func lockInitialFocalLength(on device: AVCaptureDevice, focal: FocalLengthOption) {
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

    // MARK: - 8. 镜头切换（fast / slow path）+ 安全快门

    /// 等待镜头切换稳定。capturePhoto 在 issue 给 AVF 之前调用——保证 ZSL ring 已经
    /// 换上新 constituent 的帧，不会从旧镜头的缓冲帧里挑出片。
    /// 600ms 上限保证就算 transition flag 因异常没被清掉，快门也不会永久卡住。
    func waitForLensSettled(timeoutMs: Int = 3500) async {
        guard isLensTransitioning else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + Double(timeoutMs) / 1000.0
        while isLensTransitioning, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        let waited = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Log.capture.info("lens_settle_wait waited=\(String(format: "%.0f", waited))ms still_transitioning=\(self.isLensTransitioning)")
    }

    /// capturePhoto 二次闸门：确认 active constituent === expected。slow-path 在
    /// constituent mismatch 时不锁、保留 .auto，给系统自然 crossfade 的最后窗口。命中即返回,
    /// 超时也放行（至少不卡死快门）。绝大多数已经在 waitForLensSettled 期间命中，这里只跑几十 ms。
    func waitForConstituentMatch(timeoutMs: Int) async {
        guard let device = videoCaptureDevice,
              let expected = expectedConstituent else { return }
        if device.activePrimaryConstituent === expected { return }
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + Double(timeoutMs) / 1000.0
        while device.activePrimaryConstituent !== expected, CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let waited = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let matched = device.activePrimaryConstituent === expected
        if matched {
            Log.capture.info("constituent_settle_ok waited=\(String(format: "%.0f", waited))ms")
        } else {
            Log.capture.error("constituent_settle_timeout waited=\(String(format: "%.0f", waited))ms expected=\(expected.localizedName, privacy: .public) active=\(device.activePrimaryConstituent?.localizedName ?? "nil", privacy: .public)")
        }
    }

    /// slow-path mismatch 兜底：后台 watcher 监视 active === target，命中即在 lock 块内
    /// 原子地 commit `.locked`，钉死 constituent 防止 .auto 反复横跳。
    ///
    /// 解决的 bug：100mm 的 targetZoom=8.05 紧贴 W↔T switchover 阈值，`.auto` 在边界态不稳定——
    /// AE/AF re-evaluate（如用户对焦后）系统会反复在 W/T 之间切。slow-path 结束时若 active 还在 W,
    /// "保留 .auto 等自然 commit"路径下，T 来了又走，capture 落在 W 上的 8x 数码裁切（即用户报的
    /// "100mm 用的是 24mm 镜头拍摄的"）。Deferred lock 抢在第一次 commit T 时把 constituent 钉死。
    ///
    /// 锁的原子性：lockForConfiguration 持锁期间系统无法切 constituent，所以"读 active === target"
    /// 与"写 .locked"在同一 lock 块内是原子的。读到 target 才写 .locked，否则解锁继续 polling。
    /// applyFocalToken 用于失效——用户中途切换焦段会让旧 watcher 直接退出。
    private func armDeferredLockToTarget(_ targetDevice: AVCaptureDevice, focalToken: UInt64, timeoutSec: Double) {
        Task { @MainActor [weak self] in
            guard let self, let device = self.videoCaptureDevice else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let deadline = start + timeoutSec
            while CFAbsoluteTimeGetCurrent() < deadline {
                if self.applyFocalToken != focalToken { return }
                if device.activePrimaryConstituent === targetDevice {
                    do {
                        try device.lockForConfiguration()
                        let activeInLock = device.activePrimaryConstituent === targetDevice
                        if activeInLock {
                            device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                        }
                        device.unlockForConfiguration()
                        if activeInLock {
                            let waited = (CFAbsoluteTimeGetCurrent() - start) * 1000
                            Log.session.info("focal_deferred_lock_ok target=\(targetDevice.localizedName, privacy: .public) waited=\(String(format: "%.0f", waited))ms")
                            return
                        }
                        // 极少见：active 在我们读到 → 拿到 lock 之间又变了。继续 polling。
                    } catch {
                        Log.session.error("focal_deferred_lock_failed error=\(error.localizedDescription, privacy: .public)")
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            Log.session.error("focal_deferred_lock_timeout target=\(targetDevice.localizedName, privacy: .public) timeout=\(String(format: "%.1f", timeoutSec))s active=\(device.activePrimaryConstituent?.localizedName ?? "nil", privacy: .public)")
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

    /// 标记进入"镜头切换中"状态。capturePhoto 会 await 直到此 flag 归 false 再发给 AVF。
    /// 默认 600ms 兜底超时；调用方传 graceMs 控制启动期 / slow-path 完成后的余量（让 ZSL 换血）。
    /// 同样的 flag 在 lensSettleTask 里被定时器或 constituent KVO 命中时清掉——双保险。
    private func beginLensTransition(graceMs: Int) {
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
    private func markLensSettled(reason: String) {
        guard isLensTransitioning else { return }
        lensSettleTask?.cancel()
        lensSettleTask = nil
        isLensTransitioning = false
        Log.session.info("lens_settled reason=\(reason, privacy: .public) active=\(self.activeConstituentName, privacy: .public) expected=\(self.expectedConstituent?.localizedName ?? "nil", privacy: .public)")
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

        // ============= 慢路径：跨 constituent =============
        // 进慢路径意味着 ZSL ring 即将经历"旧 constituent 帧 → 切换中模糊帧 → 新 constituent 帧"
        // 三段过渡。capturePhoto 必须等到这段过渡完才发出 issue，否则出片元数据会带上旧镜头。
        //
        // **iOS 26 .auto hysteresis bug**：targetZoom 正好踩在 switchover 阈值附近时（如 100mm
        // zoom=8.05 紧贴 W↔T 边界 zoom=8.0），系统宁可让旧 constituent 数码裁切也不切。即使 +0.05
        // ε、或后台 deferred-lock polling 5s，都救不回来 —— 用户报告"100mm 拍出 24mm 镜头"的根因。
        //
        // **修复**：跨 constituent + targetZoom 接近目标区间下界时，Phase 1 不直冲 targetZoom，而是
        // ramp 到深处（lowerBound + 2.0，例 100mm 的 zoom=10），让 .auto 在远离边界处下决心切换；
        // 等 active === target 后，**同一 lock 块内** .locked + ramp 回 targetZoom（.locked 把
        // minAvailableVideoZoomFactor 钉到 lowerBound=8.0，ramp 8.05 完全合法）。
        // 视觉上：100mm 时画面短暂"过冲"到 ~120mm 再退回 100mm，远好过卡在 W 数码裁切上。
        //
        // 旧实现尝试 dwell 在 +0.5（zoom=8.5）失败 —— 余量太小，仍在 hysteresis 窗内；+2.0 给系统
        // 充分空间。即便深 ramp 后仍 mismatch（极端情况），也会 ramp 回 targetZoom 保证视野和
        // EXIF 焦段正确，再启动 deferred-lock 兜底。
        expectedConstituent = target.device
        // Phase 0(100ms) + Phase 1(deep ramp ≤1500ms) + Phase 2(constituent ≤1500ms) + Phase 3(lock + snap-back ≤500ms)
        // + 200ms ZSL grace ≈ 3800ms 上限。slow-path 自身在结束时 markLensSettled，这里只是兜底。
        beginLensTransition(graceMs: 3800)

        // 决定 Phase 1 ramp 目标。深 ramp 的目的是绕过 iOS 26 .auto 在 switchover 边界的
        // hysteresis bug，但**仅观察到 W↔T 边界（zoom=8.0）有这个 bug**——100mm 的 zoom=8.05
        // 直冲会卡在 W 数码裁切。UW↔W 边界（zoom=2.0）实测 .auto 能正常切换。
        //
        // 所以 deep ramp 限制为 target 是 T 镜头时启用（nativeMm ≥ 50 覆盖所有 iPhone 的 T:
        // 52/56/65/77/100/120mm）。否则一律直冲 targetZoom：
        //  - 24mm（W 下界 +0.05 ε）：直冲 2.05，连续 zoom，无 overshoot；
        //  - 13mm（UW 下界）：直冲 1.0；
        //  - 35/50mm（W 区间内部）：直冲对应 zoom；
        //  - 200mm（T 区间内部 zoom=16）：targetZoom 离下界 > 1.0，nearLowerBound=false，不会触发 deep ramp。
        // 唯一会启用 deep ramp 的场景：target 是 T 且 targetZoom 接近 T 下界，即 100mm 这一档。
        // 旧实现让 24mm 也 deep ramp 到 zoom=4（52mm 视野）再退回 24mm，画面来回闪烁（用户报）。
        let lowerBound = target.virtualZoomRange.lowerBound
        let upperBound = target.virtualZoomRange.upperBound
        let nearLowerBound = (targetZoom - lowerBound) < 1.0
        let canDeepRamp = (upperBound - lowerBound) > 2.0
        let targetIsTele = target.nativeMm >= 50
        let needsDeepRamp = nearLowerBound && canDeepRamp && targetIsTele
        let phase1Target: CGFloat = needsDeepRamp ? min(lowerBound + 2.0, upperBound) : targetZoom

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
            // 100ms ≈ 3 帧 @30fps。33ms 在 iOS 26 上不够稳：偶发 .auto 还没真正接管 zoom 范围,
            // Phase 1 的 ramp 写入仍按旧 .locked min/max 被夹住，导致跨 constituent 切换看似成功
            // 但实际 active 还停在旧 constituent 上。
            try? await Task.sleep(for: .milliseconds(100))
            if self.applyFocalToken != myToken { return }

            // Phase 1: ramp 到 phase1Target（needsDeepRamp 时是 lowerBound+2.0 的深处，否则就是 targetZoom）
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: phase1Target, withRate: rampRate)
                } else {
                    device.videoZoomFactor = phase1Target
                }
                self.currentZoomFactor = phase1Target
                // 安全快门：按目标焦段（不是 phase1Target 的等效焦段）算，因为最终落在 targetZoom 上
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
            // ramp 完成后 .auto 仍可能要 ~1s 才真正 commit 跨 constituent 的 crossfade（iOS 26 在
            // 大跨度下尤其明显）。1500ms 兜底；needsDeepRamp 路径下深 ramp 已远离边界，正常会很快命中。
            let consDeadline = Date().addingTimeInterval(1.5)
            while device.activePrimaryConstituent !== target.device, Date() < consDeadline {
                try? await Task.sleep(for: .milliseconds(20))
                if self.applyFocalToken != myToken { return }
            }
            if self.applyFocalToken != myToken { return }

            // Phase 3: lock + 如有需要 snap 回 targetZoom。
            // - match：lock 块内 .locked + ramp 回 targetZoom（.locked 已把 min 钉到 lowerBound,
            //   ramp 到 targetZoom（如 8.05）完全合法，且系统不会再切 constituent）。
            // - mismatch：保留 .auto，仍 ramp 回 targetZoom 保证视野和 EXIF 焦段正确,
            //   启动 deferred-lock 5s 后台 watcher 兜底。
            let activeBeforeLock = device.activePrimaryConstituent
            let match = activeBeforeLock === target.device
            let needsZoomSnapBack = abs(device.videoZoomFactor - targetZoom) > 0.05
            if match {
                do {
                    try device.lockForConfiguration()
                    device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                    if needsZoomSnapBack {
                        // ramp 回 targetZoom，速率加倍让 overshoot 退回更快
                        if animated {
                            device.ramp(toVideoZoomFactor: targetZoom, withRate: rampRate * 2)
                        } else {
                            device.videoZoomFactor = targetZoom
                        }
                        self.currentZoomFactor = targetZoom
                    }
                    device.unlockForConfiguration()
                } catch {
                    Log.session.error("focal_phase3_lock_failed error=\(error.localizedDescription, privacy: .public)")
                    return
                }
                // 等 snap-back ramp 完成（≤500ms），让 ZSL ring 在 targetZoom 上收齐新帧
                if needsZoomSnapBack && animated {
                    let snapDeadline = Date().addingTimeInterval(0.5)
                    while device.isRampingVideoZoom, Date() < snapDeadline {
                        try? await Task.sleep(for: .milliseconds(20))
                        if self.applyFocalToken != myToken { return }
                    }
                }
            } else {
                Log.session.error("focal_constituent_mismatch target=\(target.device.localizedName, privacy: .public) active=\(activeBeforeLock?.localizedName ?? "nil", privacy: .public) zoom=\(String(format: "%.2f", device.videoZoomFactor))x deep_ramp=\(needsDeepRamp) — staying in .auto, deferred-lock armed (5s)")
                if needsZoomSnapBack {
                    do {
                        try device.lockForConfiguration()
                        if animated {
                            device.ramp(toVideoZoomFactor: targetZoom, withRate: rampRate * 2)
                        } else {
                            device.videoZoomFactor = targetZoom
                        }
                        self.currentZoomFactor = targetZoom
                        device.unlockForConfiguration()
                    } catch {
                        Log.session.error("focal_phase3_snapback_failed error=\(error.localizedDescription, privacy: .public)")
                    }
                }
                self.armDeferredLockToTarget(target.device, focalToken: myToken, timeoutSec: 5.0)
            }

            let active = activeBeforeLock?.localizedName ?? "nil"
            Log.session.info("focal_applied path=slow option=\(option.rawValue)mm target=\(target.device.localizedName, privacy: .public) active=\(active, privacy: .public) match=\(match) deep_ramp=\(needsDeepRamp) phase1_zoom=\(String(format: "%.2f", phase1Target))x final_zoom=\(String(format: "%.2f", device.videoZoomFactor))x animated=\(animated)")

            // Phase 3 之后再留 200ms grace 让 ZSL ring 收满新 constituent + 新 zoom 的帧再放行 capture
            // （constituent KVO 那条路径只覆盖 active 切到位的瞬间；这里覆盖 active 早就切到位
            // 但 KVO 没新通知的场景——拍摄前 active 一直没变，但锁刚生效 ring 还没刷新）
            try? await Task.sleep(for: .milliseconds(200))
            if self.applyFocalToken == myToken {
                self.markLensSettled(reason: "slow_path_complete")
            }
        }
    }

    // MARK: - 9. 拍照

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
        // 用户选 35mm 拍出来的照片元数据是 13mm UW 镜头。waitForLensSettled 上限兜底,
        // 不会让快门永久卡住。
        // 第二道闸门：slow-path mismatch 时不锁 constituent，保留 .auto；这里在 issue 前快速确认
        // active === expected。slow-path 的 deep-ramp 修复后正常情况下 0ms 就放行；只有极端情况
        // （deep ramp 也救不了的边界焦段）才会等满超时。从 800ms 缩到 200ms：mismatch 持续时
        // 用户感知"快门按了等近 1s 才闪"的延迟（用户原报问题），缩短后即便 mismatch 也只多 200ms。
        let initialIsLensTransitioning = isLensTransitioning
        Task { @MainActor [weak self] in
            guard let self else { return }
            if initialIsLensTransitioning {
                await self.waitForLensSettled()
            }
            await self.waitForConstituentMatch(timeoutMs: 200)
            self.issueCapturePhoto()
        }
    }

    /// capturePhoto 主体——拆出来是为了让外层 capturePhoto 能 await waitForLensSettled。
    /// 必须 @MainActor：访问 photoOutput / videoCaptureDevice / pendingFlashRestore / flashMode。
    private func issueCapturePhoto() {
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
            // 请求授权后等待 delegate 回调 didChangeAuthorization 再启动
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

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
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
