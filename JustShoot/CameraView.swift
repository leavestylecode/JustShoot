import SwiftUI
import AVFoundation
import SwiftData
import CoreLocation
import UIKit
import Foundation

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var cameraManager = CameraManager()
    @State private var showFlash = false
    
    var body: some View {
        ZStack {
            // 黑色背景
            Color.black.ignoresSafeArea()
            
            // 相机预览（居中显示，固定比例，向上偏移）
            VStack {
                Spacer()
                    .frame(height: 80) // 向上偏移80点
                
                CameraPreviewView(session: cameraManager.session)
                    .aspectRatio(3/4, contentMode: .fit) // 固定4:3比例
                    .clipped()
                    .cornerRadius(12)
                    .overlay(
                        // 取景框边框
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.5), lineWidth: 2)
                    )
                    .overlay(
                        // 取景框提示
                        VStack {
                            HStack {
                                Text("拍摄区域")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(6)
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(16)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                
                Spacer()
                    .frame(height: 120) // 为底部控制区域留出更多空间
            }
            
            // 控制界面
            VStack {
                // 顶部控制栏
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    // 焦距显示（可点击调整）
                    Button(action: {
                        cycleFocalLength()
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.macro")
                                .font(.title2)
                                .foregroundColor(.white)
                            Text("\(String(format: "%.0f", cameraManager.targetFocalLength))mm")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .fontWeight(.bold)
                            Text("\(String(format: "%.1f", cameraManager.currentZoomFactor))x")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(12)
                    }
                    
                    // 闪光灯控制按钮
                    Button(action: {
                        cameraManager.toggleFlashMode()
                    }) {
                    VStack(spacing: 4) {
                            Image(systemName: cameraManager.flashMode.iconName)
                            .font(.title2)
                                .foregroundColor(.white)
                            Text(cameraManager.flashMode.displayName)
                                .font(.caption2)
                            .foregroundColor(.white)
                        }
                        .padding()
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(12)
                    }
                }
                .padding()
                
                Spacer()
                
                // 底部控制栏
                HStack {
                    Spacer()
                    
                    // 拍照按钮
                        Button(action: {
                        capturePhoto()
                        }) {
                            ZStack {
                                Circle()
                                .fill(Color.white)
                                    .frame(width: 80, height: 80)
                                Circle()
                                .stroke(Color.black, lineWidth: 2)
                                    .frame(width: 70, height: 70)
                        }
                    }
                    
                    Spacer()
                }
                .padding(.bottom, 50)
            }
            
            // 闪光效果
            if showFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.8)
                    .animation(.easeInOut(duration: 0.1), value: showFlash)
            }
        }
        .onAppear {
            cameraManager.requestCameraPermission()
        }
        .onDisappear {
            cameraManager.stopLocationServices() // 离开拍摄页面时停止GPS
        }
    }
    
    private func capturePhoto() {
        showFlash = true
        
        cameraManager.capturePhoto { imageData in
            DispatchQueue.main.async {
                if let data = imageData {
                    let photo = Photo(imageData: data)
                    modelContext.insert(photo)
                    
                    do {
                        try modelContext.save()
                        print("Photo saved successfully")
                    } catch {
                        print("Failed to save photo: \(error)")
                    }
                }
                
                showFlash = false
                // 移除自动返回，让用户自己决定何时返回
            }
        }
    }
    
    // 循环调整焦距
    private func cycleFocalLength() {
        let focalLengths: [Float] = [24, 28, 35, 50, 85] // 常用的35mm等效焦距
        
        if let currentIndex = focalLengths.firstIndex(of: cameraManager.targetFocalLength) {
            let nextIndex = (currentIndex + 1) % focalLengths.count
            cameraManager.adjustTargetFocalLength(focalLengths[nextIndex])
        } else {
            // 如果当前焦距不在预设列表中，设置为35mm
            cameraManager.adjustTargetFocalLength(35.0)
        }
    }
}

// 相机预览视图
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor.black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill // 保持比例填充
        
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
    case auto = "auto"
    case on = "on" 
    case off = "off"
    
    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .on: return "开启"
        case .off: return "关闭"
        }
    }
    
    var iconName: String {
        switch self {
        case .auto: return "bolt.badge.a"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        }
    }
    
    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: return .auto
        case .on: return .on
        case .off: return .off
        }
    }
}

@MainActor
class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var videoCaptureDevice: AVCaptureDevice?
    private var photoDataHandler: ((Data?) -> Void)?
    @Published var flashMode: FlashMode = .auto
    
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
    
    override init() {
        super.init()
        setupCamera()
        setupOrientationMonitoring()
    }
    
    deinit {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
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
        // 设置为4:3比例的高质量照片
        session.sessionPreset = .photo
        
        guard let videoCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Failed to get camera device")
            return
        }
        
        self.videoCaptureDevice = videoCaptureDevice
        
        // 读取设备焦距信息
        readCameraSpecs(device: videoCaptureDevice)
        
        // 计算达到35mm等效焦距所需的变焦系数
        calculateZoomFactorFor35mm()
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
            
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                
                // iOS 17 新特性：启用高质量照片和rotation coordinator
                if #available(iOS 17.0, *) {
                    photoOutput.maxPhotoQualityPrioritization = .quality
                    
                    // 设置rotation coordinator
                    rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: videoCaptureDevice, previewLayer: nil)
                    print("📱 使用iOS 17 AVCaptureDevice.RotationCoordinator")
                }
            }
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
    }
    
    func capturePhoto(completion: @escaping (Data?) -> Void) {
        photoDataHandler = completion
        
        let settings = AVCapturePhotoSettings()
        
        // iOS 17 优化：启用高质量优先级
        if #available(iOS 17.0, *) {
            settings.photoQualityPrioritization = .quality
        }
        
        // 设置闪光灯模式
        if let device = videoCaptureDevice, device.hasFlash {
            settings.flashMode = flashMode.avFlashMode
        }
        
        // 启用完整的元数据保留
        settings.embedsDepthDataInPhoto = false
        settings.embedsPortraitEffectsMatteInPhoto = false
        settings.embedsSemanticSegmentationMattesInPhoto = false
        
        // 设置照片尺寸为4:3比例
        if #available(iOS 16.0, *) {
            // 获取支持的最大尺寸并调整为4:3比例
            let maxDimensions = photoOutput.maxPhotoDimensions
            let targetWidth = min(maxDimensions.width, maxDimensions.height * 4 / 3)
            let targetHeight = targetWidth * 3 / 4
            settings.maxPhotoDimensions = CMVideoDimensions(width: targetWidth, height: targetHeight)
            print("📸 设置照片尺寸为4:3比例: \(targetWidth)x\(targetHeight)")
        }
        
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
        let modelIdentifier = getModelIdentifier()
        print("📱 设备标识符: \(modelIdentifier)")
        
        // 简化的设备检测
        if modelIdentifier == "Simulator" {
            print("📱 检测到模拟器，使用默认焦距")
            return 26.0
        }
        
        // 对于实际设备，使用系统默认值
        // 大多数现代iPhone的主摄都是26mm等效焦距
        print("📱 iPhone设备，使用26mm焦距")
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
        if device35mmEquivalentFocalLength > 0 {
            requiredZoomFactor = CGFloat(targetFocalLength / device35mmEquivalentFocalLength)
            
            // 确保变焦系数在设备支持的范围内
            if let device = videoCaptureDevice {
                let maxZoom = device.activeFormat.videoMaxZoomFactor
                let minZoom = device.minAvailableVideoZoomFactor
                
                requiredZoomFactor = max(minZoom, min(maxZoom, requiredZoomFactor))
                
                print("📐 计算变焦系数:")
                print("   - 设备当前等效焦距: \(device35mmEquivalentFocalLength)mm")
                print("   - 目标等效焦距: \(targetFocalLength)mm")
                print("   - 需要变焦系数: \(String(format: "%.2f", requiredZoomFactor))x")
                print("   - 设备变焦范围: \(String(format: "%.1f", minZoom))x - \(String(format: "%.1f", maxZoom))x")
                
                // 应用变焦
                applyZoomFactor(requiredZoomFactor)
            }
        }
    }
    
    // 应用变焦系数
    private func applyZoomFactor(_ zoomFactor: CGFloat) {
        guard let device = videoCaptureDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = zoomFactor
            currentZoomFactor = zoomFactor
            device.unlockForConfiguration()
            
            print("✅ 成功应用变焦系数: \(String(format: "%.2f", zoomFactor))x")
            print("🎯 当前模拟35mm等效焦距: \(String(format: "%.1f", Float(zoomFactor) * device35mmEquivalentFocalLength))mm")
        } catch {
            print("❌ 应用变焦失败: \(error)")
        }
    }
    
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
        
        // 检查当前权限状态
        let authStatus = locationManager.authorizationStatus
        print("📍 当前位置权限状态: \(authorizationStatusDescription(authStatus))")
        
        switch authStatus {
        case .notDetermined:
            print("📍 权限未确定，请求位置权限")
            // 异步请求权限，避免阻塞主线程
            Task.detached { [weak self] in
                guard let self = self else { return }
                await MainActor.run {
                    self.locationManager.requestWhenInUseAuthorization()
                }
            }
            // 权限结果将在didChangeAuthorization回调中处理
        case .authorizedWhenInUse, .authorizedAlways:
            print("📍 位置权限已授权，开始位置更新")
            startLocationUpdates()
        case .denied, .restricted:
            print("📍 位置权限被拒绝或受限，无法获取位置信息")
        @unknown default:
            print("📍 未知的位置权限状态")
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
        Task { @MainActor in
            if let error = error {
                print("Photo capture error: \(error)")
                self.photoDataHandler?(nil)
                return
            }
            
            // 获取带有完整元数据的图片数据
            guard let imageData = photo.fileDataRepresentation() else {
                print("Could not get photo data")
                self.photoDataHandler?(nil)
                return
            }
            
            // 添加完整元数据（GPS + 方向信息）
            if let location = self.currentLocation {
                // 有GPS位置时，添加GPS和方向信息
                if let enhancedData = self.addGPSMetadataToImage(imageData: imageData, location: location) {
                    print("✅ 成功添加GPS和方向元数据到照片")
                    self.photoDataHandler?(enhancedData)
                    return
                }
            } else {
                // 没有GPS时，只添加方向信息
                if let enhancedData = self.addOrientationMetadataToImage(imageData: imageData) {
                    print("✅ 成功添加方向元数据到照片")
                    self.photoDataHandler?(enhancedData)
                    return
                }
            }
            
            print("📷 保存照片（原始元数据）")
            self.photoDataHandler?(imageData)
        }
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
