import SwiftUI
import AVFoundation
import SwiftData
import CoreLocation
import UIKit
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit

struct CameraView: View {
    let preset: FilmPreset
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Roll.createdAt, order: .reverse) private var rolls: [Roll]
    @StateObject private var cameraManager: CameraManager
    @State private var showFlash = false
    @State private var exposuresRemaining: Int = 27
    @State private var currentRoll: Roll?
    @State private var isProcessingCapture: Bool = false
    
    init(preset: FilmPreset) {
        self.preset = preset
        _cameraManager = StateObject(wrappedValue: CameraManager(preset: preset))
    }

    var body: some View {
            ZStack {
            // 背景：质感黑色（多层渐变叠加）
            ZStack {
                Color.black
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部：左上返回（放大） + 右上剩余次数
                HStack(alignment: .center) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Circle())
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Text("EXP")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("\(exposuresRemaining)")
                            .font(.system(size: 18, weight: .heavy))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer(minLength: 8)

                // 中间预览区：3:4 固定取景框（红色边框）
                GeometryReader { _ in
                    // 实时预览（应用 LUT）
                    RealtimePreviewView(manager: cameraManager, preset: preset)
                        // 去掉外层边框/描边/阴影
                }
                .aspectRatio(3/4, contentMode: .fit)
                // 取消左右留白，保证预览填满可用宽度，与成片观感一致

                Spacer(minLength: 8)

                // 底部：左侧闪光 + 中间快门
                ZStack {
                    // 中间快门（绿色）
                    Button(action: { capturePhoto() }) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.18, green: 0.80, blue: 0.36))
                                .frame(width: 82, height: 82)
                                .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 6)
                            Circle()
                                .stroke(Color.black.opacity(0.6), lineWidth: 3)
                                .frame(width: 70, height: 70)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessingCapture)
                    .opacity(isProcessingCapture ? 0.5 : 1.0)

                    // 左侧闪光按钮
                    HStack {
                        Button(action: { cameraManager.toggleFlashMode() }) {
                            let isOn = cameraManager.flashMode == .on
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(isOn ? Color.black : Color.white)
                                .frame(width: 40, height: 40)
                                .background(isOn ? Color.yellow : Color.white.opacity(0.10))
                                .clipShape(Circle())
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
                
                Spacer(minLength: 8)
            }

            // 闪光效果
            if showFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.85)
                    .animation(.easeInOut(duration: 0.1), value: showFlash)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            // 预加载 LUT，提升首次拍摄速度
            FilmProcessor.shared.preload(preset: preset)
            cameraManager.requestCameraPermission()
            prepareCurrentRoll()
            updateExposuresRemaining()
        }
        .onDisappear { cameraManager.stopLocationServices() }
    }
    
    private func capturePhoto() {
        // 若正在处理上一张，则不允许继续拍摄
        if isProcessingCapture {
            print("⏳ [Capture] 上一次照片仍在处理，忽略本次快门")
            return
        }
        print("📸 [Capture] 请求拍照，设置处理锁 isProcessingCapture=true")
        isProcessingCapture = true
        showFlash = true

        cameraManager.capturePhoto { imageData in
            DispatchQueue.main.async {
                print("📸 [Capture] didFinishProcessingPhoto 回调")
                if let data = imageData {
                    // 立即结束快门动画
                    showFlash = false
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    print("📦 [Capture] 获取到照片数据 bytes=\(data.count)")
                    
                    // 后台应用 LUT 并保存，提升响应（降低优先级，减少与预览争用）
                    Task.detached(priority: .utility) { [imageData = data, preset = preset] in
                        print("🧪 [Process] 开始后台处理(LUT+元数据+保存)...")
                        // 若定位为空，主动等待一条新鲜定位（最多1.5s）
                        print("📍 [GPS] 请求新定位(<=1.5s)...")
                        var tmpLoc = await cameraManager.fetchFreshLocation()
                        // 日志精简：不再打印 snapshot 细节
                        // 再尝试一次，保证覆盖首次回调之后的场景
                        if tmpLoc == nil {
                            print("📍 [GPS] 首次定位为空，继续短轮询(<=1.0s)...")
                            tmpLoc = await cameraManager.fetchFreshLocation(timeout: 1.0)
                        }
                        let finalLocation = tmpLoc
                        if let loc = finalLocation {
                            print(String(format: "📍 [GPS] 获取到定位 lat=%.6f lon=%.6f", loc.coordinate.latitude, loc.coordinate.longitude))
                        } else {
                            print("📍 [GPS] 未获取到有效定位，将不写入GPS")
                        }
                        print("🎨 [Process] 开始渲染与写入元数据...")
                        let processedData: Data = autoreleasepool {
                            FilmProcessor.shared.applyLUTPreservingMetadata(imageData: imageData, preset: preset, outputQuality: 0.90, location: finalLocation) ?? imageData
                        }
                        print("🎨 [Process] 渲染完成，输出 bytes=\(processedData.count)")
                        // 打印处理后 JPEG 的 EXIF/GPS
                        // 生产环境不再打印 EXIF GPS
                        await MainActor.run {
                            print("💾 [DB] 准备写入 SwiftData 模型...")
                            if currentRoll == nil || (currentRoll?.isCompleted ?? true) {
                                currentRoll = createOrFetchActiveRoll()
                                print("🎞️ [Roll] 使用活动胶卷 id=\(currentRoll?.id.uuidString ?? "nil")")
                            }
                            let newPhoto = Photo(imageData: processedData, filmPresetName: preset.rawValue)
                            if let loc = finalLocation {
                                newPhoto.latitude = loc.coordinate.latitude
                                newPhoto.longitude = loc.coordinate.longitude
                                newPhoto.altitude = loc.altitude
                                newPhoto.locationTimestamp = loc.timestamp
                            } else {
                                // 无可用位置则跳过
                            }
                            newPhoto.roll = currentRoll
                            modelContext.insert(newPhoto)
                            do {
                                try modelContext.save()
                                print("✅ [DB] Photo saved successfully")
                                updateExposuresRemaining()
                                if currentRoll?.isCompleted == true {
                                    print("🎞️ 胶卷已拍完 \(currentRoll?.capacity ?? 27) 张，自动完成")
                                }
                            } catch {
                                print("❌ [DB] Failed to save photo: \(error)")
                            }
                            // 完整处理与保存结束，解除拍摄锁
                            print("🔓 [Lock] 解除处理锁 isProcessingCapture=false")
                            isProcessingCapture = false
                        }
                    }
                } else {
                    // 获取图像数据失败，解除拍摄锁与闪光覆盖
                    showFlash = false
                    print("❌ [Capture] 未获取到照片数据，解除处理锁")
                    isProcessingCapture = false
                }
                // 移除自动返回，让用户自己决定何时返回
            }
        }
    }

    private func prepareCurrentRoll() {
        if let active = rolls.first(where: { $0.presetName == preset.rawValue && !$0.isCompleted }) {
            currentRoll = active
        } else {
            currentRoll = createOrFetchActiveRoll()
        }
    }

    private func createOrFetchActiveRoll() -> Roll {
        if let active = rolls.first(where: { $0.presetName == preset.rawValue && !$0.isCompleted }) {
            return active
        }
        let newRoll = Roll(preset: preset, capacity: 27)
        modelContext.insert(newRoll)
        do { try modelContext.save() } catch { print("保存新胶卷失败: \(error)") }
        return newRoll
    }

    private func updateExposuresRemaining() {
        if let active = rolls.first(where: { $0.presetName == preset.rawValue && !$0.isCompleted }) {
            exposuresRemaining = active.exposuresRemaining
            currentRoll = active
            if active.isCompleted && active.completedAt == nil {
                active.completedAt = Date()
            }
        } else if let current = currentRoll {
            exposuresRemaining = current.exposuresRemaining
        } else {
            exposuresRemaining = 27
        }
    }
    
    // 固定焦距为 35mm，不提供 UI 调整
    @MainActor
    private func setFocus(at point: CGPoint) {
        // 保留占位（已改由 GeometryReader 内部计算设备坐标并调用）
        cameraManager.setFocusAndExposure(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
    }
}

    

// 相机预览视图
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor.black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect // 与4:3容器保持一致不裁切
        
        view.layer.addSublayer(previewLayer)
        
        // 存储预览层以便后续更新
        view.layer.setValue(previewLayer, forKey: "previewLayer")
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // 更新预览层的frame以匹配视图的边界
        if let previewLayer = uiView.layer.value(forKey: "previewLayer") as? AVCaptureVideoPreviewLayer {
            DispatchQueue.main.async {
                previewLayer.frame = uiView.bounds
            }
        }
    }
}

// 相机管理器
// 闪光灯模式枚举
enum FlashMode: String, CaseIterable {
    case on = "on" 
    case off = "off"
    
    var displayName: String {
        switch self {
        case .on: return "开启"
        case .off: return "关闭"
        }
    }
    
    var iconName: String {
        switch self {
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        }
    }
    
    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .on: return .on
        case .off: return .off
        }
    }
}

@MainActor
class CameraManager: NSObject, ObservableObject {
    private let preset: FilmPreset
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var videoCaptureDevice: AVCaptureDevice?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
    private let previewQueue = DispatchQueue(label: "preview.lut.queue")
    fileprivate var latestPixelBuffer: CVPixelBuffer?
    // 预览方向缓存，供渲染线程读取（避免在渲染线程中做 async 查询）
    fileprivate var previewRotationAngle: CGFloat?
    fileprivate var previewDeviceOrientation: UIDeviceOrientation?
    // 用于点击坐标到相机坐标的换算（不显示在界面上）
    private var conversionPreviewLayer: AVCaptureVideoPreviewLayer?
    private var photoDataHandler: ((Data?) -> Void)?
    @Published var flashMode: FlashMode = .off
    
    // 35mm等效焦距相关属性
    private var devicePhysicalFocalLength: Float = 0.0 // 设备物理焦距
    private var device35mmEquivalentFocalLength: Float = 0.0 // 设备35mm等效焦距
    @Published var targetFocalLength: Float = 35.0 // 目标35mm等效焦距
    @Published var currentZoomFactor: CGFloat = 1.0 // 当前变焦系数
    private var requiredZoomFactor: CGFloat = 1.0 // 达到35mm所需的变焦系数
    
    // 焦距调整范围
    private let minFocalLength: Float = 24.0 // 最小35mm等效焦距
    private let maxFocalLength: Float = 85.0 // 最大35mm等效焦距
    
    // 位置管理器
    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    // 等待一次新定位的挂起请求
    private var pendingLocationRequests: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
    @MainActor
    func currentLocationSnapshot() -> CLLocation? {
        return currentLocation
    }

    // 等待一条新鲜定位（若已有较新的，直接返回），带超时（轮询实现，避免并发警告）
    func fetchFreshLocation(timeout: TimeInterval = 1.5, freshness: TimeInterval = 10.0) async -> CLLocation? {
        if let loc = currentLocation, Date().timeIntervalSince(loc.timestamp) < freshness {
            return loc
        }
        locationManager.requestLocation()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let loc = currentLocation, Date().timeIntervalSince(loc.timestamp) < freshness {
                return loc
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        return currentLocation
    }
    
    // 方向管理 - iOS 17新方式
    @available(iOS 17.0, *)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
    // 兼容旧版本的方向管理
    private var currentDeviceOrientation: UIDeviceOrientation = .portrait
    private var orientationObserver: NSObjectProtocol?
    private var subjectAreaObserver: NSObjectProtocol?

    // 固定 ISO 配置（随胶片预设）
    @Published var isISOLocked: Bool = false
    private var fixedISOValue: Float
    private var lastISOAdjustTime: Date = .distantPast
    private let isoAdjustThrottle: TimeInterval = 2.0
    private var lastLogTime: Date = .distantPast
    private var lastAppliedISO: Float?
    private var lastAppliedExposureSeconds: Double?
    // 位置日志节流
    private var lastLocationLogTime: Date = .distantPast
    private var lastLoggedLocation: CLLocation?

    // 自动测光定时器（在固定 ISO 前提下，周期性基于测光调整快门）
    private var exposureMeterTimer: Timer?
    // 拍照前的曝光补偿记录（用于拍后恢复）
    private var previousExposureTargetBias: Float = 0
    // 标记是否为闪光拍摄短暂锁定了曝光
    private var lockedExposureForFlashCapture: Bool = false
    // 点击对焦保持计时
    private var focusHoldTimer: Timer?
    private let tapFocusHoldDuration: TimeInterval = 3.0
    
    init(preset: FilmPreset) {
        self.preset = preset
        self.fixedISOValue = 0
        super.init()
        setupCamera()
        setupOrientationMonitoring()
    }
    //（已弃用）点击对焦坐标换算
    
    deinit {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let subjectObserver = subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectObserver)
        }
    }
    
    // 设置设备方向监控
    private func setupOrientationMonitoring() {
        // 启用设备方向更新
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // 监听方向变化
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDeviceOrientation()
            }
        }
        
        // 初始化当前方向
        updateDeviceOrientation()
    }
    
    // 更新设备方向
    private func updateDeviceOrientation() {
        let orientation = UIDevice.current.orientation
        
        // 只处理有效的方向
        if orientation.isValidInterfaceOrientation {
            currentDeviceOrientation = orientation
            print("📱 设备方向更新: \(orientationDescription(orientation))")
            applyVideoOrientationToOutputs()
        }
    }
    
    // 方向描述
    private func orientationDescription(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "Portrait"
        case .portraitUpsideDown: return "Portrait Upside Down"
        case .landscapeLeft: return "Landscape Left"
        case .landscapeRight: return "Landscape Right"
        default: return "Unknown"
        }
    }
    
    // 兼容旧版本：仅缓存设备方向，由渲染与EXIF写入处理方向
    // 不再使用已废弃的 AVCaptureConnection.videoOrientation

    // 同步当前方向到预览/拍照输出连接
    private func applyVideoOrientationToOutputs() {
        if #available(iOS 17.0, *) {
            if let coordinator = rotationCoordinator {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                // 仅为拍照输出设置角度，避免实时预览重复旋转
                if let pconn = photoOutput.connection(with: .video), pconn.isVideoRotationAngleSupported(angle) {
                    // 仅在不同才设置，避免无意义调用
                    if abs(pconn.videoRotationAngle - angle) > 0.5 {
                        pconn.videoRotationAngle = angle
                    }
                }
                if let lconn = conversionPreviewLayer?.connection, lconn.isVideoRotationAngleSupported(angle) {
                    if abs(lconn.videoRotationAngle - angle) > 0.5 {
                        lconn.videoRotationAngle = angle
                    }
                }
                // 缓存给渲染线程使用
                self.previewRotationAngle = angle
                return
            }
        }
        // 旧系统分支（或无 rotationCoordinator）
        let dev = currentDeviceOrientation
        // 仅缓存设备方向，渲染时根据缓存旋转图像；不再设置已废弃的 connection.videoOrientation
        self.previewRotationAngle = nil
        self.previewDeviceOrientation = dev
    }

    private func applyLegacyVideoOrientationToOutputs() { }

    // rotationInfoForPreview 已不再需要（使用缓存属性）

    // （已改为全自动对焦，保留空实现以避免调用方改动）
    @MainActor
    func setFocusAndExposure(normalizedPoint: CGPoint) {}

    // 按距离估算手电筒亮度，并开启；返回是否启用
    @MainActor
    func enableAutoTorchForCapture() -> Bool {
        guard let device = videoCaptureDevice, device.hasTorch else { return false }
        // 仅根据被摄物体远近（镜头位置）控制强度：
        // 期望区间（建议）：>3m≈全开(1.0)，2~3m≈0.8，1~2m≈0.6，<1m≈0.4
        // 说明：lensPosition 为对焦位置的近似，0≈近、1≈远，不同机型非线性；阈值为经验值，可后续调优
        let lensPos = max(0.0, min(1.0, CGFloat(device.lensPosition)))
        // 经验阈值（可按机型微调）
        let near1: CGFloat = 0.20  // ~1m 内
        let near2: CGFloat = 0.45  // ~1-2m
        let near3: CGFloat = 0.70  // ~2-3m
        let level: CGFloat
        if lensPos <= near1 {
            level = 0.40
        } else if lensPos <= near2 {
            level = 0.60
        } else if lensPos <= near3 {
            level = 0.80
        } else {
            level = 1.00
        }
        print("🔦 Torch: lensPos=\(String(format: "%.3f", lensPos)) → level=\(String(format: "%.2f", level)))")
        do {
            try device.lockForConfiguration()
            try device.setTorchModeOn(level: Float(level))
            device.unlockForConfiguration()
            return true
        } catch {
            print("⚠️ 开启手电筒失败: \(error)")
            return false
        }
    }
    
    // iOS 17新方式：从旋转角度转换为EXIF方向值
    @available(iOS 17.0, *)
    private func exifOrientationFromRotationAngle(_ rotationAngle: CGFloat) -> Int {
        let normalizedAngle = Int(rotationAngle) % 360
        switch normalizedAngle {
        case 0:
            return 1    // 正常方向 0°
        case 90, -270:
            return 6    // 逆时针旋转90度
        case 180, -180:
            return 3    // 旋转180度
        case 270, -90:
            return 8    // 顺时针旋转90度
        default:
            return 1    // 默认为正常方向
        }
    }
    
    // 兼容旧版本：转换设备方向为EXIF方向值
    private func exifOrientation(from deviceOrientation: UIDeviceOrientation) -> Int {
        switch deviceOrientation {
        case .portrait:
            return 1    // 正常竖屏
        case .landscapeLeft:
            return 6    // 向左旋转90度
        case .portraitUpsideDown:
            return 3    // 旋转180度
        case .landscapeRight:
            return 8    // 向右旋转90度
        default:
            return 1    // 默认为正常方向
        }
    }
    
    func requestCameraPermission() {
        Task {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch status {
        case .authorized:
                await startSession()
                startLocationServices() // 仅在相机启动时开启GPS
        case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                    if granted {
                    await startSession()
                    startLocationServices() // 仅在相机启动时开启GPS
                }
            default:
                break
            }
        }
    }
    
    private func setupCamera() {
        // 设置为高质量照片（稍后在capture时指定3:4尺寸）
        session.sessionPreset = .photo
        
        guard let videoCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Failed to get camera device")
            return
        }
        
        self.videoCaptureDevice = videoCaptureDevice
        
        // 读取设备焦距信息
        readCameraSpecs(device: videoCaptureDevice)
        
        // 优先选择 4:3 的 activeFormat，确保视频帧与成片一致的视角/FOV
        setDeviceToBest4by3Format(videoCaptureDevice)

            // 固定 35mm 等效焦距
            calculateZoomFactorFor35mm()
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
            
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                
                // iOS 17 新特性：优先速度；设置 rotation coordinator
                if #available(iOS 17.0, *) {
                    photoOutput.maxPhotoQualityPrioritization = .speed
                    rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: videoCaptureDevice, previewLayer: nil)
                    print("📱 使用iOS 17 AVCaptureDevice.RotationCoordinator")
                }
                // 关闭高分辨率拍照（iOS 16以下可用），iOS16+ 使用 maxPhotoDimensions 策略
                if #unavailable(iOS 16.0) {
                    photoOutput.isHighResolutionCaptureEnabled = false
                }
            }

            // 实时预览数据输出（供 CI 管线使用）
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                videoDataOutput.setSampleBufferDelegate(self, queue: previewQueue)
                applyVideoOrientationToOutputs()
            }

            // 全自动对焦/曝光默认配置
            try videoCaptureDevice.lockForConfiguration()
            if videoCaptureDevice.isFocusModeSupported(.continuousAutoFocus) {
                videoCaptureDevice.focusMode = .continuousAutoFocus
            }
            if videoCaptureDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoCaptureDevice.exposureMode = .continuousAutoExposure
            }
            if videoCaptureDevice.isSmoothAutoFocusSupported {
                videoCaptureDevice.isSmoothAutoFocusEnabled = true
            }
            videoCaptureDevice.unlockForConfiguration()

            // 启用主体区域变化监控（自动对焦时更灵敏）
            try videoCaptureDevice.lockForConfiguration()
            if videoCaptureDevice.isSubjectAreaChangeMonitoringEnabled == false {
                videoCaptureDevice.isSubjectAreaChangeMonitoringEnabled = true
            }
            // 初始使用连续自动曝光以便测光
            if videoCaptureDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoCaptureDevice.exposureMode = .continuousAutoExposure
            }
            videoCaptureDevice.unlockForConfiguration()
            
            subjectAreaObserver = NotificationCenter.default.addObserver(
                forName: .AVCaptureDeviceSubjectAreaDidChange,
                object: videoCaptureDevice,
                queue: .main
            ) { _ in }
        } catch {
            print("Error setting up camera: \(error)")
        }
    }

    // 选择并设置 4:3 的最高分辨率格式，保证预览帧比例与成片一致
    private func setDeviceToBest4by3Format(_ device: AVCaptureDevice) {
        var bestFormat: AVCaptureDevice.Format?
        var bestArea: Int32 = 0
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let w = Int32(dims.width)
            let h = Int32(dims.height)
            guard w > 0 && h > 0 else { continue }
            let ratio = Double(w) / Double(h)
            // 容差 1% 认为是 4:3
            if abs(ratio - (4.0/3.0)) > 0.01 { continue }
            // 需支持至少 30fps
            let supports30fps = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30.0 }
            guard supports30fps else { continue }
            let area = w * h
            if area > bestArea { bestArea = area; bestFormat = format }
        }
        guard let best = bestFormat else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            if let range = best.videoSupportedFrameRateRanges.first {
                let desired = min(30.0, range.maxFrameRate)
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desired))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desired))
            }
            device.unlockForConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            print("📸 设定4:3 activeFormat: \(dims.width)x\(dims.height)")
        } catch {
            print("⚠️ 设置4:3 activeFormat失败: \(error)")
        }
    }
    
    private func startSession() async {
        guard !session.isRunning else { return }
        
        // 在后台线程启动相机会话，避免阻塞主线程
        await Task.detached { [weak self] in
            await self?.session.startRunning()
        }.value
        // 会话启动后再次应用 35mm 等效变焦，确保生效
        await MainActor.run {
            self.calculateZoomFactorFor35mm()
            self.applyVideoOrientationToOutputs()
        }
    }
    
    @MainActor
    func capturePhoto(completion: @escaping (Data?) -> Void) {
        photoDataHandler = completion
        
        let settings = AVCapturePhotoSettings()
        
        // iOS 17 优化：优先速度
        if #available(iOS 17.0, *) {
            settings.photoQualityPrioritization = .speed
        }
        // 关闭高分辨率拍照（iOS 16以下可用），iOS16+ 使用 maxPhotoDimensions 策略
        if #unavailable(iOS 16.0) {
            settings.isHighResolutionPhotoEnabled = false
        }
        
        // 闪光灯/手电筒策略：若开启，按距离(对焦位置)估算手电筒强度，使用持续光代替一次性闪光
        // 使用真实闪光灯（不再用手电筒模拟），并在拍照前按距离设置曝光补偿以间接控制闪光效果
        if let device = videoCaptureDevice, device.hasFlash {
            settings.flashMode = (flashMode == .on) ? .on : .off
            if flashMode == .on {
                // 依据对焦远近设置曝光偏置（6段更强烈），并短暂锁曝光后再拍
                // lensPosition: 0≈近, 1≈远；阈值与偏置为经验值，可后续机型调优
                let lensPos = max(0.0, min(1.0, device.lensPosition))
                let bias: Float
                if lensPos < 0.10 {           // 近到极近
                    bias = -0.8
                } else if lensPos < 0.25 {    // 近
                    bias = -0.4
                } else if lensPos < 0.50 {    // 中近
                    bias = -0.1
                } else if lensPos < 0.75 {    // 中远
                    bias = 0.2
                } else if lensPos < 0.85 {    // 远
                    bias = 0.5
                } else {                       // 极远
                    bias = 0.7
                }
                do {
                    try device.lockForConfiguration()
                    previousExposureTargetBias = device.exposureTargetBias
                    let clamped = clamp(bias, min: device.minExposureTargetBias, max: device.maxExposureTargetBias)
                    device.setExposureTargetBias(clamped) { _ in }
                    // 短暂锁定曝光，避免 AE 立刻抵消偏置
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                        lockedExposureForFlashCapture = true
                    }
                    device.unlockForConfiguration()
                    print(String(format: "⚡️ Flash PreBias: lensPos=%.3f → bias=%.2f (range %.1f..%.1f)", lensPos, bias, device.minExposureTargetBias, device.maxExposureTargetBias))
                } catch {
                    print("⚠️ 设置曝光偏置失败: \(error)")
                }
            }
        }
        
        // 启用完整的元数据保留
        settings.embedsDepthDataInPhoto = false
        settings.embedsPortraitEffectsMatteInPhoto = false
        settings.embedsSemanticSegmentationMattesInPhoto = false
        
        // 让系统自动选择最合适尺寸以获得更好的响应速度
        
        // 设置照片方向 - iOS 17新方式 vs 旧版本兼容
        if #available(iOS 17.0, *) {
            // 使用iOS 17的新API
            if let coordinator = rotationCoordinator,
               let connection = photoOutput.connection(with: .video) {
                let rotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    if connection.videoRotationAngle != rotationAngle {
                        connection.videoRotationAngle = rotationAngle
                    }
                    print("📱 iOS 17设置照片旋转角度: \(rotationAngle)°")
                } else {
                    print("⚠️ 设备不支持该旋转角度: \(rotationAngle)°")
                }
            }
        } else {
            // 兼容iOS 16及以下版本：不再设置已废弃的 videoOrientation，仅依赖渲染与EXIF缓存
        }
        
        // 添加位置信息到照片设置中
        if let location = currentLocation {
            print("📍 添加GPS位置信息: \(location.coordinate)")
        }
        
        // 若进行了曝光锁定，延迟短暂时间再触发拍照
        if lockedExposureForFlashCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        } else {
            photoOutput.capturePhoto(with: settings, delegate: self)
        }

        // 拍完在代理回调里关闭手电筒（见下）
    }
    
    func toggleFlashMode() {
        let modes = FlashMode.allCases
        if let currentIndex = modes.firstIndex(of: flashMode) {
            let nextIndex = (currentIndex + 1) % modes.count
            flashMode = modes[nextIndex]
        }
    }
    
    // MARK: - 35mm等效焦距相关方法
    
    // 读取相机规格信息
    private func readCameraSpecs(device: AVCaptureDevice) {
        // 获取设备的物理焦距（通常在镜头信息中）
        let lensPosition = device.lensPosition
        print("📷 镜头位置: \(lensPosition)")
        
        // 获取设备的35mm等效焦距信息
        // iPhone的主摄通常有固定的35mm等效焦距值
        let deviceModel = getModelIdentifier()
        let systemVersion = UIDevice.current.systemVersion
        
        print("📱 设备型号: \(deviceModel)")
        print("📱 系统版本: \(systemVersion)")
        
        // 根据设备型号推断35mm等效焦距
        // 这些值基于苹果官方规格
        device35mmEquivalentFocalLength = estimate35mmEquivalentFocalLength()
        devicePhysicalFocalLength = estimatePhysicalFocalLength()
        
        print("📏 设备物理焦距: \(devicePhysicalFocalLength)mm")
        print("📏 设备35mm等效焦距: \(device35mmEquivalentFocalLength)mm")
        print("🎯 目标35mm等效焦距: \(targetFocalLength)mm")
    }
    
    // 估算设备的35mm等效焦距
    private func estimate35mmEquivalentFocalLength() -> Float {
        let modelName = getModelIdentifier()
        print("📱 设备标识符/名称: \(modelName)")

        // 基于机型的主摄等效焦距近似（不足以严谨，但足够用于设定目标视角）
        // 16 Pro 系列主摄 24mm；16 非 Pro 为 26mm
        // 15 Pro 系列主摄 24mm；大多数 12/13/14/15 非 Pro 为 26mm；更老设备多为 28mm
        let name = modelName
        if name.contains("16 Pro") { return 24.0 }
        if name.contains("16") { return 26.0 }
        if name.contains("15 Pro") { return 24.0 }
        if name.contains("15") { return 26.0 }
        if name.contains("14") || name.contains("13") || name.contains("12") || name.contains("11") || name.contains("XS") || name.contains("XR") || name.contains(" iPhone X") { return 26.0 }
        if name.contains("8") || name.contains("7") || name.contains("6") { return 28.0 }
        // 模拟器或未知机型
        return 26.0
    }
    
    // 获取精确的设备型号标识符
    private func getModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(Character(UnicodeScalar(UInt8(value))))
        }
        
        // 使用简化方式检测模拟器
        #if targetEnvironment(simulator)
        return "iPhone 15 Pro (Simulator)"
        #else
        return deviceModelName(from: identifier)
        #endif
    }
    
    // 将设备标识符转换为可读的设备名称
    private func deviceModelName(from identifier: String) -> String {
        switch identifier {
        // iPhone 16 系列（推测的标识符）
        case "iPhone17,1": return "iPhone 16"
        case "iPhone17,2": return "iPhone 16 Plus"
        case "iPhone17,3": return "iPhone 16 Pro"
        case "iPhone17,4": return "iPhone 16 Pro Max"
        
        // iPhone 15 系列
        case "iPhone16,1": return "iPhone 15"
        case "iPhone16,2": return "iPhone 15 Plus"
        case "iPhone16,3": return "iPhone 15 Pro"
        case "iPhone16,4": return "iPhone 15 Pro Max"
            
        // iPhone 14 系列
        case "iPhone15,4": return "iPhone 14"
        case "iPhone15,5": return "iPhone 14 Plus"
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
            
        // iPhone 13 系列
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,6": return "iPhone 13 Pro"
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
            
        // iPhone 12 系列
        case "iPhone13,1": return "iPhone 12 mini"
        case "iPhone13,2": return "iPhone 12"
        case "iPhone13,3": return "iPhone 12 Pro"
        case "iPhone13,4": return "iPhone 12 Pro Max"
            
        // iPhone 11 系列
        case "iPhone12,1": return "iPhone 11"
        case "iPhone12,3": return "iPhone 11 Pro"
        case "iPhone12,5": return "iPhone 11 Pro Max"
            
        // iPhone X 系列
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "iPhone11,8": return "iPhone XR"
        case "iPhone10,3", "iPhone10,6": return "iPhone X"
            
        // 较老的iPhone型号
        case "iPhone10,1", "iPhone10,4": return "iPhone 8"
        case "iPhone10,2", "iPhone10,5": return "iPhone 8 Plus"
        case "iPhone9,1", "iPhone9,3": return "iPhone 7"
        case "iPhone9,2", "iPhone9,4": return "iPhone 7 Plus"
        case "iPhone8,1": return "iPhone 6s"
        case "iPhone8,2": return "iPhone 6s Plus"
        case "iPhone7,2": return "iPhone 6"
        case "iPhone7,1": return "iPhone 6 Plus"
            
        default:
            // 如果没有匹配到具体型号，返回通用名称
            return "iPhone (\(identifier))"
        }
    }
    
    // 估算设备的物理焦距
    private func estimatePhysicalFocalLength() -> Float {
        // iPhone的物理焦距通常在5-7mm之间
        // 这个值主要用于计算，实际焦距信息较难直接获取
        return 6.0 // 典型的iPhone主摄物理焦距
    }
    
    // 计算达到35mm等效焦距所需的变焦系数
    private func calculateZoomFactorFor35mm() {
        guard let device = videoCaptureDevice else { return }
        // 尽可能用设备提供的 35mm 等效信息，回退 26mm
        let baseEquivalent: Float = device35mmEquivalentFocalLength > 0 ? device35mmEquivalentFocalLength : 26.0
        requiredZoomFactor = CGFloat(targetFocalLength / baseEquivalent)

        let maxZoom = device.activeFormat.videoMaxZoomFactor
        let minZoom = device.minAvailableVideoZoomFactor
        requiredZoomFactor = max(minZoom, min(maxZoom, requiredZoomFactor))

        applyZoomFactor(requiredZoomFactor)
    }
    
    // 应用变焦系数
    private func applyZoomFactor(_ zoomFactor: CGFloat) {
        guard let device = videoCaptureDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = zoomFactor
            currentZoomFactor = zoomFactor
            device.unlockForConfiguration()
            
            print("✅ 固定35mm等效焦距，变焦系数: \(String(format: "%.2f", zoomFactor))x")
        } catch {
            print("❌ 应用变焦失败: \(error)")
        }
    }

    // MARK: - 固定 ISO 400 逻辑
    private func scheduleReapplyFixedISO(initial: Bool = false) { }

    private func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        return max(minValue, min(maxValue, value))
    }

    private func cmTime(fromSeconds seconds: Double) -> CMTime {
        return CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000_000)
    }

    private func exposureSeconds(_ time: CMTime) -> Double {
        guard time.timescale != 0 else { return 0 }
        return Double(time.value) / Double(time.timescale)
    }

    private func applyFixedISOAfterAutoMetering() async { }

    // 对外暴露一次性强制应用固定 ISO（拍照前调用）
    func forceApplyFixedISO() async { }
    
    // 调整目标焦距
    func adjustTargetFocalLength(_ newFocalLength: Float) {
        // 限制焦距范围
        let clampedFocalLength = max(minFocalLength, min(maxFocalLength, newFocalLength))
        targetFocalLength = clampedFocalLength
        
        // 重新计算并应用变焦系数
        calculateZoomFactorFor35mm()
        
        print("🎯 调整目标焦距为: \(String(format: "%.0f", targetFocalLength))mm")
    }
    
    // 启动位置服务（仅在拍摄页面）
    private func startLocationServices() {
        print("📍 启动GPS位置服务（拍摄模式）")
        
        // 配置位置管理器
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
        
        // 请求授权；若已授权，立即启动更新与一次性请求
        locationManager.requestWhenInUseAuthorization()
        if #available(iOS 14.0, *) {
            let status = locationManager.authorizationStatus
            print("📍 当前定位授权状态: \(authorizationStatusDescription(status))")
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                startLocationUpdates()
                Task { @MainActor in self.locationManager.requestLocation() }
            case .notDetermined, .denied, .restricted:
                break
            @unknown default:
                break
            }
        } else {
            let status = CLLocationManager.authorizationStatus()
            print("📍 当前定位授权状态(legacy): \(authorizationStatusDescription(status))")
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                startLocationUpdates()
                Task { @MainActor in self.locationManager.requestLocation() }
            case .notDetermined, .denied, .restricted:
                break
            @unknown default:
                break
            }
        }
    }
    
    // 权限状态描述
    private func authorizationStatusDescription(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "未确定"
        case .denied:
            return "已拒绝"
        case .restricted:
            return "受限制"
        case .authorizedWhenInUse:
            return "使用时授权"
        case .authorizedAlways:
            return "始终授权"
        @unknown default:
            return "未知状态"
        }
    }
    
    // 实际启动位置更新
    private func startLocationUpdates() {
        // 在后台检查位置服务状态，避免主线程阻塞
        Task.detached { [weak self] in
            guard let self = self else { return }
            
            let locationServicesEnabled = CLLocationManager.locationServicesEnabled()
            
            await MainActor.run {
                guard locationServicesEnabled else {
                    print("📍 系统位置服务未启用，无法获取位置")
                    return
                }
                
                print("📍 开始位置更新")
                self.locationManager.startUpdatingLocation()
                self.locationManager.startUpdatingHeading()
                self.startLocationTimer()
            }
        }
    }
    
    // 停止位置服务
    func stopLocationServices() {
        print("📍 停止GPS位置服务")
        locationManager.stopUpdatingLocation()
        locationTimer?.invalidate()
        locationTimer = nil
        stopExposureMeteringTimer()
    }
    
    // 位置更新定时器
    private var locationTimer: Timer?
    
    private func startLocationTimer() {
        locationTimer?.invalidate()
        locationTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // 每30秒重新获取一次位置
            Task { @MainActor in
                if CLLocationManager.locationServicesEnabled() {
                    print("📍 30秒定时更新GPS位置")
                    self.locationManager.requestLocation() // 单次位置请求
                }
            }
        }
    }

    // MARK: - 自动测光（固定ISO前提下）
    private func startExposureMeteringTimer() {
        // 为避免频闪，不再高频打断预览去重设曝光
        exposureMeterTimer?.invalidate()
        exposureMeterTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.scheduleReapplyFixedISO()
            }
        }
    }

    private func stopExposureMeteringTimer() {
        exposureMeterTimer?.invalidate()
        exposureMeterTimer = nil
    }
}

// MARK: - CLLocationManagerDelegate
extension CameraManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let location = locations.last {
                self.currentLocation = location
                // 节流日志：仅在时间>1s或位置变化>10m时输出一条
                let now = Date()
                let shouldLog: Bool = {
                    let timeOk = now.timeIntervalSince(self.lastLocationLogTime) > 1.0
                    if let last = self.lastLoggedLocation {
                        let dist = location.distance(from: last)
                        return timeOk || dist > 10
                    }
                    return timeOk
                }()
                if shouldLog {
                    self.lastLocationLogTime = now
                    self.lastLoggedLocation = location
                    let age = now.timeIntervalSince(location.timestamp)
                    print(String(format: "📍 位置更新 lat=%.6f lon=%.6f alt=%.1f acc=%.1f age=%.2fs",
                                  location.coordinate.latitude, location.coordinate.longitude,
                                  location.altitude, location.horizontalAccuracy, age))
                }
                // 唤醒等待中的请求
                if !self.pendingLocationRequests.isEmpty {
                    for (id, cont) in self.pendingLocationRequests { cont.resume(returning: location); self.pendingLocationRequests.removeValue(forKey: id) }
                }
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("📍 位置获取失败: \(error.localizedDescription)")
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            print("📍 位置权限状态变化: \(self.authorizationStatusDescription(status))")
            
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                print("📍 位置权限获得，开始位置更新")
                self.startLocationUpdates()
            case .denied, .restricted:
                print("📍 位置权限被拒绝或受限，停止位置服务")
                self.stopLocationServices()
            case .notDetermined:
                print("📍 位置权限仍未确定，等待用户选择")
            @unknown default:
                print("📍 未知的位置权限状态: \(status.rawValue)")
            }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // 将重活从主线程移走：不在此处做元数据重写，加快回调速度
        if let error = error {
            Task { @MainActor in self.photoDataHandler?(nil) }
            print("Photo capture error: \(error)")
            return
        }
        guard let imageData = photo.fileDataRepresentation() else {
            Task { @MainActor in self.photoDataHandler?(nil) }
            print("Could not get photo data")
            return
        }
        // 拍照完成后恢复曝光补偿和曝光模式（若有调整）
        Task { @MainActor in
            if let device = self.videoCaptureDevice {
                do {
                    try device.lockForConfiguration()
                    device.setExposureTargetBias(self.previousExposureTargetBias) { _ in }
                    if self.lockedExposureForFlashCapture, device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                        self.lockedExposureForFlashCapture = false
                    }
                    device.unlockForConfiguration()
                    print(String(format: "⚡️ Flash PostRestore: bias=%.2f", self.previousExposureTargetBias))
                } catch {}
            }
        }
        // 直接回调原始数据；后续在调用方应用 LUT 并在后台复制元数据
        Task { @MainActor in self.photoDataHandler?(imageData) }
    }
    
    // 手动添加GPS元数据和方向信息到图片
    private func addGPSMetadataToImage(imageData: Data, location: CLLocation) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let imageType = CGImageSourceGetType(imageSource),
              let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
            return nil
        }
        
        // 获取原始元数据
        var metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] ?? [:]
        
        // 添加GPS信息
        let gpsMetadata: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(location.coordinate.latitude),
            kCGImagePropertyGPSLongitude as String: abs(location.coordinate.longitude),
            kCGImagePropertyGPSLatitudeRef as String: location.coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitudeRef as String: location.coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude as String: location.altitude,
            kCGImagePropertyGPSTimeStamp as String: location.timestamp.description,
            kCGImagePropertyGPSSpeed as String: location.speed >= 0 ? location.speed : 0,
            kCGImagePropertyGPSImgDirection as String: location.course >= 0 ? location.course : 0
        ]
        metadata[kCGImagePropertyGPSDictionary as String] = gpsMetadata
        
        // 添加设备信息到TIFF字典
        var tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiffDict[kCGImagePropertyTIFFMake as String] = "Apple"
        tiffDict[kCGImagePropertyTIFFModel as String] = getModelIdentifier()
        tiffDict[kCGImagePropertyTIFFSoftware as String] = "JustShoot Camera"
        
        // 添加EXIF方向信息 - iOS 17新方式 vs 旧版本兼容
        let orientationValue: Int
        if #available(iOS 17.0, *), let coordinator = rotationCoordinator {
            // 使用iOS 17的rotation coordinator获取方向
            let rotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            orientationValue = exifOrientationFromRotationAngle(rotationAngle)
            print("📱 iOS 17添加EXIF方向信息: 旋转角度\(rotationAngle)° = EXIF值\(orientationValue)")
        } else {
            // 兼容旧版本
            orientationValue = exifOrientation(from: currentDeviceOrientation)
            print("📱 兼容模式添加EXIF方向信息: \(orientationDescription(currentDeviceOrientation)) = EXIF值\(orientationValue)")
        }
        
        tiffDict[kCGImagePropertyTIFFOrientation as String] = orientationValue
        metadata[kCGImagePropertyTIFFDictionary as String] = tiffDict
        
        // 确保EXIF字典也包含拍摄时间和正确的焦距信息
        var exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exifDict[kCGImagePropertyExifDateTimeOriginal as String] = formatter.string(from: Date())
        exifDict[kCGImagePropertyExifDateTimeDigitized as String] = formatter.string(from: Date())
        
        // 写入正确的35mm等效焦距到EXIF
        exifDict[kCGImagePropertyExifFocalLenIn35mmFilm as String] = Int(targetFocalLength)
        // 保持物理焦距信息
        exifDict[kCGImagePropertyExifFocalLength as String] = Double(devicePhysicalFocalLength)
        print("📸 写入EXIF焦距信息: 35mm等效=\(targetFocalLength)mm, 物理=\(devicePhysicalFocalLength)mm")
        
        metadata[kCGImagePropertyExifDictionary as String] = exifDict
        
        // 保存带有新元数据的图片
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, metadata as CFDictionary)
        
        if CGImageDestinationFinalize(destination) {
            return mutableData as Data
        }
        
        return nil
    }
    
    // 仅添加方向元数据到图片（当没有GPS时）
    private func addOrientationMetadataToImage(imageData: Data) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let imageType = CGImageSourceGetType(imageSource),
              let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
            return nil
        }
        
        // 获取原始元数据
        var metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] ?? [:]
        
        // 添加设备信息到TIFF字典
        var tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiffDict[kCGImagePropertyTIFFMake as String] = "Apple"
        tiffDict[kCGImagePropertyTIFFModel as String] = getModelIdentifier()
        tiffDict[kCGImagePropertyTIFFSoftware as String] = "JustShoot Camera"
        
        // 添加EXIF方向信息 - iOS 17新方式 vs 旧版本兼容
        let orientationValue: Int
        if #available(iOS 17.0, *), let coordinator = rotationCoordinator {
            // 使用iOS 17的rotation coordinator获取方向
            let rotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            orientationValue = exifOrientationFromRotationAngle(rotationAngle)
            print("📱 iOS 17添加EXIF方向信息: 旋转角度\(rotationAngle)° = EXIF值\(orientationValue)")
        } else {
            // 兼容旧版本
            orientationValue = exifOrientation(from: currentDeviceOrientation)
            print("📱 兼容模式添加EXIF方向信息: \(orientationDescription(currentDeviceOrientation)) = EXIF值\(orientationValue)")
        }
        
        tiffDict[kCGImagePropertyTIFFOrientation as String] = orientationValue
        metadata[kCGImagePropertyTIFFDictionary as String] = tiffDict
        
        // 确保EXIF字典也包含拍摄时间和正确的焦距信息
        var exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exifDict[kCGImagePropertyExifDateTimeOriginal as String] = formatter.string(from: Date())
        exifDict[kCGImagePropertyExifDateTimeDigitized as String] = formatter.string(from: Date())
        
        // 写入正确的35mm等效焦距到EXIF
        exifDict[kCGImagePropertyExifFocalLenIn35mmFilm as String] = Int(targetFocalLength)
        // 保持物理焦距信息
        exifDict[kCGImagePropertyExifFocalLength as String] = Double(devicePhysicalFocalLength)
        print("📸 写入EXIF焦距信息: 35mm等效=\(targetFocalLength)mm, 物理=\(devicePhysicalFocalLength)mm")
        
        metadata[kCGImagePropertyExifDictionary as String] = exifDict
        
        // 保存带有新元数据的图片
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, metadata as CFDictionary)
        
        if CGImageDestinationFinalize(destination) {
            return mutableData as Data
        }
        
        return nil
    }
}

// MARK: - 视频输出：实时预览像素缓存
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    @preconcurrency nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor in
            self.latestPixelBuffer = buffer
        }
    }
}

// MARK: - SwiftUI 实时预览视图（MTKView + CI 渲染）
struct RealtimePreviewView: UIViewRepresentable {
    let manager: CameraManager
    let preset: FilmPreset

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 30
        context.coordinator.setup(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.preset = preset
        context.coordinator.manager = manager
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var preset: FilmPreset = .fujiC200
        weak var manager: CameraManager?
        private var ciContext: CIContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

        func setup(view: MTKView) {
            view.delegate = self
            if let dev = view.device {
                // 可根据需要创建命令队列，但 CIContext 会管理
                _ = dev
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pixelBuffer = manager?.latestPixelBuffer,
                  let drawable = view.currentDrawable,
                  let commandQueue = view.device?.makeCommandQueue(),
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            // 预览始终保持竖屏：若帧为横向（宽>高），统一旋转90°到竖向
            if ciImage.extent.width > ciImage.extent.height {
                ciImage = ciImage.oriented(.right)
            }
            // 中心裁剪为 3:4，确保预览取景与成片一致（避免拉伸/挤压）
            do {
                let targetAspect: CGFloat = 3.0 / 4.0
                let e = ciImage.extent
                let aspect = e.width / e.height
                if abs(aspect - targetAspect) > 0.001 {
                    if aspect > targetAspect {
                        // 过宽，裁左右
                        let newW = e.height * targetAspect
                        let x = e.origin.x + (e.width - newW) / 2.0
                        ciImage = ciImage.cropped(to: CGRect(x: x, y: e.origin.y, width: newW, height: e.height))
                    } else {
                        // 过高，裁上下
                        let newH = e.width / targetAspect
                        let y = e.origin.y + (e.height - newH) / 2.0
                        ciImage = ciImage.cropped(to: CGRect(x: e.origin.x, y: y, width: e.width, height: newH))
                    }
                }
            }
            let outputImage = FilmProcessor.shared.applyLUT(to: ciImage, preset: preset) ?? ciImage

            ciContext.render(outputImage, to: drawable.texture, commandBuffer: commandBuffer, bounds: outputImage.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - UIDeviceOrientation Extension
extension UIDeviceOrientation {
    var isValidInterfaceOrientation: Bool {
        switch self {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            return true
        default:
            return false
        }
    }
} 

