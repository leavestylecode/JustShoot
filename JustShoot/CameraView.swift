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
    @Query(sort: \Photo.timestamp, order: .reverse) private var allPhotos: [Photo]
    @StateObject private var cameraManager: CameraManager
    @State private var showFlash = false
    @State private var exposuresRemaining: Int = 27
    @State private var currentRoll: Roll?
    @State private var isCapturing = false
    @State private var lastCapturedPhoto: Photo?
    @State private var lastPhotoThumbnail: UIImage?
    @State private var showingGallery = false

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

                // 中间预览区：3:4 固定取景框
                GeometryReader { _ in
                    RealtimePreviewView(manager: cameraManager, preset: preset)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 8)
                }
                .aspectRatio(3/4, contentMode: .fit)
                .padding(.horizontal, 16)

                Spacer(minLength: 8)

                // 底部控制区：左侧闪光灯 + 中间快门 + 右侧缩略图
                HStack(alignment: .center) {
                    // 左侧闪光灯按钮
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        cameraManager.toggleFlashMode()
                    }) {
                        let isOn = cameraManager.flashMode == .on
                        Image(systemName: isOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.8))
                            .frame(width: 44, height: 44)
                            .background(isOn ? Color.yellow : Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // 中间快门按钮（白色圆环设计）
                    Button(action: { capturePhoto() }) {
                        ZStack {
                            // 外圈白色环
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            // 内圈按钮
                            Circle()
                                .fill(Color.white)
                                .frame(width: 60, height: 60)
                                .scaleEffect(isCapturing ? 0.9 : 1.0)
                                .animation(.easeInOut(duration: 0.1), value: isCapturing)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // 右侧最近照片缩略图
                    Button(action: { showingGallery = true }) {
                        if let lastPhoto = lastCapturedPhoto, let thumb = lastPhotoThumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                )
                        } else {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.6))
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }

            // 快门闪光效果
            if showFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.7)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            // 锁定为竖屏
            OrientationManager.shared.lockOrientation(.portrait)
            // 强制旋转到竖屏
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }

            FilmProcessor.shared.preload(preset: preset)
            cameraManager.requestCameraPermission()
            prepareCurrentRoll()
            updateExposuresRemaining()
            loadLastPhotoThumbnail()
        }
        .onDisappear {
            // 解锁方向
            OrientationManager.shared.unlockOrientation()
            cameraManager.stopLocationServices()
        }
        .fullScreenCover(isPresented: $showingGallery) {
            GalleryView()
        }
        .onChange(of: allPhotos.count) { _, _ in
            loadLastPhotoThumbnail()
        }
    }

    private func loadLastPhotoThumbnail() {
        guard let photo = allPhotos.first else {
            lastCapturedPhoto = nil
            lastPhotoThumbnail = nil
            return
        }
        lastCapturedPhoto = photo
        Task {
            let thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: 88)
            await MainActor.run {
                lastPhotoThumbnail = thumb
            }
        }
    }
    
    private func capturePhoto() {
        // 防止重复拍摄
        guard !isCapturing else { return }

        // 立即触发触觉反馈
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // 快门按压动画 + 闪光效果
        Task { @MainActor in
            isCapturing = true
            try? await Task.sleep(nanoseconds: 80_000_000) // 0.08s 按压效果

            withAnimation(.easeOut(duration: 0.08)) {
                showFlash = true
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s 闪光
            withAnimation(.easeIn(duration: 0.1)) {
                showFlash = false
            }

            isCapturing = false
        }

        // 触发拍摄（回调仅处理数据）
        let currentPreset = preset
        let manager = cameraManager
        let context = modelContext

        cameraManager.capturePhoto { imageData in
            guard let data = imageData else { return }

            // 后台处理管道（不阻塞 UI）
            Task.detached(priority: .userInitiated) {
                // iOS 18 优化：并发处理 LUT + GPS（节省 ~500ms）
                async let processedData = FilmProcessor.shared.applyLUTPreservingMetadata(
                    imageData: data,
                    preset: currentPreset,
                    outputQuality: 0.95,
                    location: await manager.cachedOrFreshLocation()
                )
                async let location = manager.cachedOrFreshLocation()

                // 等待并发任务完成
                let (finalData, finalLoc) = await (processedData ?? data, location)

                // 主线程保存（使用 nonisolated 上下文避免 Sendable 警告）
                await MainActor.run {
                    Self.savePhotoToContext(
                        imageData: finalData,
                        preset: currentPreset,
                        location: finalLoc,
                        context: context
                    )
                }
            }
        }
    }

    @MainActor
    private static func savePhotoToContext(
        imageData: Data,
        preset: FilmPreset,
        location: CLLocation?,
        context: ModelContext
    ) {
        let newPhoto = Photo(imageData: imageData, filmPresetName: preset.rawValue)
        if let loc = location {
            newPhoto.latitude = loc.coordinate.latitude
            newPhoto.longitude = loc.coordinate.longitude
            newPhoto.altitude = loc.altitude
            newPhoto.locationTimestamp = loc.timestamp
        }

        // 查找或创建当前胶卷
        let descriptor = FetchDescriptor<Roll>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let allRolls = (try? context.fetch(descriptor)) ?? []
        let activeRolls = allRolls.filter { $0.presetName == preset.rawValue && !$0.isCompleted }

        let roll = activeRolls.first ?? {
            let newRoll = Roll(preset: preset, capacity: 27)
            context.insert(newRoll)
            return newRoll
        }()

        newPhoto.roll = roll
        context.insert(newPhoto)

        do {
            try context.save()
            print("📸 Photo saved successfully")
            if roll.isCompleted {
                print("🎞️ 胶卷已拍完 \(roll.capacity) 张，自动完成")
            }
        } catch {
            print("❌ Failed to save photo: \(error)")
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
    // iOS 18 优化：位置缓存策略
    private var locationCache: [Date: CLLocation] = [:]
    private let locationCacheExpiry: TimeInterval = 30.0
    private var pendingLocationRequests: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]

    @MainActor
    func currentLocationSnapshot() -> CLLocation? {
        return currentLocation
    }

    // iOS 18 优化：获取缓存或新鲜位置（无阻塞等待）
    func cachedOrFreshLocation() async -> CLLocation? {
        let now = Date()

        // 1. 检查30s内的缓存
        if let recent = locationCache.values.first(where: {
            now.timeIntervalSince($0.timestamp) < locationCacheExpiry
        }) {
            return recent
        }

        // 2. 使用当前位置
        if let fresh = currentLocation {
            locationCache[now] = fresh
            // 清理过期缓存
            locationCache = locationCache.filter { now.timeIntervalSince($0.value.timestamp) < locationCacheExpiry }
            return fresh
        }

        // 3. 触发后台更新（下次拍摄使用）
        locationManager.requestLocation()

        return nil
    }

    // 保留原方法用于兼容（已废弃，建议使用 cachedOrFreshLocation）
    @available(*, deprecated, message: "Use cachedOrFreshLocation() instead")
    func fetchFreshLocation(timeout: TimeInterval = 1.5, freshness: TimeInterval = 10.0) async -> CLLocation? {
        return await cachedOrFreshLocation()
    }
    
    // iOS 18 方向管理
    fileprivate var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
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
        // 若初始读取到无效方向（如横屏进入时常见的 .unknown/.faceUp），用界面方向回填
        bootstrapInitialOrientationIfNeeded()
    }
    
    // 更新设备方向
    private func updateDeviceOrientation() {
        let orientation = UIDevice.current.orientation
        
        // 只处理有效的方向
        if orientation.isValidInterfaceOrientation {
            currentDeviceOrientation = orientation
            // 同步缓存，供预览渲染在角度不可用时回退使用
            self.previewDeviceOrientation = orientation
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

    // 当 UIDeviceOrientation 初始无效时，从窗口场景的界面方向推断一次，修正横屏进入的初始状态
    private func bootstrapInitialOrientationIfNeeded() {
        // 仅当尚未缓存有效的预览方向时回填
        if previewDeviceOrientation == nil || previewDeviceOrientation == .unknown {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let io = scene.interfaceOrientation
                let dev: UIDeviceOrientation
                switch io {
                case .portrait: dev = .portrait
                case .portraitUpsideDown: dev = .portraitUpsideDown
                case .landscapeLeft: dev = .landscapeRight // 窗口方向与设备方向在横屏上相反
                case .landscapeRight: dev = .landscapeLeft
                default: dev = .portrait
                }
                self.previewDeviceOrientation = dev
                self.currentDeviceOrientation = dev
                applyVideoOrientationToOutputs()
            }
        }
    }
    
    // 兼容旧版本：仅缓存设备方向，由渲染与EXIF写入处理方向
    // 不再使用已废弃的 AVCaptureConnection.videoOrientation

    // iOS 18: 同步当前方向到预览/拍照输出连接
    private func applyVideoOrientationToOutputs() {
        guard let coordinator = rotationCoordinator else { return }

        let angle = coordinator.videoRotationAngleForHorizonLevelCapture

        // 设置拍照输出角度
        if let pconn = photoOutput.connection(with: .video),
           pconn.isVideoRotationAngleSupported(angle) {
            pconn.videoRotationAngle = angle
        }

        if let lconn = conversionPreviewLayer?.connection,
           lconn.isVideoRotationAngleSupported(angle) {
            lconn.videoRotationAngle = angle
        }

        // 缓存给渲染线程使用
        self.previewRotationAngle = angle
    }

    // 已改为全自动对焦
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
    
    // iOS 18: 从旋转角度转换为EXIF方向值
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

    // iOS 18: 从旋转角度转换为CIImage方向
    fileprivate func orientationFromRotationAngle(_ rotationAngle: CGFloat) -> CGImagePropertyOrientation {
        let normalizedAngle = Int(rotationAngle) % 360
        switch normalizedAngle {
        case 0:
            return .up          // 正常方向 0°
        case 90, -270:
            return .right       // 逆时针旋转90度
        case 180, -180:
            return .down        // 旋转180度
        case 270, -90:
            return .left        // 顺时针旋转90度
        default:
            return .up          // 默认为正常方向
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
        // iOS 18 优化：批量配置以减少开销
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let videoCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("❌ Failed to get camera device")
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

                // iOS 18 优化：响应式拍摄 + 快速连拍
                photoOutput.maxPhotoQualityPrioritization = .speed
                photoOutput.isResponsiveCaptureEnabled = true
                photoOutput.isFastCapturePrioritizationEnabled = true

                // 精确控制输出尺寸（从支持的尺寸中选择）
                let format = videoCaptureDevice.activeFormat
                let supportedDimensions = format.supportedMaxPhotoDimensions

                // 选择最接近 4:3 比例且不超过 4000px 宽度的尺寸
                let preferred = supportedDimensions.filter { dim in
                    let ratio = Float(dim.width) / Float(dim.height)
                    return dim.width <= 4000 && abs(ratio - 4.0/3.0) < 0.1
                }.max { $0.width < $1.width }

                if let selected = preferred {
                    photoOutput.maxPhotoDimensions = selected
                    print("📐 Photo dimensions: \(selected.width)×\(selected.height)")
                } else if let largest = supportedDimensions.max(by: { $0.width < $1.width }) {
                    // 回退：使用最大支持尺寸
                    photoOutput.maxPhotoDimensions = largest
                    print("📐 Photo dimensions (fallback): \(largest.width)×\(largest.height)")
                }

                // Rotation coordinator
                rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: videoCaptureDevice,
                    previewLayer: nil
                )
                print("📱 Using iOS 18 AVCaptureDevice.RotationCoordinator")
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
                forName: AVCaptureDevice.subjectAreaDidChangeNotification,
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
            self.applyVideoOrientationToOutputs()
        }
    }
    
    @MainActor
    func capturePhoto(completion: @escaping (Data?) -> Void) {
        photoDataHandler = completion

        let settings = AVCapturePhotoSettings()

        // iOS 18 优化：快速拍摄优先级
        settings.photoQualityPrioritization = .speed
        
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
        
        // iOS 18 优化：使用 RotationCoordinator 设置照片方向
        if let coordinator = rotationCoordinator,
           let connection = photoOutput.connection(with: .video) {
            let rotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
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
                let age = Date().timeIntervalSince(location.timestamp)
                print(String(format: "📍 位置更新 lat=%.6f lon=%.6f alt=%.1f acc=%.1f age=%.2fs",
                              location.coordinate.latitude, location.coordinate.longitude,
                              location.altitude, location.horizontalAccuracy, age))
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
        if let error = error {
            Task { @MainActor in self.photoDataHandler?(nil) }
            print("❌ [照片] 拍摄错误: \(error)")
            return
        }
        guard let imageData = photo.fileDataRepresentation() else {
            Task { @MainActor in self.photoDataHandler?(nil) }
            print("❌ [照片] 无法获取照片数据")
            return
        }

        Task.detached(priority: .userInitiated) {
            // 原始照片信息
            if let source = CGImageSourceCreateWithData(imageData as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                let width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                let height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                let exifOrientation = props[kCGImagePropertyOrientation as String] as? UInt32 ?? 0
                print("📸 [照片] 原始尺寸: \(width)×\(height), EXIF方向: \(exifOrientation)")
            }

            // 读取照片的 EXIF 方向并物理旋转像素
            let rotatedData = self.applyExifOrientationToPixels(imageData: imageData)

            // 调试日志
            if let rotatedData = rotatedData,
               let source = CGImageSourceCreateWithData(rotatedData as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                let width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                let height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                let exifOrientation = props[kCGImagePropertyOrientation as String] as? UInt32 ?? 0
                print("📸 [照片] 旋转后尺寸: \(width)×\(height), EXIF方向: \(exifOrientation)")
            }

            // 回调处理后的数据
            await MainActor.run {
                self.photoDataHandler?(rotatedData ?? imageData)
            }
        }

        // 拍照完成后恢复曝光
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
                } catch {}
            }
        }
    }

    /// 读取照片 EXIF 方向并物理旋转像素
    /// AVFoundation 拍摄的照片带有 EXIF 方向标记，我们将其应用到像素上
    private nonisolated func applyExifOrientationToPixels(imageData: Data) -> Data? {
        // 1. 读取 EXIF 方向
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return imageData
        }

        // 获取方向值（默认为 1 = .up）
        let orientationValue = properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up

        print("📸 [照片] EXIF 方向值: \(orientationValue)")

        // 如果方向已经是 .up，无需旋转
        if orientation == .up {
            return imageData
        }

        // 2. 加载图像并应用方向
        guard let ciImage = CIImage(data: imageData) else { return imageData }
        let rotatedImage = ciImage.oriented(orientation)

        // 3. 渲染为 JPEG
        let ciContext = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let renderedJPEG = ciContext.jpegRepresentation(of: rotatedImage, colorSpace: colorSpace, options: [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95
        ]) else { return imageData }

        // 4. 复制元数据，并将方向设为 .up
        var metadata = properties
        metadata[kCGImagePropertyOrientation as String] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        // 5. 写入最终图像
        guard let renderedSource = CGImageSourceCreateWithData(renderedJPEG as CFData, nil),
              let mutableData = CFDataCreateMutable(nil, 0),
              let imageType = CGImageSourceGetType(renderedSource),
              let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
            return imageData
        }

        metadata[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        CGImageDestinationAddImageFromSource(destination, renderedSource, 0, metadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return imageData }

        let rotatedExtent = rotatedImage.extent
        print("📸 [照片] 旋转后尺寸: \(Int(rotatedExtent.width))×\(Int(rotatedExtent.height))")

        return mutableData as Data
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
        // 清除背景色
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
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
        private var ciContext: CIContext!
        private var commandQueue: MTLCommandQueue?
        // 日志节流
        private var lastLogTime: Date = .distantPast
        private let logInterval: TimeInterval = 2.0

        func setup(view: MTKView) {
            view.delegate = self
            if let device = view.device {
                commandQueue = device.makeCommandQueue()
                ciContext = CIContext(mtlDevice: device, options: [
                    .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                    .outputColorSpace: CGColorSpaceCreateDeviceRGB()
                ])
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pixelBuffer = manager?.latestPixelBuffer,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

            // 1. 从相机获取原始图像
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rawExtent = ciImage.extent

            // 2. 判断是否需要旋转
            // 相机预览应该是竖屏（高 > 宽），如果是横向buffer（宽 > 高），需要旋转90度
            let isLandscapeBuffer = rawExtent.width > rawExtent.height
            let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let isPortraitView = drawableSize.height > drawableSize.width

            // 如果 buffer 是横向的，但视图是竖向的，需要旋转
            if isLandscapeBuffer && isPortraitView {
                // 强制旋转 90 度使其变为竖向
                ciImage = ciImage.oriented(.right)
            } else if let angle = manager?.previewRotationAngle, angle != 0 {
                // 否则使用 RotationCoordinator 提供的角度
                let orientation = orientationFromAngle(angle)
                ciImage = ciImage.oriented(orientation)
            }

            // 3. 应用 LUT 滤镜
            let lutImage = FilmProcessor.shared.applyLUT(to: ciImage, preset: preset) ?? ciImage
            let imageExtent = lutImage.extent

            // 4. 计算填充渲染区域（保持比例，居中显示）
            let targetRect = aspectFillRect(imageSize: imageExtent.size, targetSize: drawableSize)

            // 5. 将图像缩放到目标区域
            let scaleX = targetRect.width / imageExtent.width
            let scaleY = targetRect.height / imageExtent.height
            let scaledImage = lutImage
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .transformed(by: CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y))

            // 6. 渲染到 drawable
            let renderBounds = CGRect(origin: .zero, size: drawableSize)
            ciContext.render(scaledImage, to: drawable.texture, commandBuffer: commandBuffer, bounds: renderBounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            commandBuffer.present(drawable)
            commandBuffer.commit()

            // 节流日志
            let now = Date()
            if now.timeIntervalSince(lastLogTime) >= logInterval {
                lastLogTime = now
                let rotationAngle = manager?.previewRotationAngle ?? -1
                let autoRotated = isLandscapeBuffer && isPortraitView
                print("🎥 [预览] 原始:\(Int(rawExtent.width))×\(Int(rawExtent.height)) 自动旋转:\(autoRotated) 角度:\(Int(rotationAngle))° → 处理后:\(Int(imageExtent.width))×\(Int(imageExtent.height)) → 显示:\(Int(targetRect.width))×\(Int(targetRect.height))")
            }
        }

        // 角度转方向
        private func orientationFromAngle(_ angle: CGFloat) -> CGImagePropertyOrientation {
            let normalized = Int(angle.truncatingRemainder(dividingBy: 360))
            switch normalized {
            case 0: return .up
            case 90: return .right
            case 180: return .down
            case 270: return .left
            default: return .up
            }
        }

        // 计算 Aspect Fill 区域（居中，保持比例，填满目标）
        private func aspectFillRect(imageSize: CGSize, targetSize: CGSize) -> CGRect {
            let imageAspect = imageSize.width / imageSize.height
            let targetAspect = targetSize.width / targetSize.height

            var drawWidth: CGFloat
            var drawHeight: CGFloat

            if imageAspect > targetAspect {
                // 图像更宽，按高度填满
                drawHeight = targetSize.height
                drawWidth = drawHeight * imageAspect
            } else {
                // 图像更高，按宽度填满
                drawWidth = targetSize.width
                drawHeight = drawWidth / imageAspect
            }

            let x = (targetSize.width - drawWidth) / 2
            let y = (targetSize.height - drawHeight) / 2

            return CGRect(x: x, y: y, width: drawWidth, height: drawHeight)
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

