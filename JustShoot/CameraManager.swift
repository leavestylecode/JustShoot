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
// 主类声明 + 全部存储属性 + init/deinit + 帧状态。功能模块按文件拆分：
//   - CameraManager+Orientation.swift  方向监控 / EXIF 方向
//   - CameraManager+Session.swift       权限 / 配置 / KVO observers / 生命周期 / 诊断 dump
//   - CameraManager+Lens.swift          焦段切换（fast / slow path）+ 安全快门
//   - CameraManager+Capture.swift       对焦 / 曝光补偿 / 闪光 / capturePhoto + photo delegate
//   - CameraManager+Location.swift      GPS 缓存 + CLLocationManagerDelegate
//
// 注：跨文件 extension 需要访问同一类的属性，因此本文件内的存储属性大多以 `internal`
// （默认）声明而非 `private`。这是模块级访问，仍然不会暴露给其他模块。
@MainActor
class CameraManager: NSObject, ObservableObject {
    /// 虚拟设备 AVCaptureSession（iOS 26 推荐架构）：以 .builtInTripleCamera 等虚拟设备作为
    /// 单一 input；切焦距通过 setPrimaryConstituentDeviceSwitchingBehavior(.locked, ...) +
    /// videoZoomFactor 完成 — 系统在内部做硬件级 constituent 切换，预览不黑屏，无需 bridgeImage。
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    /// 当前 session 的虚拟（或物理）设备 input —— 整个生命周期只 add 一次，不 swap。
    var currentVideoInput: AVCaptureDeviceInput?
    /// 当前 video 设备（虚拟或物理）。focus / exposure / zoom 都打在它身上；
    /// constituent 切换由系统在内部完成，对外仍是同一个 device 实例。
    var videoCaptureDevice: AVCaptureDevice? { currentVideoInput?.device }
    let videoDataOutput = AVCaptureVideoDataOutput()
    let previewQueue = DispatchQueue(label: "preview.lut.queue")
    /// 专用会话队列（AVCaptureSession 操作必须在同一串行队列）
    let sessionQueue = DispatchQueue(label: "camera.session.queue")

    /// 线程安全的像素缓冲区（用 os_unfair_lock 保护跨线程访问）
    struct PreviewState: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var frameId: UInt64 = 0
    }
    let pixelBufferLock = OSAllocatedUnfairLock(initialState: PreviewState())

    /// 获取最新帧（用于 MTKView 渲染）
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

    /// 切焦距时用于丢弃过时回调的单调递增 token（用户快速来回点档位时旧任务不会把
    /// 新档位的 lock 撤掉）。
    var applyFocalToken: UInt64 = 0
    /// beginLensTransition 启动的 grace 超时 task；新一次进入或外部 markLensSettled 时取消旧的。
    var lensSettleTask: Task<Void, Never>?

    /// 弱引用 MTKView，用于从相机回调触发渲染
    weak var previewMTKView: MTKView?

    /// 首帧到达标记（线程安全，仅打印一次）
    let firstFrameFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
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

    // 预览方向缓存
    var previewRotationAngle: CGFloat?
    var previewDeviceOrientation: UIDeviceOrientation?
    var photoDataHandler: ((Data?) -> Void)?
    var exposureCompleteHandler: (() -> Void)?
    /// AVF 在主曝光（含闪光灯主脉冲）即将开始那一帧 fire 的回调，由
    /// `photoOutput(_:willCapturePhotoFor:)` 在 main actor 上派发。
    /// 用途：把屏幕白屏覆盖层与真实闪光灯同帧触发——这是 Apple 文档明确推荐的
    /// shutter visual feedback 挂载点，避免"UI 先闪、氙气灯后亮"的脱钩感。
    var willCaptureHandler: (() -> Void)?
    @Published var flashMode: FlashMode = .off

    // 震动反馈（预创建复用，减少首次延迟）
    let hapticLight = UIImpactFeedbackGenerator(style: .light)
    let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
    let hapticSoft = UIImpactFeedbackGenerator(style: .soft)

    // 等效焦距
    @Published var currentFocalLength: FocalLengthOption = .mm35
    @Published var focalInfo: DeviceFocalInfo = .placeholder
    @Published var currentZoomFactor: CGFloat = 1.0
    /// 当前实际激活的物理 constituent（KVO 自虚拟设备 activePrimaryConstituentDevice）。
    /// 用于诊断 .locked 是否真的把 constituent 钉住了；UI 不直接渲染。
    @Published var activeConstituentName: String = ""
    /// 镜头切换进行中（slow path Phase 0–3 + 200ms grace period）。
    /// **关键作用**：capturePhoto 在 issue 给 AVF 之前 await 此 flag 归 false——避免
    /// ZSL ring buffer 里上一颗 constituent 的旧帧被选作出片源。等效焦距 35mm 的照片在
    /// 元数据里"被报成 13mm 镜头拍摄"的根因，就是这个 race。Capture 内部由 waitForLensSettled
    /// 串行化，UI 不需要看；@Published 仍然便于调试 / 未来在 UI 加 spinner。
    @Published var isLensTransitioning: Bool = false
    /// 当前切换目标 constituent。constituentObservation 命中时（active === expected）即认为
    /// 镜头硬件已切到位，slow path Phase 3 lock 后再加 200ms grace 让 ZSL ring 完全换血。
    var expectedConstituent: AVCaptureDevice?
    var zoomObservation: NSKeyValueObservation?
    var constituentObservation: NSKeyValueObservation?
    var focalLengthPicker: AVCaptureIndexPicker?
    /// 系统级 EV 滑块（iOS 18+）。虚拟设备架构下 device 实例不变，整生命周期内只装一次。
    var exposureBiasSlider: AVCaptureSystemExposureBiasSlider?

    // 位置管理器
    let locationManager = CLLocationManager()
    var currentLocation: CLLocation?
    var locationCache: CLLocation?
    var locationCacheTime: Date = .distantPast
    let locationCacheExpiry: TimeInterval = 30.0

    // iOS 18 方向管理（每次 swap 后重建 RotationCoordinator）
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// KVO 监听 coordinator 的 horizon-level 角度。RotationCoordinator 初始值是 0，等运动数据
    /// 到位后才异步收敛——光在 configureAndStartSession 末尾同步读一次，会把错误角度写进 photo
    /// connection（用户横屏入页时，photoOutput.videoRotationAngle 会被钉死成默认值，出片永远是
    /// 错向）。Apple 在 RotationCoordinator 文档里就推荐 KVO 联动，每次值变就 reapply。
    var captureRotationObservation: NSKeyValueObservation?
    /// UI 端通过此值给悬浮控件（焦距条等）做 rotationEffect。app 整体 UI 锁竖屏，但用户横握时
    /// 控件需要随设备旋转保持"用户视角下水平"，对齐 iPhone Camera 体验。
    /// 注：原本 `private(set)`，跨文件 extension 写入 `private(set)` 受文件作用域限制。
    /// 改成普通 `@Published` 后，`updateOrientationFromAcceleration` 这类 extension 方法可直接写入；
    /// 模块外部仍只通过 ObservableObject 订阅，不会被错误改写。
    @Published var currentDeviceOrientation: UIDeviceOrientation = .portrait
    /// 直接读重力向量做方向判定。系统旋转锁开启时 UIDevice.orientationDidChange 会被节流甚至不发出，
    /// CMMotionManager 不受锁影响，与 iPhone Camera 保持一致——永远响应物理方向。
    let motionManager = CMMotionManager()
    var subjectAreaObserver: (any NSObjectProtocol)?
    var sessionInterruptionObserver: (any NSObjectProtocol)?
    var sessionInterruptionEndedObserver: (any NSObjectProtocol)?
    var sessionRuntimeErrorObserver: (any NSObjectProtocol)?
    /// session 是否已完成首次配置；区分"冷启动需要 configureAndStartSession"与"前台返回只 startRunning"
    var sessionConfigured: Bool = false
    /// 系统中断仍在进行中（来电/控制中心/录屏），interruptionEnded 后 resume
    var sessionInterrupted: Bool = false

    // 权限状态
    @Published var cameraPermissionDenied: Bool = false
    /// 定位权限被拒绝或受限时，UI 显示「位置已关闭」提示
    @Published var locationPermissionDenied: Bool = false

    /// 仅在值真正变化时写入 @Published 属性，避免无意义的 objectWillChange 发布
    func setCameraDenied(_ denied: Bool) {
        if cameraPermissionDenied != denied { cameraPermissionDenied = denied }
    }
    func setLocationDenied(_ denied: Bool) {
        if locationPermissionDenied != denied { locationPermissionDenied = denied }
    }

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
    struct FlashRestoreState {
        let exposureTargetBias: Float
        let wbMode: AVCaptureDevice.WhiteBalanceMode
        let lockedExposure: Bool
        let lockedWB: Bool
    }
    var pendingFlashRestore: FlashRestoreState?
    var focusHoldTimer: Timer?
    let tapFocusHoldDuration: TimeInterval = 3.0
    var focusObservation: NSKeyValueObservation?
    var pressureObservation: NSKeyValueObservation?
    /// 进入相机时启动 session 的任务句柄；离开时取消，避免在 sessionQueue 上做完整 startRunning 后又被立即停止
    var startupTask: Task<Void, Never>?
    /// 正常情况下的目标帧率；由 sessionQueue 写入、压力回调 KVO 读取，用锁保护避免数据竞争
    let nominalFPSLock = OSAllocatedUnfairLock<Double>(initialState: 30.0)
    @Published var isFocusLocked = false
    /// 用户曝光补偿（EV）。tap-to-focus 后上下滑动手势驱动；focus 释放（timer / subject-area）时归零。
    /// 与 device.exposureTargetBias 镜像同步——后者在 flash capture 路径里会被临时改写，但 capture
    /// 完成后会通过 pendingFlashRestore 恢复，对外表现仍等于这里。
    @Published var exposureBias: Float = 0

    /// 虚拟（或物理）设备 — 整个生命周期固定，不 swap。constituent 由系统按 zoom + .locked
    /// 在内部切换。session 配置完成前为 nil。
    var captureDevice: AVCaptureDevice?

    /// AVF 对象 + main-actor 状态打包后跨 actor 边界传递。
    /// 这些 NSObject 在 dumpLensSpecsImpl 里只读 nonisolated 属性，与主 actor 写入无并发；
    /// `@unchecked Sendable` 表达"语义上 Sendable，但编译器无法证明"。
    struct LensDumpArgs: @unchecked Sendable {
        let device: AVCaptureDevice
        let focalInfo: DeviceFocalInfo
        let photoOutput: AVCapturePhotoOutput
        let videoDataOutput: AVCaptureVideoDataOutput
    }

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
    static func discoverBestCaptureDevice() -> AVCaptureDevice? {
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
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate（实时预览样本帧）
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    @preconcurrency nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        self.setLatestPixelBuffer(buffer)
        self.logFirstFrameOnce(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        // 事件驱动：新帧到达时触发 MTKView 重绘（替代定时器轮询）
        DispatchQueue.main.async { [weak self] in
            self?.previewMTKView?.setNeedsDisplay()
        }
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
