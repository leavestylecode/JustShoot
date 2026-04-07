import SwiftUI
import AVFoundation
import SwiftData
import CoreLocation
import UIKit
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import os

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
    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusIndicator = false
    @State private var showRollFullAlert = false

    init(preset: FilmPreset) {
        self.preset = preset
        _cameraManager = StateObject(wrappedValue: CameraManager(preset: preset))
    }

    var body: some View {
        ZStack {
            // 背景
            ZStack {
                LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.06), Color.black], startPoint: .top, endPoint: .bottom)
                RadialGradient(gradient: Gradient(colors: [Color.white.opacity(0.06), .clear]), center: .top, startRadius: 0, endRadius: 400)
                LinearGradient(colors: [Color.clear, Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                    // 顶部栏
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

                    // 预览区
                    GeometryReader { geometry in
                        ZStack {
                            RealtimePreviewView(manager: cameraManager, preset: preset)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 8)

                            if showFocusIndicator, let point = focusPoint {
                                FocusIndicatorView()
                                    .position(point)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            handleTapToFocus(at: location, in: geometry.size)
                        }
                    }
                    .aspectRatio(3/4, contentMode: .fit)
                    .padding(.horizontal, 16)

                    Spacer(minLength: 8)

                    // 底部控制区
                    HStack(alignment: .center) {
                        // 闪光灯
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

                        // 快门
                        Button(action: { capturePhoto() }) {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 4)
                                    .frame(width: 72, height: 72)
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

                        // 缩略图
                        Button(action: { showingGallery = true }) {
                            if let _ = lastCapturedPhoto, let thumb = lastPhotoThumbnail {
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
            FilmProcessor.shared.preload(preset: preset)
            cameraManager.requestCameraPermission()
            prepareCurrentRoll()
            updateExposuresRemaining()
            loadLastPhotoThumbnail()
        }
        .onDisappear {
            cameraManager.stopLocationServices()
        }
        .fullScreenCover(isPresented: $showingGallery) {
            GalleryView()
        }
        .onChange(of: allPhotos.count) { _, _ in
            loadLastPhotoThumbnail()
            updateExposuresRemaining()
        }
        .alert("胶卷已拍完", isPresented: $showRollFullAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("当前胶卷已拍满 27 张，请返回选择新的胶卷。")
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

        // 胶卷已满检查
        guard exposuresRemaining > 0 else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showRollFullAlert = true
            return
        }

        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let currentPreset = preset
        let manager = cameraManager
        let context = modelContext

        cameraManager.capturePhoto(onExposureComplete: { [self] in
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.05)) {
                    showFlash = true
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
                withAnimation(.easeIn(duration: 0.1)) {
                    showFlash = false
                }
            }
        }) { [self] imageData in
            Task { @MainActor in
                isCapturing = false
            }

            guard let data = imageData else { return }

            Task.detached(priority: .userInitiated) {
                // 先获取一次 location，避免重复调用
                let location = await manager.cachedOrFreshLocation()

                let processedData = FilmProcessor.shared.applyLUTPreservingMetadata(
                    imageData: data,
                    preset: currentPreset,
                    outputQuality: 0.95,
                    location: location
                )

                let finalData = processedData ?? data

                await MainActor.run {
                    Self.savePhotoToContext(
                        imageData: finalData,
                        preset: currentPreset,
                        location: location,
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

        let roll = findOrCreateActiveRoll(preset: preset, context: context)
        newPhoto.roll = roll
        context.insert(newPhoto)

        do {
            try context.save()
            if roll.isCompleted {
                roll.completedAt = Date()
                try? context.save()
            }
        } catch {
            print("❌ Failed to save photo: \(error)")
        }
    }

    /// 统一的 Roll 查找/创建逻辑（消除三处重复）
    @MainActor
    private static func findOrCreateActiveRoll(preset: FilmPreset, context: ModelContext) -> Roll {
        let descriptor = FetchDescriptor<Roll>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let allRolls = (try? context.fetch(descriptor)) ?? []
        if let active = allRolls.first(where: { $0.presetName == preset.rawValue && !$0.isCompleted }) {
            return active
        }
        let newRoll = Roll(preset: preset, capacity: 27)
        context.insert(newRoll)
        return newRoll
    }

    private func prepareCurrentRoll() {
        currentRoll = Self.findOrCreateActiveRoll(preset: preset, context: modelContext)
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

    @MainActor
    private func handleTapToFocus(at location: CGPoint, in size: CGSize) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        focusPoint = location

        withAnimation(.easeOut(duration: 0.15)) {
            showFocusIndicator = true
        }

        let normalizedX = location.y / size.height
        let normalizedY = 1.0 - (location.x / size.width)
        let normalizedPoint = CGPoint(x: normalizedX, y: normalizedY)

        cameraManager.setFocusAndExposure(normalizedPoint: normalizedPoint)

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                showFocusIndicator = false
            }
        }
    }
}

// MARK: - 对焦框视图
struct FocusIndicatorView: View {
    @State private var scale: CGFloat = 1.5
    @State private var opacity: Double = 0.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 70, height: 70)

            FocusCorners()
                .stroke(Color.yellow, lineWidth: 2.5)
                .frame(width: 70, height: 70)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}

struct FocusCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cornerLength: CGFloat = 15

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerLength))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + cornerLength, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - cornerLength, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerLength))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerLength))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerLength, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + cornerLength, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerLength))

        return path
    }
}

// MARK: - 闪光灯模式
enum FlashMode: String, CaseIterable {
    case on = "on"
    case off = "off"

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .on: return .on
        case .off: return .off
        }
    }
}

// MARK: - 相机管理器
@MainActor
class CameraManager: NSObject, ObservableObject {
    private let preset: FilmPreset
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var videoCaptureDevice: AVCaptureDevice?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    /// 共享 CIContext（复用于旋转处理，避免每次拍照创建）
    private let ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
    private let previewQueue = DispatchQueue(label: "preview.lut.queue")
    /// 专用会话队列（AVCaptureSession 操作必须在同一串行队列）
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")

    /// 线程安全的像素缓冲区（用 os_unfair_lock 保护跨线程访问）
    private let pixelBufferLock = OSAllocatedUnfairLock<CVPixelBuffer?>(initialState: nil)

    nonisolated func getLatestPixelBuffer() -> CVPixelBuffer? {
        pixelBufferLock.withLock { $0 }
    }

    nonisolated func setLatestPixelBuffer(_ buffer: CVPixelBuffer) {
        pixelBufferLock.withLock { $0 = buffer }
    }

    // 预览方向缓存
    fileprivate var previewRotationAngle: CGFloat?
    fileprivate var previewDeviceOrientation: UIDeviceOrientation?
    private var photoDataHandler: ((Data?) -> Void)?
    private var exposureCompleteHandler: (() -> Void)?
    @Published var flashMode: FlashMode = .off

    // 35mm 等效焦距
    private var device35mmEquivalentFocalLength: Float = 0.0
    @Published var targetFocalLength: Float = 35.0
    @Published var currentZoomFactor: CGFloat = 1.0
    private var requiredZoomFactor: CGFloat = 1.0

    // 位置管理器
    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var locationCache: CLLocation?
    private var locationCacheTime: Date = .distantPast
    private let locationCacheExpiry: TimeInterval = 30.0

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

        // 3. 触发后台更新
        locationManager.requestLocation()
        return nil
    }

    // iOS 18 方向管理
    fileprivate var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var currentDeviceOrientation: UIDeviceOrientation = .portrait
    private var orientationObserver: NSObjectProtocol?
    private var subjectAreaObserver: NSObjectProtocol?

    // 拍照曝光补偿
    private var previousExposureTargetBias: Float = 0
    private var lockedExposureForFlashCapture: Bool = false
    private var focusHoldTimer: Timer?
    private let tapFocusHoldDuration: TimeInterval = 3.0

    init(preset: FilmPreset) {
        self.preset = preset
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

    // MARK: - 方向监控

    private func setupOrientationMonitoring() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDeviceOrientation()
            }
        }

        updateDeviceOrientation()
        bootstrapInitialOrientationIfNeeded()
    }

    private func updateDeviceOrientation() {
        let orientation = UIDevice.current.orientation
        if orientation.isValidInterfaceOrientation {
            currentDeviceOrientation = orientation
            previewDeviceOrientation = orientation
            applyVideoOrientationToOutputs()
        }
    }

    private func bootstrapInitialOrientationIfNeeded() {
        if previewDeviceOrientation == nil || previewDeviceOrientation == .unknown {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let io = scene.interfaceOrientation
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

    private func applyVideoOrientationToOutputs() {
        guard let coordinator = rotationCoordinator else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelCapture

        if let pconn = photoOutput.connection(with: .video),
           pconn.isVideoRotationAngleSupported(angle) {
            pconn.videoRotationAngle = angle
        }

        previewRotationAngle = angle
    }

    // MARK: - 对焦

    func setFocusAndExposure(normalizedPoint: CGPoint) {
        guard let device = videoCaptureDevice else { return }

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = normalizedPoint
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = normalizedPoint
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }

            device.unlockForConfiguration()
            startFocusHoldTimer()
        } catch {
            print("❌ 设置对焦失败: \(error)")
        }
    }

    private func startFocusHoldTimer() {
        focusHoldTimer?.invalidate()
        focusHoldTimer = Timer.scheduledTimer(withTimeInterval: tapFocusHoldDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.restoreContinuousFocus()
            }
        }
    }

    private func restoreContinuousFocus() {
        guard let device = videoCaptureDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - 闪光灯曝光补偿

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

    // MARK: - EXIF 方向

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

    fileprivate func orientationFromRotationAngle(_ rotationAngle: CGFloat) -> CGImagePropertyOrientation {
        let normalizedAngle = Int(rotationAngle) % 360
        switch normalizedAngle {
        case 0: return .up
        case 90, -270: return .right
        case 180, -180: return .down
        case 270, -90: return .left
        default: return .up
        }
    }

    // MARK: - 权限与会话

    func requestCameraPermission() {
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                await startSession()
                startLocationServices()
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted {
                    await startSession()
                    startLocationServices()
                }
            default:
                break
            }
        }
    }

    private func setupCamera() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let videoCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }

        self.videoCaptureDevice = videoCaptureDevice
        readCameraSpecs(device: videoCaptureDevice)
        calculateZoomFactorFor35mm()

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)

            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }

            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)

                photoOutput.maxPhotoQualityPrioritization = .speed
                photoOutput.isResponsiveCaptureEnabled = true
                photoOutput.isFastCapturePrioritizationEnabled = true

                let format = videoCaptureDevice.activeFormat
                let supportedDimensions = format.supportedMaxPhotoDimensions

                let preferred = supportedDimensions.filter { dim in
                    let ratio = Float(dim.width) / Float(dim.height)
                    return dim.width <= 4000 && abs(ratio - 4.0/3.0) < 0.1
                }.max { $0.width < $1.width }

                if let selected = preferred {
                    photoOutput.maxPhotoDimensions = selected
                } else if let largest = supportedDimensions.max(by: { $0.width < $1.width }) {
                    photoOutput.maxPhotoDimensions = largest
                }

                rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: videoCaptureDevice,
                    previewLayer: nil
                )
            }

            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                videoDataOutput.setSampleBufferDelegate(self, queue: previewQueue)
                applyVideoOrientationToOutputs()
            }

            // 合并为一次 lockForConfiguration
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
            videoCaptureDevice.isSubjectAreaChangeMonitoringEnabled = true
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

    /// 使用专用串行队列启动会话，避免阻塞主线程
    private func startSession() async {
        guard !session.isRunning else { return }

        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                self?.session.startRunning()
                continuation.resume()
            }
        }

        calculateZoomFactorFor35mm()
        applyVideoOrientationToOutputs()
    }

    // MARK: - 拍照

    func capturePhoto(onExposureComplete: (() -> Void)? = nil, completion: @escaping (Data?) -> Void) {
        photoDataHandler = completion
        exposureCompleteHandler = onExposureComplete

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed

        if let device = videoCaptureDevice, device.hasFlash {
            settings.flashMode = (flashMode == .on) ? .on : .off
            if flashMode == .on {
                let bias = calculateFlashExposureBias(device: device)
                do {
                    try device.lockForConfiguration()
                    previousExposureTargetBias = device.exposureTargetBias
                    let clamped = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, bias))
                    device.setExposureTargetBias(clamped) { _ in }
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                        lockedExposureForFlashCapture = true
                    }
                    device.unlockForConfiguration()
                } catch {}
            }
        }

        settings.embedsDepthDataInPhoto = false
        settings.embedsPortraitEffectsMatteInPhoto = false
        settings.embedsSemanticSegmentationMattesInPhoto = false

        if let coordinator = rotationCoordinator,
           let connection = photoOutput.connection(with: .video) {
            let rotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
        }

        if lockedExposureForFlashCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        } else {
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func toggleFlashMode() {
        flashMode = (flashMode == .on) ? .off : .on
    }

    // MARK: - 35mm 焦距

    private func readCameraSpecs(device: AVCaptureDevice) {
        device35mmEquivalentFocalLength = estimate35mmEquivalentFocalLength()
    }

    private func estimate35mmEquivalentFocalLength() -> Float {
        let modelName = getModelIdentifier()
        if modelName.contains("16 Pro") { return 24.0 }
        if modelName.contains("16") { return 26.0 }
        if modelName.contains("15 Pro") { return 24.0 }
        if modelName.contains("15") { return 26.0 }
        if modelName.contains("14") || modelName.contains("13") || modelName.contains("12") ||
           modelName.contains("11") || modelName.contains("XS") || modelName.contains("XR") { return 26.0 }
        if modelName.contains("8") || modelName.contains("7") || modelName.contains("6") { return 28.0 }
        return 26.0
    }

    private func getModelIdentifier() -> String {
        #if targetEnvironment(simulator)
        return "iPhone 15 Pro (Simulator)"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(Character(UnicodeScalar(UInt8(value))))
        }
        return deviceModelName(from: identifier)
        #endif
    }

    private func deviceModelName(from identifier: String) -> String {
        switch identifier {
        case "iPhone17,1": return "iPhone 16"
        case "iPhone17,2": return "iPhone 16 Plus"
        case "iPhone17,3": return "iPhone 16 Pro"
        case "iPhone17,4": return "iPhone 16 Pro Max"
        case "iPhone16,1": return "iPhone 15"
        case "iPhone16,2": return "iPhone 15 Plus"
        case "iPhone16,3": return "iPhone 15 Pro"
        case "iPhone16,4": return "iPhone 15 Pro Max"
        case "iPhone15,4": return "iPhone 14"
        case "iPhone15,5": return "iPhone 14 Plus"
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,6", "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        case "iPhone13,1": return "iPhone 12 mini"
        case "iPhone13,2": return "iPhone 12"
        case "iPhone13,3": return "iPhone 12 Pro"
        case "iPhone13,4": return "iPhone 12 Pro Max"
        case "iPhone12,1": return "iPhone 11"
        case "iPhone12,3": return "iPhone 11 Pro"
        case "iPhone12,5": return "iPhone 11 Pro Max"
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "iPhone11,8": return "iPhone XR"
        case "iPhone10,3", "iPhone10,6": return "iPhone X"
        case "iPhone10,1", "iPhone10,4": return "iPhone 8"
        case "iPhone10,2", "iPhone10,5": return "iPhone 8 Plus"
        case "iPhone9,1", "iPhone9,3": return "iPhone 7"
        case "iPhone9,2", "iPhone9,4": return "iPhone 7 Plus"
        default: return "iPhone (\(identifier))"
        }
    }

    private func calculateZoomFactorFor35mm() {
        guard let device = videoCaptureDevice else { return }
        let baseEquivalent: Float = device35mmEquivalentFocalLength > 0 ? device35mmEquivalentFocalLength : 26.0
        requiredZoomFactor = CGFloat(targetFocalLength / baseEquivalent)

        let maxZoom = device.activeFormat.videoMaxZoomFactor
        let minZoom = device.minAvailableVideoZoomFactor
        requiredZoomFactor = max(minZoom, min(maxZoom, requiredZoomFactor))

        applyZoomFactor(requiredZoomFactor)
    }

    private func applyZoomFactor(_ zoomFactor: CGFloat) {
        guard let device = videoCaptureDevice else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = zoomFactor
            currentZoomFactor = zoomFactor
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - 位置服务

    private func startLocationServices() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5

        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationUpdates()
        case .notDetermined:
            // 请求授权后等待 delegate 回调 didChangeAuthorization 再启动
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    private func startLocationUpdates() {
        // 将阻塞调用移到后台线程，避免主线程卡顿
        Task.detached {
            let enabled = CLLocationManager.locationServicesEnabled()
            await MainActor.run {
                guard enabled else { return }
                self.locationManager.startUpdatingLocation()
                self.startLocationTimer()
            }
        }
    }

    func stopLocationServices() {
        locationManager.stopUpdatingLocation()
        locationTimer?.invalidate()
        locationTimer = nil
    }

    private var locationTimer: Timer?

    private func startLocationTimer() {
        locationTimer?.invalidate()
        locationTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if CLLocationManager.locationServicesEnabled() {
                    self.locationManager.requestLocation()
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
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("📍 位置获取失败: \(error.localizedDescription)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.startLocationUpdates()
            case .denied, .restricted:
                self.stopLocationServices()
            default:
                break
            }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Task { @MainActor in
            self.exposureCompleteHandler?()
            self.exposureCompleteHandler = nil
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            Task { @MainActor in self.photoDataHandler?(nil) }
            print("❌ [照片] 拍摄错误: \(error)")
            return
        }
        guard let imageData = photo.fileDataRepresentation() else {
            Task { @MainActor in self.photoDataHandler?(nil) }
            return
        }

        // 复用管理器持有的 CIContext（避免每次创建）
        let sharedCIContext = self.ciContext

        Task.detached(priority: .userInitiated) {
            let rotatedData = Self.applyExifOrientationToPixels(imageData: imageData, ciContext: sharedCIContext)

            await MainActor.run {
                self.photoDataHandler?(rotatedData ?? imageData)
            }
        }

        // 恢复曝光
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

    /// 读取 EXIF 方向并物理旋转像素（静态方法，复用 CIContext）
    private nonisolated static func applyExifOrientationToPixels(imageData: Data, ciContext: CIContext) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return imageData
        }

        let orientationValue = properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up

        if orientation == .up { return imageData }

        guard let ciImage = CIImage(data: imageData) else { return imageData }
        let rotatedImage = ciImage.oriented(orientation)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let renderedJPEG = ciContext.jpegRepresentation(of: rotatedImage, colorSpace: colorSpace, options: [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95
        ]) else { return imageData }

        var metadata = properties
        metadata[kCGImagePropertyOrientation as String] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        guard let renderedSource = CGImageSourceCreateWithData(renderedJPEG as CFData, nil),
              let mutableData = CFDataCreateMutable(nil, 0),
              let imageType = CGImageSourceGetType(renderedSource),
              let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
            return imageData
        }

        metadata[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        CGImageDestinationAddImageFromSource(destination, renderedSource, 0, metadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return imageData }
        return mutableData as Data
    }
}

// MARK: - 视频输出：实时预览
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    @preconcurrency nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 直接在 delegate 线程写入（锁保护），避免 MainActor 中转延迟
        self.setLatestPixelBuffer(buffer)
    }
}

// MARK: - 实时预览视图（MTKView + CI 渲染）
struct RealtimePreviewView: UIViewRepresentable {
    let manager: CameraManager
    let preset: FilmPreset

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // Metal 不可用（模拟器等），返回空视图
            let fallback = MTKView(frame: .zero)
            fallback.backgroundColor = .black
            return fallback
        }
        let view = MTKView(frame: .zero, device: device)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 30
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

        func setup(view: MTKView) {
            view.delegate = self
            if let device = view.device {
                commandQueue = device.makeCommandQueue()
                let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                ciContext = CIContext(mtlDevice: device, options: [
                    .workingColorSpace: srgbColorSpace,
                    .outputColorSpace: srgbColorSpace
                ])
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pixelBuffer = manager?.getLatestPixelBuffer(),
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rawExtent = ciImage.extent

            let isLandscapeBuffer = rawExtent.width > rawExtent.height
            let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let isPortraitView = drawableSize.height > drawableSize.width

            if isLandscapeBuffer && isPortraitView {
                ciImage = ciImage.oriented(.right)
            } else if let angle = manager?.previewRotationAngle, angle != 0 {
                let orientation = orientationFromAngle(angle)
                ciImage = ciImage.oriented(orientation)
            }

            let lutImage = FilmProcessor.shared.applyLUT(to: ciImage, preset: preset) ?? ciImage
            let imageExtent = lutImage.extent

            let targetRect = aspectFillRect(imageSize: imageExtent.size, targetSize: drawableSize)

            let scaleX = targetRect.width / imageExtent.width
            let scaleY = targetRect.height / imageExtent.height
            let scaledImage = lutImage
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .transformed(by: CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y))

            let renderBounds = CGRect(origin: .zero, size: drawableSize)
            let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            ciContext.render(scaledImage, to: drawable.texture, commandBuffer: commandBuffer, bounds: renderBounds, colorSpace: srgbColorSpace)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

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

        private func aspectFillRect(imageSize: CGSize, targetSize: CGSize) -> CGRect {
            let imageAspect = imageSize.width / imageSize.height
            let targetAspect = targetSize.width / targetSize.height

            var drawWidth: CGFloat
            var drawHeight: CGFloat

            if imageAspect > targetAspect {
                drawHeight = targetSize.height
                drawWidth = drawHeight * imageAspect
            } else {
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
