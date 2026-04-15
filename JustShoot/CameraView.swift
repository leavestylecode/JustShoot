import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import SwiftData
import CoreLocation
import UIKit
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import os

struct CameraView: View {
    let source: FilmSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var presetPhotos: [Photo]
    @StateObject private var cameraManager: CameraManager
    @State private var showFlash = false
    @State private var isCapturing = false
    @State private var shutterPressed = false
    @State private var lastPhotoThumbnail: UIImage?
    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusIndicator = false
    @State private var showPhotoDetail = false

    init(source: FilmSource) {
        self.source = source
        let filterName = source.photoFilterName
        _presetPhotos = Query(
            filter: #Predicate<Photo> { photo in
                photo.filmPresetName == filterName
            },
            sort: \Photo.timestamp
        )
        _cameraManager = StateObject(wrappedValue: CameraManager())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 预览区
            GeometryReader { geometry in
                ZStack {
                    RealtimePreviewView(manager: cameraManager, lutCacheKey: source.lutCacheKey)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if showFocusIndicator, let point = focusPoint {
                        FocusIndicatorView()
                            .position(point)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleTapToFocus(at: location, in: geometry.size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(3.0/4.0, contentMode: .fit)
            .padding(.horizontal, 4)

            // 权限被拒绝时的引导
            if cameraManager.cameraPermissionDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("需要相机权限")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("请在系统设置中允许 JustShoot 访问相机")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundColor(.black)
                }
                .padding(40)
            }

            // 快门闪光效果
            if showFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.7)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // 左上：返回
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .fontWeight(.semibold)
                }
                .tint(.white)
            }

            // 中间：胶片名 + 拍摄计数
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(source.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text("\(presetPhotos.count) 张")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 右上：闪光灯
            ToolbarItem(placement: .primaryAction) {
                Button {
                    cameraManager.toggleFlashMode()
                } label: {
                    Image(systemName: cameraManager.flashMode == .on ? "bolt.fill" : "bolt.slash.fill")
                }
                .tint(cameraManager.flashMode == .on ? .yellow : .white)
            }
        }
        // 底部控制栏
        .safeAreaInset(edge: .bottom) {
            HStack {
                // 左：最近照片缩略图
                Button { if !presetPhotos.isEmpty { showPhotoDetail = true } } label: {
                    if let thumb = lastPhotoThumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 46, height: 46)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }

                Spacer()

                // 中：快门按钮
                Button(action: capturePhoto) {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(.white)
                            .frame(width: 60, height: 60)
                            .scaleEffect(shutterPressed ? 0.85 : 1.0)
                            .animation(.easeInOut(duration: 0.1), value: shutterPressed)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // 右：占位（保持快门居中）
                Color.clear
                    .frame(width: 46, height: 46)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 10)
        }
        .onAppear {
            FilmProcessor.shared.preload(source: source)
            cameraManager.requestCameraPermission()
            loadLastPhotoThumbnail()
        }
        .onDisappear {
            cameraManager.stopLocationServices()
        }
        .onChange(of: presetPhotos.count) { _, _ in
            loadLastPhotoThumbnail()
        }
        .sheet(isPresented: $showPhotoDetail) {
            if let latest = presetPhotos.last {
                NavigationStack {
                    PhotoDetailView(photo: latest, allPhotos: presetPhotos)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { showPhotoDetail = false } label: {
                                    Image(systemName: "xmark")
                                        .fontWeight(.semibold)
                                }
                                .tint(.white)
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(false)
                .preferredColorScheme(.dark)
            }
        }
    }

    private func loadLastPhotoThumbnail() {
        guard let photo = presetPhotos.last else {
            lastPhotoThumbnail = nil
            return
        }
        Task {
            let thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: 88)
            await MainActor.run {
                lastPhotoThumbnail = thumb
            }
        }
    }

    private func capturePhoto() {
        // 防止重复拍摄
        guard !isCapturing else {
            Log.capture.debug("shutter_ignored reason=busy")
            return
        }

        let tapTime = Log.now()
        Log.capture.info("shutter_tap source=\(source.photoFilterName, privacy: .public)")

        isCapturing = true
        shutterPressed = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let currentSource = source
        let manager = cameraManager
        let context = modelContext

        cameraManager.capturePhoto(onExposureComplete: { [self] in
            Log.capture.info("exposure_complete dt_from_tap=\(Log.ms(since: tapTime))ms")
            Task { @MainActor in
                // 曝光已完成：立刻释放按钮按压视觉，贴近原生相机手感
                shutterPressed = false
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
                shutterPressed = false
            }

            guard let data = imageData else {
                Log.capture.error("photo_data_nil dt_from_tap=\(Log.ms(since: tapTime))ms")
                return
            }
            Log.capture.info("photo_data_received bytes=\(data.count) dt_from_tap=\(Log.ms(since: tapTime))ms")

            Task.detached(priority: .userInitiated) {
                let location = await manager.cachedOrFreshLocation()
                Log.gps.info("gps_resolved present=\(location != nil) age=\(location.map { String(format: "%.1fs", Date().timeIntervalSince($0.timestamp)) } ?? "nil", privacy: .public)")

                let processedData = FilmProcessor.shared.applyLUTPreservingMetadata(
                    imageData: data,
                    lutCacheKey: currentSource.lutCacheKey,
                    outputQuality: 0.95,
                    location: location
                )

                let finalData = processedData ?? data
                if processedData == nil {
                    Log.capture.error("lut_fallback_raw bytes=\(finalData.count)")
                }

                await MainActor.run {
                    Self.savePhotoToContext(
                        imageData: finalData,
                        source: currentSource,
                        location: location,
                        context: context
                    )
                    Log.capture.info("capture_pipeline_complete total_dt=\(Log.ms(since: tapTime))ms")
                }
            }
        }
    }

    @MainActor
    private static func savePhotoToContext(
        imageData: Data,
        source: FilmSource,
        location: CLLocation?,
        context: ModelContext
    ) {
        let newPhoto = Photo(imageData: imageData, filmPresetName: source.photoFilterName)
        // 自定义 LUT 存储显示名称
        if case .custom(_, let name, _, _) = source {
            newPhoto.filmDisplayLabel = name
        }
        if let loc = location {
            newPhoto.latitude = loc.coordinate.latitude
            newPhoto.longitude = loc.coordinate.longitude
            newPhoto.altitude = loc.altitude
            newPhoto.locationTimestamp = loc.timestamp
        }

        context.insert(newPhoto)

        do {
            try context.save()
            Log.save.info("photo_saved id=\(newPhoto.id.uuidString, privacy: .public) bytes=\(imageData.count) preset=\(source.photoFilterName, privacy: .public) gps=\(location != nil)")
        } catch {
            Log.save.error("photo_save_failed error=\(error.localizedDescription, privacy: .public)")
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
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.yellow, lineWidth: 1)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    scale = 1.0
                    opacity = 1.0
                }
            }
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
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var videoCaptureDevice: AVCaptureDevice?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let previewQueue = DispatchQueue(label: "preview.lut.queue")
    /// 专用会话队列（AVCaptureSession 操作必须在同一串行队列）
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")

    /// CVPixelBuffer 的 Sendable 包装（CVBuffer 本身不符合 Sendable，但通过锁保护是安全的）
    private struct SendableBuffer: @unchecked Sendable {
        var buffer: CVPixelBuffer?
    }

    /// 线程安全的像素缓冲区（用 os_unfair_lock 保护跨线程访问）
    private let pixelBufferLock = OSAllocatedUnfairLock(initialState: SendableBuffer())

    nonisolated func getLatestPixelBuffer() -> CVPixelBuffer? {
        pixelBufferLock.withLockUnchecked { $0.buffer }
    }

    nonisolated func setLatestPixelBuffer(_ buffer: CVPixelBuffer) {
        pixelBufferLock.withLockUnchecked { $0.buffer = buffer }
    }

    /// 首帧到达标记（线程安全，仅打印一次）
    private let firstFrameFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
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

        // startUpdatingLocation 已在持续更新，无需额外请求
        return nil
    }

    // iOS 18 方向管理
    fileprivate var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var currentDeviceOrientation: UIDeviceOrientation = .portrait
    private var orientationObserver: NSObjectProtocol?
    private var subjectAreaObserver: NSObjectProtocol?

    // 权限状态
    @Published var cameraPermissionDenied: Bool = false

    // 拍照曝光补偿
    private var previousExposureTargetBias: Float = 0
    private var lockedExposureForFlashCapture: Bool = false
    private var focusHoldTimer: Timer?
    private let tapFocusHoldDuration: TimeInterval = 3.0

    override init() {
        super.init()
        // Lightweight init: only find device and read specs, no session configuration
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            videoCaptureDevice = device
            readCameraSpecs(device: device)
        }
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

        if previewRotationAngle != angle {
            Log.orientation.info("rotation_applied angle=\(Int(angle))° device=\(self.currentDeviceOrientation.rawValue)")
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
            Log.session.info("permission_camera_status status=\(status.rawValue)")
            switch status {
            case .authorized:
                cameraPermissionDenied = false
                await configureAndStartSession()
                startLocationServices()
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                Log.session.info("permission_camera_result granted=\(granted)")
                if granted {
                    cameraPermissionDenied = false
                    await configureAndStartSession()
                    startLocationServices()
                } else {
                    cameraPermissionDenied = true
                }
            case .denied, .restricted:
                Log.session.error("permission_camera_denied")
                cameraPermissionDenied = true
            @unknown default:
                break
            }
        }
    }

    /// 在专用串行队列上配置并启动 AVCaptureSession，避免阻塞主线程
    private func configureAndStartSession() async {
        guard !session.isRunning, let device = videoCaptureDevice else {
            Log.session.debug("session_config_skip running=\(self.session.isRunning) has_device=\(self.videoCaptureDevice != nil)")
            return
        }
        let configTimer = Log.perf("session_configure", logger: Log.session)
        Log.session.info("session_config_begin device=\(device.localizedName, privacy: .public)")

        let captureSession = session
        let output = photoOutput
        let videoOutput = videoDataOutput

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                captureSession.beginConfiguration()
                captureSession.sessionPreset = .photo

                do {
                    let videoInput = try AVCaptureDeviceInput(device: device)

                    if captureSession.canAddInput(videoInput) {
                        captureSession.addInput(videoInput)
                    }

                    if captureSession.canAddOutput(output) {
                        captureSession.addOutput(output)

                        output.maxPhotoQualityPrioritization = .speed
                        output.isResponsiveCaptureEnabled = true
                        output.isFastCapturePrioritizationEnabled = true

                        let format = device.activeFormat
                        let supportedDimensions = format.supportedMaxPhotoDimensions

                        let preferred = supportedDimensions.filter { dim in
                            let ratio = Float(dim.width) / Float(dim.height)
                            return dim.width <= 4000 && abs(ratio - 4.0/3.0) < 0.1
                        }.max { $0.width < $1.width }

                        if let selected = preferred {
                            output.maxPhotoDimensions = selected
                        } else if let largest = supportedDimensions.max(by: { $0.width < $1.width }) {
                            output.maxPhotoDimensions = largest
                        }
                    }

                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    if captureSession.canAddOutput(videoOutput) {
                        captureSession.addOutput(videoOutput)
                    }

                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    if device.isSmoothAutoFocusSupported {
                        device.isSmoothAutoFocusEnabled = true
                    }
                    device.isSubjectAreaChangeMonitoringEnabled = true
                    device.unlockForConfiguration()
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
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        videoDataOutput.setSampleBufferDelegate(self, queue: previewQueue)
        calculateZoomFactorFor35mm()
        applyVideoOrientationToOutputs()
        configTimer.end("zoom=\(String(format: "%.2f", currentZoomFactor))x")

        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: device,
            queue: .main
        ) { _ in }
    }

    // MARK: - 拍照

    func capturePhoto(onExposureComplete: (() -> Void)? = nil, completion: @escaping (Data?) -> Void) {
        photoDataHandler = completion
        exposureCompleteHandler = onExposureComplete

        let issueTime = Log.now()
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

        // 抓取当前 rotation 角度（避免在 sessionQueue 跨 actor 访问）
        let rotationAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let output = photoOutput
        let delegate = self
        let needsFlashDelay = lockedExposureForFlashCapture

        // 调度到 sessionQueue：AVCapturePhotoOutput 操作不占用主线程，快门响应更快
        let deadline: DispatchTime = needsFlashDelay ? .now() + 0.20 : .now()
        Log.capture.info("capture_dispatch flash=\(self.flashMode.rawValue, privacy: .public) flash_delay=\(needsFlashDelay ? 200 : 0)ms rotation=\(rotationAngle.map { "\(Int($0))°" } ?? "nil", privacy: .public)")
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

    func toggleFlashMode() {
        flashMode = (flashMode == .on) ? .off : .on
    }

    // MARK: - 35mm 焦距

    private func readCameraSpecs(device: AVCaptureDevice) {
        device35mmEquivalentFocalLength = estimate35mmEquivalentFocalLength()
    }

    private func estimate35mmEquivalentFocalLength() -> Float {
        let modelName = getModelIdentifier()
        if modelName.contains("17 Pro") { return 24.0 }
        if modelName.contains("17") { return 24.0 }
        if modelName.contains("16e") { return 26.0 }
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
        case "iPhone18,1": return "iPhone 17"
        case "iPhone18,2": return "iPhone 17 Air"
        case "iPhone18,3": return "iPhone 17 Pro"
        case "iPhone18,4": return "iPhone 17 Pro Max"
        case "iPhone17,5": return "iPhone 16e"
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
        locationManager.startUpdatingLocation()
    }

    func stopLocationServices() {
        locationManager.stopUpdatingLocation()
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.gps.error("gps_fail error=\(error.localizedDescription, privacy: .public)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            Log.gps.info("gps_auth_changed status=\(status.rawValue)")
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
        Log.capture.info("delegate_did_capture dims=\(resolvedSettings.photoDimensions.width)x\(resolvedSettings.photoDimensions.height)")
        Task { @MainActor in
            self.exposureCompleteHandler?()
            self.exposureCompleteHandler = nil
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
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
        Task { @MainActor in
            self.photoDataHandler?(imageData)
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
}

// MARK: - 视频输出：实时预览
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    @preconcurrency nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 直接在 delegate 线程写入（锁保护），避免 MainActor 中转延迟
        self.setLatestPixelBuffer(buffer)
        self.logFirstFrameOnce(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }
}

// MARK: - 实时预览视图（全 Metal 管线：CVPixelBuffer → compute shader → drawable）
struct RealtimePreviewView: UIViewRepresentable {
    let manager: CameraManager
    let lutCacheKey: String

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            let fallback = MTKView(frame: .zero)
            fallback.backgroundColor = .black
            return fallback
        }
        let view = MTKView(frame: .zero, device: device)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = false  // 允许 compute shader 写入 drawable
        view.preferredFramesPerSecond = 30
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.coordinator.setup(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.lutCacheKey = lutCacheKey
        context.coordinator.manager = manager
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Metal Preview Coordinator
    final class Coordinator: NSObject, MTKViewDelegate {
        var lutCacheKey: String = ""
        weak var manager: CameraManager?

        // Metal 核心对象
        private var metalDevice: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var computePipeline: MTLComputePipelineState?

        // CVPixelBuffer → MTLTexture 零拷贝缓存
        private var textureCache: CVMetalTextureCache?

        // 3D LUT 纹理缓存（每个预设一个，首次使用时创建）
        private var lutTextures: [String: MTLTexture] = [:]
        private var lutDimensions: [String: Int] = [:]

        // Shader 参数结构（必须与 LUTShader.metal 中的 PreviewParams 一致）
        private struct PreviewParams {
            var scale: Float
            var offsetX: Float
            var offsetY: Float
            var inputWidth: UInt32
            var inputHeight: UInt32
            var rotation: UInt32
            var lutDimension: UInt32
        }

        func setup(view: MTKView) {
            guard let device = view.device else { return }
            metalDevice = device
            commandQueue = device.makeCommandQueue()
            view.delegate = self

            // 创建 CVMetalTextureCache（零拷贝访问相机像素缓冲区）
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache

            // 加载 compute shader
            guard let library = device.makeDefaultLibrary(),
                  let function = library.makeFunction(name: "previewLUT") else {
                print("[Metal] Failed to load previewLUT shader")
                return
            }
            computePipeline = try? device.makeComputePipelineState(function: function)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        // MARK: - 每帧渲染（全 Metal，无 CIImage/CIFilter）

        // 一次性诊断用计数器
        private var skipFrameCount: Int = 0
        private var didLogFirstDraw: Bool = false

        func draw(in view: MTKView) {
            guard let pixelBuffer = manager?.getLatestPixelBuffer(),
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let pipeline = computePipeline,
                  let cache = textureCache else {
                skipFrameCount += 1
                // 每 60 帧（约 2s）打一次 skip 原因，避免日志洪水
                if skipFrameCount % 60 == 1 {
                    let hasBuffer = manager?.getLatestPixelBuffer() != nil
                    let hasDrawable = view.currentDrawable != nil
                    let hasPipeline = computePipeline != nil
                    let hasCache = textureCache != nil
                    Log.session.error("preview_skip n=\(self.skipFrameCount) buf=\(hasBuffer) drawable=\(hasDrawable) pipeline=\(hasPipeline) cache=\(hasCache)")
                }
                return
            }
            if !didLogFirstDraw {
                didLogFirstDraw = true
                Log.session.info("preview_first_draw skipped=\(self.skipFrameCount) lut_key=\(self.lutCacheKey, privacy: .public)")
            }

            let inW = CVPixelBufferGetWidth(pixelBuffer)
            let inH = CVPixelBufferGetHeight(pixelBuffer)

            // CVPixelBuffer → MTLTexture（零拷贝，GPU 直接读取相机帧内存）
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil,
                .bgra8Unorm, inW, inH, 0, &cvTexture
            )
            guard status == kCVReturnSuccess,
                  let cvTex = cvTexture,
                  let inputTexture = CVMetalTextureGetTexture(cvTex) else { return }

            // 获取或创建 3D LUT 纹理
            guard let lutTexture = getOrCreateLUTTexture(cacheKey: lutCacheKey) else { return }
            let lutDim = lutDimensions[lutCacheKey] ?? 25

            let outW = drawable.texture.width
            let outH = drawable.texture.height

            // 计算旋转参数
            let isLandscape = inW > inH
            let isPortraitView = outH > outW
            var rotation: UInt32 = 0
            if isLandscape && isPortraitView {
                rotation = 1  // 90° CW
            } else if let angle = manager?.previewRotationAngle, angle != 0 {
                rotation = rotationFromAngle(angle)
            }

            // 计算 aspect-fill 参数
            let rotatedW: Float
            let rotatedH: Float
            if rotation == 1 || rotation == 3 {
                rotatedW = Float(inH)
                rotatedH = Float(inW)
            } else {
                rotatedW = Float(inW)
                rotatedH = Float(inH)
            }

            let scaleX = Float(outW) / rotatedW
            let scaleY = Float(outH) / rotatedH
            let scale = max(scaleX, scaleY)
            let offsetX = (Float(outW) - rotatedW * scale) / 2.0
            let offsetY = (Float(outH) - rotatedH * scale) / 2.0

            var params = PreviewParams(
                scale: scale,
                offsetX: offsetX,
                offsetY: offsetY,
                inputWidth: UInt32(inW),
                inputHeight: UInt32(inH),
                rotation: rotation,
                lutDimension: UInt32(lutDim)
            )

            // 编码 compute 命令
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(lutTexture, index: 1)
            encoder.setTexture(drawable.texture, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<PreviewParams>.size, index: 0)

            // 使用 dispatchThreads（iOS 11+ / A11+，精确线程数）
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: outW, height: outH, depth: 1)
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - 3D LUT 纹理管理

        private func getOrCreateLUTTexture(cacheKey: String) -> MTLTexture? {
            if let cached = lutTextures[cacheKey] { return cached }

            guard let device = metalDevice else { return nil }

            // 从 FilmProcessor 缓存获取 LUT 数据
            guard let lut = FilmProcessor.shared.getCachedLUT(cacheKey: cacheKey) else { return nil }
            let dim = lut.dimension

            // 创建 3D 纹理（硬件三线性插值采样）
            let desc = MTLTextureDescriptor()
            desc.textureType = .type3D
            desc.pixelFormat = .rgba32Float
            desc.width = dim
            desc.height = dim
            desc.depth = dim
            desc.usage = [.shaderRead]
            desc.storageMode = .shared

            guard let texture = device.makeTexture(descriptor: desc) else { return nil }

            lut.data.withUnsafeBytes { ptr in
                texture.replace(
                    region: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: dim, height: dim, depth: dim)
                    ),
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: ptr.baseAddress!,
                    bytesPerRow: dim * 4 * MemoryLayout<Float>.size,
                    bytesPerImage: dim * dim * 4 * MemoryLayout<Float>.size
                )
            }

            lutTextures[cacheKey] = texture
            lutDimensions[cacheKey] = dim
            return texture
        }

        private func rotationFromAngle(_ angle: CGFloat) -> UInt32 {
            let normalized = Int(angle.truncatingRemainder(dividingBy: 360))
            switch normalized {
            case 90:  return 1  // 90° CW
            case 180: return 2
            case 270: return 3
            default:  return 0
            }
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
