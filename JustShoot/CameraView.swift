import SwiftUI
import AVFoundation
import SwiftData
import CoreLocation
import UIKit
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

struct CameraView: View {
    let preset: FilmPreset
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Roll.createdAt, order: .reverse) private var rolls: [Roll]
    @StateObject private var cameraManager: CameraManager
    @State private var showFlash = false
    @State private var exposuresRemaining: Int = 27
    @State private var currentRoll: Roll?
    
    init(preset: FilmPreset) {
        self.preset = preset
        _cameraManager = StateObject(wrappedValue: CameraManager(preset: preset))
    }

    var body: some View {
        ZStack {
            // 背景：质感黑色（多层渐变叠加）
            ZStack {
                LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.06), Color.black], startPoint: .top, endPoint: .bottom)
                RadialGradient(gradient: Gradient(colors: [Color.white.opacity(0.06), .clear]), center: .top, startRadius: 0, endRadius: 400)
                LinearGradient(colors: [Color.clear, Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
                ZStack {
                    // 实时预览：先直接显示原始相机预览（后续可换为 Metal/CI 处理）
                    CameraPreviewView(session: cameraManager.session)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.red, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 6)
                }
                .aspectRatio(3/4, contentMode: .fit)
                .padding(.horizontal, 16)

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
        showFlash = true

        cameraManager.capturePhoto { imageData in
            DispatchQueue.main.async {
                if let data = imageData {
                    // 立即结束快门动画
                    showFlash = false
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    
                    // 后台应用 LUT 并保存，提升响应
                    Task.detached(priority: .userInitiated) { [imageData = data, preset = preset] in
                        let processedData = FilmProcessor.shared.applyLUTPreservingMetadata(imageData: imageData, preset: preset) ?? imageData
                        await MainActor.run {
                            if currentRoll == nil || (currentRoll?.isCompleted ?? true) {
                                currentRoll = createOrFetchActiveRoll()
                            }
                            let newPhoto = Photo(imageData: processedData, filmPresetName: preset.rawValue)
                            newPhoto.roll = currentRoll
                            modelContext.insert(newPhoto)
                            do {
                                try modelContext.save()
                                print("Photo saved successfully")
                                updateExposuresRemaining()
                                if currentRoll?.isCompleted == true {
                                    print("🎞️ 胶卷已拍完 \(currentRoll?.capacity ?? 27) 张，自动完成")
                                }
                            } catch {
                                print("Failed to save photo: \(error)")
                            }
                        }
                    }
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

    // 自动测光定时器（在固定 ISO 前提下，周期性基于测光调整快门）
    private var exposureMeterTimer: Timer?
    
    init(preset: FilmPreset) {
        self.preset = preset
        self.fixedISOValue = 0
        super.init()
        setupCamera()
        setupOrientationMonitoring()
    }
    
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
    
    // 兼容旧版本：转换设备方向为AVCaptureVideoOrientation
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    private func videoOrientation(from deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch deviceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight  // 注意：设备向左转，视频方向向右
        case .landscapeRight:
            return .landscapeLeft   // 注意：设备向右转，视频方向向左
        default:
            return .portrait        // 默认为竖屏
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

            // 启用主体区域变化监控（用于在场景变化时重新应用固定ISO逻辑）
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
    
    private func startSession() async {
        guard !session.isRunning else { return }
        
        // 在后台线程启动相机会话，避免阻塞主线程
        await Task.detached { [weak self] in
            await self?.session.startRunning()
        }.value
        // 会话启动后再次应用 35mm 等效变焦，确保生效
        await MainActor.run {
            self.calculateZoomFactorFor35mm()
        }
    }
    
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
        
        // 设置闪光灯模式
        if let device = videoCaptureDevice, device.hasFlash {
            settings.flashMode = flashMode.avFlashMode
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
                    connection.videoRotationAngle = rotationAngle
                    print("📱 iOS 17设置照片旋转角度: \(rotationAngle)°")
                } else {
                    print("⚠️ 设备不支持该旋转角度: \(rotationAngle)°")
                }
            }
        } else {
            // 兼容iOS 16及以下版本
            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    let videoOrientation = videoOrientation(from: currentDeviceOrientation)
                    connection.videoOrientation = videoOrientation
                    print("📱 兼容模式设置照片方向: \(orientationDescription(currentDeviceOrientation)) -> \(videoOrientation)")
                } else {
                    print("⚠️ 设备不支持视频方向设置")
                }
            }
        }
        
        // 添加位置信息到照片设置中
        if let location = currentLocation {
            print("📍 添加GPS位置信息: \(location.coordinate)")
        }
        
        photoOutput.capturePhoto(with: settings, delegate: self)
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
        // 15 Pro 系列主摄 24mm；大多数 12/13/14/15 非 Pro 为 26mm；更老设备多为 28mm
        let name = modelName
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
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters // 降低精度以节省电量
        locationManager.distanceFilter = 50 // 移动50米才更新
        
        // 不主动拉取授权状态，直接请求授权，等回调中处理，避免主线程卡顿警告
        locationManager.requestWhenInUseAuthorization()
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
                print("📍 位置更新: \(location.coordinate.latitude), \(location.coordinate.longitude)")
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

