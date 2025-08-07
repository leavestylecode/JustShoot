import SwiftUI
import AVFoundation
import SwiftData
import CoreLocation
import UIKit

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var cameraManager = CameraManager()
    @State private var showFlash = false
    
    var body: some View {
        ZStack {
            // 相机预览
            CameraPreviewView(session: cameraManager.session)
                    .ignoresSafeArea()
            
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
}

// 相机预览视图
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
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
        session.sessionPreset = .photo
        
        guard let videoCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Failed to get camera device")
            return
        }
        
        self.videoCaptureDevice = videoCaptureDevice
        
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
        
        // 确保保留EXIF数据
        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
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
    
    // 启动位置服务（仅在拍摄页面）
    private func startLocationServices() {
        print("📍 启动GPS位置服务（拍摄模式）")
        
        // 配置位置管理器
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters // 降低精度以节省电量
        locationManager.distanceFilter = 50 // 移动50米才更新
        
        // 在后台队列检查权限状态，避免阻塞主线程
        Task.detached { [weak self] in
            guard let self = self else { return }
            
            await MainActor.run {
                let authStatus = self.locationManager.authorizationStatus
                print("📍 当前位置权限状态: \(self.authorizationStatusDescription(authStatus))")
                
                switch authStatus {
                case .notDetermined:
                    print("📍 请求位置权限")
                    self.locationManager.requestWhenInUseAuthorization()
                    // 权限结果将在didChangeAuthorization回调中处理
                case .authorizedWhenInUse, .authorizedAlways:
                    print("📍 位置权限已授权，开始位置更新")
                    self.startLocationUpdates()
                case .denied, .restricted:
                    print("📍 位置权限被拒绝或受限，无法获取位置信息")
                @unknown default:
                    print("📍 未知的位置权限状态")
                }
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
            print("📍 位置权限状态变化: \(status.rawValue)")
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                print("📍 位置权限获得，开始位置更新")
                self.startLocationUpdates()
            case .denied, .restricted:
                print("📍 位置权限被拒绝或受限")
            case .notDetermined:
                print("📍 位置权限未确定")
            @unknown default:
                print("📍 未知的位置权限状态")
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
        tiffDict[kCGImagePropertyTIFFModel as String] = UIDevice.current.model
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
        
        // 确保EXIF字典也包含拍摄时间
        var exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exifDict[kCGImagePropertyExifDateTimeOriginal as String] = formatter.string(from: Date())
        exifDict[kCGImagePropertyExifDateTimeDigitized as String] = formatter.string(from: Date())
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
        tiffDict[kCGImagePropertyTIFFModel as String] = UIDevice.current.model
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
        
        // 确保EXIF字典也包含拍摄时间
        var exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exifDict[kCGImagePropertyExifDateTimeOriginal as String] = formatter.string(from: Date())
        exifDict[kCGImagePropertyExifDateTimeDigitized as String] = formatter.string(from: Date())
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