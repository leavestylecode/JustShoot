import SwiftUI
import AVFoundation
import SwiftData
import CoreLocation

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
    
    override init() {
        super.init()
        setupCamera()
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
                
                // iOS 17 新特性：启用高质量照片
                if #available(iOS 17.0, *) {
                    photoOutput.maxPhotoQualityPrioritization = .quality
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
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters // 降低精度以节省电量
        locationManager.distanceFilter = 50 // 移动50米才更新
        
        // 检查当前权限状态
        let authStatus = locationManager.authorizationStatus
        switch authStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            // 权限结果将在delegate回调中处理
        case .authorizedWhenInUse, .authorizedAlways:
            startLocationUpdates()
        case .denied, .restricted:
            print("📍 位置权限被拒绝或受限")
        @unknown default:
            print("📍 未知的位置权限状态")
        }
    }
    
    // 实际启动位置更新
    private func startLocationUpdates() {
        guard CLLocationManager.locationServicesEnabled() else {
            print("📍 位置服务未启用")
            return
        }
        
        print("📍 开始位置更新")
        locationManager.startUpdatingLocation()
        startLocationTimer()
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
            
            // 如果有位置信息，手动添加GPS数据到EXIF
            if let location = self.currentLocation {
                if let enhancedData = self.addGPSMetadataToImage(imageData: imageData, location: location) {
                    print("✅ 成功添加GPS元数据到照片")
                    self.photoDataHandler?(enhancedData)
                    return
                }
            }
            
            print("📷 保存照片（原始元数据）")
            self.photoDataHandler?(imageData)
        }
    }
    
    // 手动添加GPS元数据到图片
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
        metadata[kCGImagePropertyTIFFDictionary as String] = tiffDict
        
        // 保存带有新元数据的图片
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, metadata as CFDictionary)
        
        if CGImageDestinationFinalize(destination) {
            return mutableData as Data
        }
        
        return nil
    }
} 