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
import AVKit
import os

/// 跳转到当前 App 的系统设置页。两处权限被拒流程（相机、定位）共用。
@MainActor
private func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}

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
                    // 单镜头 + 帧桥接：W↔T swap 时 cameraManager.bridgeImage 先盖一帧 LUT 后的快照，
                    // swap + AE 收敛 ~250ms 后再淡出。比之前 ultraThinMaterial 干净，比 multi-cam 保留 12MP。
                    RealtimePreviewView(manager: cameraManager, lutCacheKey: source.lutCacheKey)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            if let bridge = cameraManager.bridgeImage {
                                Image(uiImage: bridge)
                                    .resizable()
                                    .scaledToFill()
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.22), value: cameraManager.bridgeImage != nil)

                    if showFocusIndicator, let point = focusPoint {
                        FocusIndicatorView()
                            .position(point)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleTapToFocus(at: location, in: geometry.size)
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            cameraManager.handlePinchZoom(scale: value.magnification)
                        }
                        .onEnded { _ in
                            cameraManager.finishPinchZoom()
                        }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 2:3 纵向 = 135 全画幅胶片画幅。预览与成片对齐（在 applyLUTPreservingMetadata
            // 里同步裁 4:3 → 2:3），35mm 档拍出来的视场和真 135/35mm 一致：横向、纵向、画幅
            // 三件套全对得上，不再是「同对角 FOV 的 4:3 框」。
            .aspectRatio(2.0/3.0, contentMode: .fit)
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
                    Button("打开设置", action: openAppSettings)
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
                .accessibilityLabel("返回")
            }

            // 中间：胶片名 + 拍摄计数 + 可选的位置状态
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(source.displayName)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 6) {
                        Text("\(presetPhotos.count) 张")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if cameraManager.locationPermissionDenied {
                            Button(action: openAppSettings) {
                                Label("位置已关闭", systemImage: "location.slash.fill")
                                    .font(.caption2.weight(.medium))
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(.orange.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("位置已关闭")
                            .accessibilityHint("前往系统设置，允许定位以给照片添加地理位置")
                        }
                    }
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
                .accessibilityLabel(cameraManager.flashMode == .on ? "闪光灯：开启" : "闪光灯：关闭")
                .accessibilityHint("切换闪光灯开关")
            }
        }
        // 底部控制栏
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 14) {
                FocalLengthStrip(
                    focalInfo: cameraManager.focalInfo,
                    current: cameraManager.currentFocalLength
                ) { option in
                    cameraManager.hapticSoft.impactOccurred()
                    cameraManager.setFocalLength(option)
                }

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
                .accessibilityLabel(presetPhotos.isEmpty ? "最近的照片" : "最近的照片 — 共 \(presetPhotos.count) 张")
                .accessibilityHint(presetPhotos.isEmpty ? "暂无照片" : "查看大图")
                .disabled(presetPhotos.isEmpty)

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
                .accessibilityLabel("拍照")
                .accessibilityHint("拍摄一张照片")

                Spacer()

                // 右：当前胶片封面缩略图（与左侧最近照片对称）。
                // 列表 tile 通过 navigationTransition(.zoom) 放大成本页时，封面落位在这里。
                // 暂作展示用；后续会挂点击扩展功能。
                FilmSourceCoverThumbnail(source: source)
                    .frame(width: 46, height: 46)
                }
                .padding(.horizontal, 30)
            }
            .padding(.bottom, 10)
        }
        .onAppear {
            FilmProcessor.shared.preload(source: source)
            cameraManager.currentLutCacheKey = source.lutCacheKey
            cameraManager.requestCameraPermission()
            loadLastPhotoThumbnail()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        // Camera Control 硬件快门按钮（iPhone 16+）
        .onCameraCaptureEvent { event in
            if event.phase == .ended {
                capturePhoto()
            }
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
        Task { @MainActor in
            let thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: 88)
            lastPhotoThumbnail = thumb
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
        cameraManager.hapticMedium.impactOccurred()

        let currentSource = source
        let manager = cameraManager
        // ModelContainer 是 Sendable；ModelContext 不是。跨 Task.detached 边界只能传 container，
        // 保存时再 hop 回 @MainActor 读取 mainContext。
        let container = modelContext.container

        let focalMm = cameraManager.currentFocalLength.rawValue
        cameraManager.capturePhoto(onExposureComplete: {
            Log.capture.info("exposure_complete dt_from_tap=\(Log.ms(since: tapTime))ms")
            // 曝光已完成：立刻释放按钮按压视觉，贴近原生相机手感
            Task { @MainActor in
                shutterPressed = false
                withAnimation(.easeOut(duration: 0.05)) {
                    showFlash = true
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
                withAnimation(.easeIn(duration: 0.1)) {
                    showFlash = false
                }
            }
        }) { imageData in
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
                    location: location,
                    focalLengthIn35mm: focalMm
                )

                let finalData = processedData ?? data
                if processedData == nil {
                    Log.capture.error("lut_fallback_raw bytes=\(finalData.count)")
                }

                await Self.savePhotoToContainer(
                    imageData: finalData,
                    source: currentSource,
                    location: location,
                    container: container
                )
                Log.capture.info("capture_pipeline_complete total_dt=\(Log.ms(since: tapTime))ms")
            }
        }
    }

    @MainActor
    private static func savePhotoToContainer(
        imageData: Data,
        source: FilmSource,
        location: CLLocation?,
        container: ModelContainer
    ) {
        let context = container.mainContext
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
        cameraManager.hapticLight.impactOccurred()

        focusPoint = location

        withAnimation(.easeOut(duration: 0.15)) {
            showFocusIndicator = true
        }

        // 坐标转换：视图坐标 → AVFoundation 归一化坐标
        // AVFoundation 使用横屏坐标系：{0,0} 左上，{1,1} 右下（Home 键在右）
        let normalizedX = location.y / size.height
        let normalizedY = 1.0 - (location.x / size.width)
        let normalizedPoint = CGPoint(x: normalizedX, y: normalizedY)

        cameraManager.setFocusAndExposure(normalizedPoint: normalizedPoint)

        // 对焦框跟随 focusHoldTimer 消失（3s 后恢复连续对焦时隐藏）
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !cameraManager.isFocusLocked {
                withAnimation(.easeOut(duration: 0.3)) {
                    showFocusIndicator = false
                }
            }
        }
    }
}

// MARK: - 焦段切换条（仿 iPhone 相机样式）
struct FocalLengthStrip: View {
    let focalInfo: DeviceFocalInfo
    let current: FocalLengthOption
    let onSelect: (FocalLengthOption) -> Void

    var body: some View {
        if focalInfo.options.count <= 1 {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                ForEach(focalInfo.options) { option in
                    Button { onSelect(option) } label: {
                        focalButton(for: option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.rawValue) 毫米等效焦距")
                    .accessibilityAddTraits(option == current ? [.isButton, .isSelected] : .isButton)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("焦距选择")
        }
    }

    @ViewBuilder
    private func focalButton(for option: FocalLengthOption) -> some View {
        let isSelected = option == current
        let isCrop = focalInfo.isDigitalCrop(option)

        Text(option.label)
            .font(.system(size: 13, weight: isSelected ? .bold : .regular, design: .rounded))
            .foregroundStyle(isSelected ? .yellow : isCrop ? .white.opacity(0.4) : .white.opacity(0.65))
            .frame(width: 40, height: 40)
            .background {
                if isSelected {
                    Circle()
                        .fill(.white.opacity(0.15))
                        .frame(width: 36, height: 36)
                }
            }
            .contentShape(Circle())
            .animation(.spring(duration: 0.25, bounce: 0.1), value: isSelected)
    }
}

// MARK: - 对焦完成通知
extension Notification.Name {
    static let focusDidComplete = Notification.Name("JustShoot.focusDidComplete")
}

// MARK: - 对焦框视图（响应对焦完成 KVO）
struct FocusIndicatorView: View {
    @State private var scale: CGFloat = 1.4
    @State private var opacity: Double = 0.0
    @State private var focusLocked = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.yellow, lineWidth: focusLocked ? 1.5 : 1)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.65)) {
                    scale = 1.0
                    opacity = 1.0
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusDidComplete)) { _ in
                withAnimation(.easeInOut(duration: 0.15)) {
                    focusLocked = true
                    scale = 0.9
                }
                withAnimation(.easeOut(duration: 0.1).delay(0.15)) {
                    scale = 1.0
                }
            }
    }
}

// MARK: - 拍摄页右下角胶片封面缩略图
/// 拍摄页右下角的胶片封面缩略图（与左下最近照片缩略图对称）。
/// FilmSource.preset → 加载胶片图鉴的 libraryCardImage；FilmSource.custom → 配色 + 滤镜图标
/// （和列表 CustomLUTTile 一致）。列表 tile 通过 navigationTransition(.zoom) 放大成本页时，
/// 视觉上封面落位在这里。当前仅展示，后续会挂点击交互。
struct FilmSourceCoverThumbnail: View {
    let source: FilmSource
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private static let customAccent = Color(red: 0.6, green: 0.5, blue: 0.8)
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        ZStack {
            switch source {
            case .preset:
                Color.white.opacity(0.05)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            case .custom:
                Self.customAccent.opacity(0.18)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Self.customAccent)
            }
        }
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .task(id: source.id) {
            // 46pt × scale ≈ 138 px；预留余量取 200，与列表缓存的 cacheKey 解耦避免反复解码。
            guard case .preset(let preset) = source else {
                image = nil
                return
            }
            let pixel = max(Int(46.0 * displayScale * 1.5), 100)
            image = await FilmCardImageCache.shared.loadImage(
                imageName: preset.libraryCardImage,
                cacheKey: "thumb_\(preset.rawValue)",
                maxPixel: pixel
            )
        }
        .accessibilityLabel("当前胶片：\(source.displayName)")
    }
}

// MARK: - 等效焦距档位
enum FocalLengthOption: Int, CaseIterable, Identifiable {
    case mm13 = 13
    case mm24 = 24
    case mm35 = 35
    case mm50 = 50
    case mm100 = 100
    case mm200 = 200

    var id: Int { rawValue }
    var mm: Float { Float(rawValue) }
    var label: String { "\(rawValue)" }
}

// MARK: - 设备焦段信息（基于物理 wide + telephoto，不走虚拟设备）
struct DeviceFocalInfo {
    /// 可用焦段选项
    let options: [FocalLengthOption]
    /// 主摄 W 的 35mm 等效焦距（如 17 Pro = 24mm）
    let wideMm: Float
    /// 长焦 T 的 35mm 等效焦距（0 表示无长焦）
    let teleMm: Float

    /// 该档位应使用哪颗物理镜头。100mm/200mm 优先 telephoto；其余用 wide。
    func deviceType(for option: FocalLengthOption) -> AVCaptureDevice.DeviceType {
        if (option == .mm100 || option == .mm200) && teleMm > 0 {
            return .builtInTelephotoCamera
        }
        return .builtInWideAngleCamera
    }

    /// 该档位在目标镜头上的 zoom factor（mm ÷ 该镜头原生 mm）
    func zoomFactor(for option: FocalLengthOption) -> CGFloat {
        let nativeMm = (deviceType(for: option) == .builtInTelephotoCamera) ? teleMm : wideMm
        guard nativeMm > 0 else { return 1.0 }
        return CGFloat(option.mm / nativeMm)
    }

    /// 是否纯数字裁切（zoom 显著大于 1.0× = 不是镜头原生视野）
    func isDigitalCrop(_ option: FocalLengthOption) -> Bool {
        zoomFactor(for: option) > 1.05
    }

    /// 默认值（session 未配置前的临时占位）
    static let placeholder = DeviceFocalInfo(options: [.mm24, .mm35], wideMm: 24, teleMm: 0)

    /// 在 wide/tele 设备 activeFormat 已配置好之后调用。
    /// - Parameter wide: 必须存在；用于读 wideMm 和 zoom 上限
    /// - Parameter tele: 可选；存在则启用 100/200mm 档位
    static func from(wide: AVCaptureDevice, tele: AVCaptureDevice?) -> DeviceFocalInfo {
        let wideMm = wide.nominalFocalLengthIn35mmFilm > 0 ? wide.nominalFocalLengthIn35mmFilm : 26.0
        let teleMm = (tele?.nominalFocalLengthIn35mmFilm ?? 0) > 0 ? (tele?.nominalFocalLengthIn35mmFilm ?? 0) : 0
        let wideMaxZoom = wide.activeFormat.videoMaxZoomFactor
        let teleMaxZoom = tele?.activeFormat.videoMaxZoomFactor ?? 0

        let info = DeviceFocalInfo(
            options: [.mm24, .mm35, .mm50, .mm100, .mm200],
            wideMm: wideMm,
            teleMm: teleMm
        )

        // 过滤掉超出物理可达 zoom 的档位
        var options: [FocalLengthOption] = info.options.filter { opt in
            let zoom = info.zoomFactor(for: opt)
            let maxZ = (info.deviceType(for: opt) == .builtInTelephotoCamera) ? teleMaxZoom : wideMaxZoom
            return zoom >= 0.99 && zoom <= maxZ + 0.01
        }

        // 长焦缺失或原生焦距不够，移除依赖长焦的档位
        if teleMm <= 0 {
            options.removeAll { $0 == .mm100 || $0 == .mm200 }
        } else {
            if teleMm < 70 { options.removeAll { $0 == .mm100 } }
            if teleMm < 100 { options.removeAll { $0 == .mm200 } }
        }
        if !options.contains(.mm24) { options.insert(.mm24, at: 0) }

        let optical = options.filter { !info.isDigitalCrop($0) }.map { $0.rawValue }
        Log.session.info("focal_info wide=\(wideMm)mm tele=\(teleMm)mm wide_maxZoom=\(String(format: "%.1f", wideMaxZoom)) tele_maxZoom=\(String(format: "%.1f", teleMaxZoom)) options=\(options.map { $0.rawValue }) optical=\(optical)")

        return DeviceFocalInfo(options: options, wideMm: wideMm, teleMm: teleMm)
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
    /// 单镜头 AVCaptureSession：保留 12MP 4:3 全画幅；W↔T 物理切换通过 swapInputDevice 完成，
    /// 用 bridgeImage 帧桥接遮住 swap+AE 收敛的 ~250ms 过渡，视觉接近 iPhone 原相机。
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    /// 后置主摄（24mm 等效），始终存在
    private var wideDevice: AVCaptureDevice?
    /// 后置长焦（100mm 等效），可能为 nil（无长焦机型）
    private var teleDevice: AVCaptureDevice?
    /// 当前 session 的视频输入；通过 swapInputDevice 在 W ⇄ T 之间切换
    private var currentVideoInput: AVCaptureDeviceInput?
    /// 当前激活的设备（focus / exposure / zoom 都打在它身上）
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

    /// 获取最新帧（用于 MTKView 渲染 + bridgeImage 抓帧）
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

    /// W↔T 切镜过渡桥：物理 swap 之前抓当前预览帧（已套用 LUT + 旋转），盖在 MTKView 上。
    /// swap + AE 收敛完成后再淡出，把 ~280ms 黑屏 + AE 突跳合并成一次干净的 cross-fade。
    @Published private(set) var bridgeImage: UIImage?

    /// 当前 LUT 缓存 key（CameraView 在 onAppear 时写入）。bridgeImage 渲染时用它套色。
    var currentLutCacheKey: String = ""

    /// 单调递增 token：用于丢弃过时 swap 的清理回调（用户快速来回点档位时不会让旧任务把
    /// bridgeImage 提前撤掉）。
    private var swapToken: UInt64 = 0

    /// 用于桥接帧渲染的 CIContext（首次访问时初始化，~50ms 一次性成本）
    private lazy var bridgeContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let mtl = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: mtl, options: [
                .workingColorSpace: srgb,
                .outputColorSpace: srgb
            ])
        }
        return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
    }()

    /// 抓取最新预览帧并套用当前 LUT + 旋转，渲染成 UIImage 用作切镜桥接遮罩。
    /// 与 MTKView 渲染管线视觉一致——cross-fade 不会出现颜色跳变。
    @MainActor
    private func makeBridgeImage(lutCacheKey: String) -> UIImage? {
        guard let (buffer, _) = getLatestFrame() else { return nil }
        var ciImage = CIImage(cvPixelBuffer: buffer)

        if let lut = FilmProcessor.shared.getCachedLUT(cacheKey: lutCacheKey),
           let colorCube = CIFilter(name: "CIColorCubeWithColorSpace") {
            colorCube.setValue(ciImage, forKey: kCIInputImageKey)
            colorCube.setValue(lut.dimension, forKey: "inputCubeDimension")
            colorCube.setValue(lut.data, forKey: "inputCubeData")
            if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
                colorCube.setValue(srgb, forKey: "inputColorSpace")
            }
            if let out = colorCube.outputImage {
                ciImage = out
            }
        }

        if let angle = previewRotationAngle, Int(angle) % 360 != 0 {
            ciImage = ciImage.oriented(orientationFromRotationAngle(angle))
        }

        guard let cgImage = bridgeContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 弱引用 MTKView，用于从相机回调触发渲染
    weak var previewMTKView: MTKView?

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

    // 震动反馈（预创建复用，减少首次延迟）
    let hapticLight = UIImpactFeedbackGenerator(style: .light)
    let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
    let hapticSoft = UIImpactFeedbackGenerator(style: .soft)

    // 等效焦距
    @Published var currentFocalLength: FocalLengthOption = .mm35
    @Published var focalInfo: DeviceFocalInfo = .placeholder
    @Published var currentZoomFactor: CGFloat = 1.0
    private var zoomObservation: NSKeyValueObservation?
    private var pinchDidSwitch = false  // 一次捏合手势只切换一档
    private var focalLengthPicker: AVCaptureIndexPicker?
    /// 系统级 EV 滑块（iOS 18+）；device-bound——swap 时必须 remove + re-add 才能跟到新设备。
    private var exposureBiasSlider: AVCaptureSystemExposureBiasSlider?

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

    // iOS 18 方向管理（每次 swap 后重建 RotationCoordinator）
    fileprivate var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var currentDeviceOrientation: UIDeviceOrientation = .portrait
    private var orientationObserver: (any NSObjectProtocol)?
    private var subjectAreaObserver: (any NSObjectProtocol)?

    // 权限状态
    @Published var cameraPermissionDenied: Bool = false
    /// 定位权限被拒绝或受限时，UI 显示「位置已关闭」提示
    @Published var locationPermissionDenied: Bool = false

    /// 仅在值真正变化时写入 @Published 属性，避免无意义的 objectWillChange 发布
    private func setCameraDenied(_ denied: Bool) {
        if cameraPermissionDenied != denied { cameraPermissionDenied = denied }
    }
    private func setLocationDenied(_ denied: Bool) {
        if locationPermissionDenied != denied { locationPermissionDenied = denied }
    }

    // 拍照曝光补偿
    private var previousExposureTargetBias: Float = 0
    private var lockedExposureForFlashCapture: Bool = false
    /// 闪光灯拍摄期间的 WB 状态：lock 一帧防止白平衡跳变，capture 完成后还原。
    private var lockedWBForFlashCapture: Bool = false
    private var previousWBMode: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance
    private var focusHoldTimer: Timer?
    private let tapFocusHoldDuration: TimeInterval = 3.0
    private var focusObservation: NSKeyValueObservation?
    private var pressureObservation: NSKeyValueObservation?
    /// 进入相机时启动 session 的任务句柄；离开时取消，避免在 sessionQueue 上做完整 startRunning 后又被立即停止
    private var startupTask: Task<Void, Never>?
    /// 正常情况下的目标帧率；由 sessionQueue 写入、压力回调 KVO 读取，用锁保护避免数据竞争
    private let nominalFPSLock = OSAllocatedUnfairLock<Double>(initialState: 30.0)
    @Published var isFocusLocked = false

    override init() {
        super.init()
        let (wide, tele) = Self.discoverPhysicalCameras()
        wideDevice = wide
        teleDevice = tele
        Log.session.info("camera_devices_discovered wide=\(wide?.localizedName ?? "nil", privacy: .public) tele=\(tele?.localizedName ?? "nil", privacy: .public)")
        setupOrientationMonitoring()
    }

    /// 用 DiscoverySession 查找后置物理 wide 与 telephoto。
    /// 不再用虚拟设备（TripleCamera 等），因为它的 switchover 策略会让 zoom < 2× 时
    /// 落到 ultra wide 上，且 .locked behavior 受 pipeline 时序影响不可靠。
    /// 物理设备一颗就是一颗，selecting which device == selecting which lens。
    private static func discoverPhysicalCameras() -> (wide: AVCaptureDevice?, tele: AVCaptureDevice?) {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        )
        let wide = session.devices.first { $0.deviceType == .builtInWideAngleCamera }
        let tele = session.devices.first { $0.deviceType == .builtInTelephotoCamera }
        return (wide, tele)
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

            isFocusLocked = true
            startFocusHoldTimer()
        } catch {
            Log.session.error("focus_set_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 对焦完成回调（KVO isAdjustingFocus → false）
    private func onFocusCompleted() {
        // 对焦完成后可用于触发 UI 更新（如对焦框缩小动画）
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

    /// 在专用串行队列上配置并启动 AVCaptureSession。单镜头模式：wide 启动、tele 预热 format（启动期就把
    /// tele 的 4:3 高分辨率 format 选好，swap 路径上零 reconfig）。切镜走 swapInputDevice + bridgeImage cross-fade。
    private func configureAndStartSession() async {
        guard !session.isRunning, let device = wideDevice else {
            Log.session.debug("session_config_skip running=\(self.session.isRunning) has_wide=\(self.wideDevice != nil)")
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

                    self.applyBestFormatAndModes(on: device)

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
        videoDataOutput.setSampleBufferDelegate(self, queue: previewQueue)

        // 预配置 telephoto 的 activeFormat（一次性，与 wide 同样选 4:3 高分辨率）。
        // 这样后续 swapInputDevice(to: tele) 时 format 已经就绪，swap 路径只做 input 切换。
        if let tele = teleDevice {
            await preconfigureFormat(on: tele)
        }

        // Session 已配置，wide 和 tele 的 activeFormat / nominalFocalLengthIn35mmFilm 都已可用
        focalInfo = DeviceFocalInfo.from(wide: device, tele: teleDevice)
        if !focalInfo.options.contains(currentFocalLength) {
            currentFocalLength = focalInfo.options.contains(.mm35) ? .mm35 : (focalInfo.options.first ?? .mm24)
        }

        applyFocalLength(currentFocalLength, animated: false)
        applyVideoOrientationToOutputs()
        configTimer.end("zoom=\(String(format: "%.2f", currentZoomFactor))x")

        dumpLensSpecs(device: device)

        // Camera Control 硬件支持（iPhone 16+）：离散焦段选择器
        if currentVideoInput != nil {
            let titles = focalInfo.options.map { "\($0.rawValue)mm" }
            let picker = AVCaptureIndexPicker("焦距", symbolName: "camera.metering.spot", localizedIndexTitles: titles)
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
    }

    // MARK: - 设备配置 / 物理镜头切换（W ⇄ T）

    /// 给指定设备选好 4:3 高分辨率 format 并设置焦点/曝光/帧率。
    /// 必须在 sessionQueue 调用。设备不必在 session 中（用于预配置 telephoto）。
    nonisolated private func applyBestFormatAndModes(on device: AVCaptureDevice) {
        let currentDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let bestFormat = device.formats
            .filter { fmt in
                let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                guard d.width > 0, d.height > 0 else { return false }
                let aspect = Float(d.width) / Float(d.height)
                let supports30 = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30.0 }
                return abs(aspect - 4.0 / 3.0) < 0.02 && supports30
            }
            .max { lhs, rhs in
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
                    Log.session.info("active_format_set device=\(device.localizedName, privacy: .public) dims=\(newDims.width)x\(newDims.height)")
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
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            device.isSubjectAreaChangeMonitoringEnabled = true

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
    /// 策略：挑 ≤28M 像素的最大 4:3 dim——优先 24MP（5712×4284 类），次选 12MP，拒 48MP。
    /// 24MP 让 35/50/200mm 的数字裁切保留 ~10MP 真实细节；24/100mm 也享受 sensor 高分辨率
    /// 读出再下采样的过采样锐度。48MP 文件膨胀 4×、LUT 处理时间 3×，边际增益不值。
    nonisolated private func applyMaxPhotoDimensions(output: AVCapturePhotoOutput, device: AVCaptureDevice) {
        let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
        let cap = 28_000_000
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

    /// 安装/重装系统 EV 滑块（绑定到指定设备）。AVCaptureSystemExposureBiasSlider 是 device-bound 的，
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

    /// 在启动时为后备 telephoto 预配置 format（避免 swap 路径上做这件事）
    private func preconfigureFormat(on device: AVCaptureDevice) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.applyBestFormatAndModes(on: device)
                continuation.resume()
            }
        }
    }

    /// 切换 session 输入到指定物理设备。负责：
    /// 1) sessionQueue 上做 begin/removeInput/addInput/photoOutputDims/commit（format 已预配置过）
    /// 2) 回到 MainActor 重建 rotationCoordinator、重绑 zoom/focus/pressure KVO
    /// 3) UI 端在调用前已抓 bridgeImage 盖住预览，swap 完成后再淡出，整体接近 iPhone 原相机切焦体验
    private func swapInputDevice(to target: AVCaptureDevice) async {
        if currentVideoInput?.device === target { return }

        let captureSession = session
        let output = photoOutput
        let from = currentVideoInput?.device.localizedName ?? "nil"
        let swapTimer = Log.perf("swap_input", logger: Log.session)
        Log.session.info("swap_input_begin from=\(from, privacy: .public) to=\(target.localizedName, privacy: .public)")

        let newInput: AVCaptureDeviceInput? = await withCheckedContinuation { (continuation: CheckedContinuation<AVCaptureDeviceInput?, Never>) in
            sessionQueue.async {
                captureSession.beginConfiguration()

                for input in captureSession.inputs {
                    captureSession.removeInput(input)
                }

                var added: AVCaptureDeviceInput?
                do {
                    let inp = try AVCaptureDeviceInput(device: target)
                    if captureSession.canAddInput(inp) {
                        captureSession.addInput(inp)
                        added = inp
                    } else {
                        Log.session.error("swap_input_cannot_add target=\(target.localizedName, privacy: .public)")
                    }
                } catch {
                    Log.session.error("swap_input_create_failed error=\(error.localizedDescription, privacy: .public)")
                }

                // format 启动时已为 wide/tele 各配过；swap 路径只重置 photoOutput 输出尺寸即可
                self.applyMaxPhotoDimensions(output: output, device: target)

                captureSession.commitConfiguration()
                continuation.resume(returning: added)
            }
        }

        currentVideoInput = newInput
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: target, previewLayer: nil)
        bindDeviceObservers(to: target)
        // EV 滑块绑定到旧设备，重装到新设备
        installExposureBiasSlider(for: target)
        applyVideoOrientationToOutputs()

        let activeDims = CMVideoFormatDescriptionGetDimensions(target.activeFormat.formatDescription)
        let outDims = photoOutput.maxPhotoDimensions
        Log.session.info("swap_complete device=\(target.localizedName, privacy: .public) active_dims=\(activeDims.width)x\(activeDims.height) photo_dims=\(outDims.width)x\(outDims.height) zoom=\(String(format: "%.2f", target.videoZoomFactor))")

        swapTimer.end("device=\(target.localizedName)")
    }

    /// 把 zoom / focus / pressure KVO 重新绑到当前激活设备。swap 后必须调用。
    private func bindDeviceObservers(to device: AVCaptureDevice) {
        zoomObservation?.invalidate()
        focusObservation?.invalidate()
        pressureObservation?.invalidate()

        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] dev, change in
            guard let self, let newZoom = change.newValue else { return }
            let isRamping = dev.isRampingVideoZoom
            Task { @MainActor in
                self.currentZoomFactor = newZoom
                if isRamping { return }
                let nativeMm = (dev.deviceType == .builtInTelephotoCamera) ? self.focalInfo.teleMm : self.focalInfo.wideMm
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
    }

    // MARK: - 系统压力自适应帧率

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

    // MARK: - 拍照

    func capturePhoto(onExposureComplete: (() -> Void)? = nil, completion: @escaping (Data?) -> Void) {
        photoDataHandler = completion
        exposureCompleteHandler = onExposureComplete

        let issueTime = Log.now()
        let settings = AVCapturePhotoSettings()
        // 与 photoOutput.maxPhotoQualityPrioritization 一致：.balanced 走完整原生管线
        // （Deep Fusion / Smart HDR / Photonic Engine），同步交付高质量数据再过 LUT。
        settings.photoQualityPrioritization = .balanced

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
                    // 锁 WB：闪光灯触发会让 AWB 突跳一帧，引入色温/染色偏移；锁住后 capture 完成再还原。
                    // 已锁 AE 的同时也锁 WB，组合出 iPhone 原相机闪光下的稳色感。
                    if device.isWhiteBalanceModeSupported(.locked), device.whiteBalanceMode != .locked {
                        previousWBMode = device.whiteBalanceMode
                        device.whiteBalanceMode = .locked
                        lockedWBForFlashCapture = true
                    }
                    device.unlockForConfiguration()
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

    // MARK: - 设备数据 dump（调试用）

    /// 一次性打印当前后置镜头/会话的所有可读数据，便于调试与设备适配。
    /// 必须在 session 配置完成后调用，否则 activeFormat / 缩放范围 / maxPhotoDimensions 会读到默认值。
    private func dumpLensSpecs(device: AVCaptureDevice) {
        let log = Log.session
        let modelID = Self.hardwareModelIdentifier()
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

        // 2) 物理镜头清单（W + T，可能 T 为 nil）
        let wMm = self.wideDevice?.nominalFocalLengthIn35mmFilm ?? 0
        let tMm = self.teleDevice?.nominalFocalLengthIn35mmFilm ?? 0
        log.info("📷 physical_cameras wide=\(self.wideDevice?.localizedName ?? "nil", privacy: .public)/\(String(format: "%.1f", wMm))mm tele=\(self.teleDevice?.localizedName ?? "nil", privacy: .public)/\(String(format: "%.1f", tMm))mm")
        log.info("📷 optics current_device=\(device.localizedName, privacy: .public) aperture=f/\(String(format: "%.2f", device.lensAperture)) wideMm=\(self.focalInfo.wideMm) teleMm=\(self.focalInfo.teleMm) focalOptions=\(self.focalInfo.options.map { $0.rawValue }, privacy: .public)")

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
            switch self.photoOutput.maxPhotoQualityPrioritization {
            case .speed: return "speed"
            case .balanced: return "balanced"
            case .quality: return "quality"
            @unknown default: return "unknown"
            }
        }()
        log.info("📷 photo_caps supported=[\(photoDims, privacy: .public)] selected=\(outDims.width)x\(outDims.height) responsive=\(self.photoOutput.isResponsiveCaptureEnabled) fast_capture=\(self.photoOutput.isFastCapturePrioritizationEnabled) zsl=\(self.photoOutput.isZeroShutterLagEnabled) constant_color=\(self.photoOutput.isConstantColorSupported) quality_pri=\(qPri, privacy: .public)")

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

        // 8.5) 视频防抖（OIS / 软件复合）。photoOutput 没有 stabilization API；只能从 videoDataOutput
        // 的 connection 上读 active mode。100/200mm tele 端裁切大、抖动放大，调试时这条很有用。
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

        // 10) 全部 format 列表（精简：dims + fov + 最大帧率）
        for (i, f) in device.formats.enumerated() {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let maxFPS = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let isActive = (f === fmt) ? " *" : ""
            log.info("📷 format[\(i)]\(isActive, privacy: .public) dims=\(d.width)x\(d.height) fov=\(String(format: "%.1f", f.videoFieldOfView))° max_fps=\(Int(maxFPS)) binned=\(f.isVideoBinned) hdr=\(f.isVideoHDRSupported)")
        }

        log.info("📷 lens_dump_end")
    }

    /// 原始硬件标识（如 "iPhone18,3"）。仅用于日志排查，不再参与焦距推算
    /// （iOS 26 的 `nominalFocalLengthIn35mmFilm` 已让查表式硬编码彻底过时）。
    private static func hardwareModelIdentifier() -> String {
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

    /// 外部入口：切换等效焦距
    func setFocalLength(_ option: FocalLengthOption, animated: Bool = true) {
        guard focalInfo.options.contains(option) else { return }
        let previousZoom = currentZoomFactor
        syncCurrentFocalLength(option)
        applyFocalLength(option, animated: animated, fromZoom: previousZoom)
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

    // MARK: - 捏合切换焦段（一次手势只切换一档）

    func handlePinchZoom(scale: CGFloat) {
        guard !pinchDidSwitch else { return }
        let threshold: CGFloat = 1.15  // 缩放超过 15% 触发切换
        let options = focalInfo.options
        guard let currentIdx = options.firstIndex(of: currentFocalLength) else { return }

        if scale > threshold, currentIdx + 1 < options.count {
            pinchDidSwitch = true
            hapticMedium.impactOccurred()
            setFocalLength(options[currentIdx + 1])
        } else if scale < 1.0 / threshold, currentIdx > 0 {
            pinchDidSwitch = true
            hapticMedium.impactOccurred()
            setFocalLength(options[currentIdx - 1])
        }
    }

    func finishPinchZoom() {
        pinchDidSwitch = false
    }

    /// 切焦距：需要换物理镜头时先抓 bridgeImage 盖住预览，sessionQueue 上完成 swap，
    /// 等 ~250ms 让新镜头 AE/WB 收敛 + 1-2 帧抵达 MTKView，再清空 bridgeImage 触发 SwiftUI 淡出。
    /// 视觉效果：用户看到的是「上一帧定格 → 平滑过渡到新镜头」，没有黑帧、没有 AE 突跳。
    private func applyFocalLength(_ option: FocalLengthOption, animated: Bool = true, fromZoom: CGFloat? = nil) {
        let targetType = focalInfo.deviceType(for: option)
        let target: AVCaptureDevice? = (targetType == .builtInTelephotoCamera) ? teleDevice : wideDevice
        guard let target else {
            Log.session.error("focal_apply_no_device type=\(targetType.rawValue, privacy: .public) option=\(option.rawValue)")
            return
        }

        let needSwap = (currentVideoInput?.device !== target)
        let zoomOnTarget = focalInfo.zoomFactor(for: option)

        if needSwap {
            // 用户快速来回点档位时，旧 swap 完成回调中的 bridgeImage 清理必须被丢弃，
            // 否则会把过时回调把 bridge 提前撤掉，露出还没收敛好的画面。
            swapToken &+= 1
            let myToken = swapToken

            // 1. 抓 bridge 帧（与当前预览像素级一致）
            if let bridge = makeBridgeImage(lutCacheKey: currentLutCacheKey) {
                bridgeImage = bridge
            }

            // 2. swap → ramp zoom → 等 AE 收敛 → 淡出 bridge
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.swapInputDevice(to: target)
                guard self.swapToken == myToken else {
                    Log.session.info("focal_apply_obsolete option=\(option.rawValue) token=\(myToken) latest=\(self.swapToken)")
                    return
                }
                self.applyZoomOnly(zoomOnTarget, on: target, animated: animated, fromZoom: fromZoom, option: option)
                // 30fps ≈ 33ms/frame；250ms ≈ 7-8 帧。新镜头 AE/WB 收敛 + 几帧到达 MTKView。
                try? await Task.sleep(for: .milliseconds(250))
                guard self.swapToken == myToken else { return }
                self.bridgeImage = nil
            }
        } else {
            applyZoomOnly(zoomOnTarget, on: target, animated: animated, fromZoom: fromZoom, option: option)
        }
    }

    /// 在已经是目标设备的前提下，单纯设置 zoom（带 ramp 动画）。
    private func applyZoomOnly(_ zoom: CGFloat, on device: AVCaptureDevice, animated: Bool, fromZoom: CGFloat?, option: FocalLengthOption) {
        let maxZoom = device.activeFormat.videoMaxZoomFactor
        let minZoom = device.minAvailableVideoZoomFactor
        let clamped = max(minZoom, min(maxZoom, zoom))

        do {
            try device.lockForConfiguration()
            if animated {
                // 自适应速率：跨度越大越快，小幅切换更柔和，接近 iPhone 原相机体验
                let ratio = fromZoom.map { max(clamped / $0, $0 / clamped) } ?? 2.0
                let rate: Float = if ratio < 1.5 {
                    4.0    // 小幅切换（如 24→35）：柔和
                } else if ratio < 3.0 {
                    8.0    // 中等跨度（如 24→50）
                } else {
                    16.0   // 大幅跨度
                }
                device.ramp(toVideoZoomFactor: clamped, withRate: rate)
            } else {
                device.videoZoomFactor = clamped
            }
            currentZoomFactor = clamped
            device.unlockForConfiguration()
            Log.session.info("focal_applied target=\(option.rawValue)mm zoom=\(String(format: "%.2f", clamped))x device=\(device.localizedName, privacy: .public) animated=\(animated)")
        } catch {
            Log.session.error("focal_apply_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 位置服务

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

    func stopLocationServices() {
        locationManager.stopUpdatingLocation()
    }

    /// 停止 session 并释放相机资源（导航离开时调用，防止多 session 竞争）
    func stopSession() {
        // 取消可能仍在 await configureAndStartSession 的启动任务，
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
        currentVideoInput = nil
        bridgeImage = nil
        // 清空 buffer（避免 stopRunning 后 MTKView 还显示上次的 frame）
        pixelBufferLock.withLockUnchecked { $0.buffer = nil }
        // 取消 NotificationCenter observer（deinit 因 Swift 6 隔离规则无法访问这些属性）
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
        }
        if let subjectObserver = subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectObserver)
            subjectAreaObserver = nil
        }
        // 平衡 setupOrientationMonitoring 中的 begin 调用
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
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

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
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
                    if self.lockedWBForFlashCapture, device.isWhiteBalanceModeSupported(self.previousWBMode) {
                        device.whiteBalanceMode = self.previousWBMode
                        self.lockedWBForFlashCapture = false
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
        // 事件驱动渲染：只在新帧到达时绘制（由相机回调触发 setNeedsDisplay）
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = false  // 允许 compute shader 写入 drawable
        // 预览降分辨率：2x 而非 3x，减少 55% 像素量
        view.contentScaleFactor = min(context.environment.displayScale, 2.0)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.autoResizeDrawable = true
        context.coordinator.setup(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.lutCacheKey = lutCacheKey
        context.coordinator.manager = manager
        manager.previewMTKView = uiView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Metal Preview Coordinator
    // @MainActor：MTKViewDelegate.draw 在主线程触发（enableSetNeedsDisplay=true），
    // 同时需要访问 @MainActor 的 CameraManager 属性（previewRotationAngle 等）
    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var lutCacheKey: String = ""
        weak var manager: CameraManager?

        // Metal 核心对象
        private var metalDevice: (any MTLDevice)?
        private var commandQueue: (any MTLCommandQueue)?
        private var computePipeline: (any MTLComputePipelineState)?

        // CVPixelBuffer → MTLTexture 零拷贝缓存
        private var textureCache: CVMetalTextureCache?

        // 3D LUT 纹理缓存（每个预设一个，首次使用时创建）
        private var lutTextures: [String: any MTLTexture] = [:]
        private var lutDimensions: [String: Int] = [:]

        // Triple-buffer 信号量：限制 GPU 最多 3 帧 in-flight，防止命令堆积
        // nonisolated：`DispatchSemaphore` 线程安全，且 GPU completion handler 在后台线程触发
        nonisolated private let inflightSemaphore = DispatchSemaphore(value: 3)

        // 帧去重：避免同一相机帧被渲染两次
        private var lastRenderedFrameId: UInt64 = 0

        // 纹理缓存刷新计数器
        private var frameCount: UInt32 = 0

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
            // 设置最大 in-flight command buffers
            commandQueue?.label = "com.justshoot.preview"
            view.delegate = self

            // 创建 CVMetalTextureCache（零拷贝访问相机像素缓冲区）
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache

            // 加载 compute shader
            guard let library = device.makeDefaultLibrary(),
                  let function = library.makeFunction(name: "previewLUT") else {
                Log.session.error("metal_shader_load_failed")
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
            // 帧去重：如果相机没有产生新帧，跳过渲染
            guard let (pixelBuffer, frameId) = manager?.getLatestFrame(),
                  frameId != lastRenderedFrameId else {
                return
            }

            // Triple-buffer 背压控制：如果 GPU 有 3 帧在队列中，跳过当前帧
            guard inflightSemaphore.wait(timeout: .now()) == .success else {
                return
            }

            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let pipeline = computePipeline,
                  let cache = textureCache else {
                inflightSemaphore.signal()
                skipFrameCount += 1
                if skipFrameCount % 60 == 1 {
                    Log.session.error("preview_skip n=\(self.skipFrameCount)")
                }
                return
            }

            lastRenderedFrameId = frameId

            if !didLogFirstDraw {
                didLogFirstDraw = true
                Log.session.info("preview_first_draw skipped=\(self.skipFrameCount) lut_key=\(self.lutCacheKey, privacy: .public)")
            }

            // 定期刷新纹理缓存，释放不再使用的 CVMetalTexture（每 300 帧 ≈ 10s）
            frameCount &+= 1
            if frameCount % 300 == 0 {
                CVMetalTextureCacheFlush(cache, 0)
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
                  let inputTexture = CVMetalTextureGetTexture(cvTex) else {
                inflightSemaphore.signal()
                return
            }

            // 获取或创建 3D LUT 纹理
            guard let lutTexture = getOrCreateLUTTexture(cacheKey: lutCacheKey) else {
                inflightSemaphore.signal()
                return
            }
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
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                inflightSemaphore.signal()
                return
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(lutTexture, index: 1)
            encoder.setTexture(drawable.texture, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<PreviewParams>.size, index: 0)

            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: outW, height: outH, depth: 1)
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)

            encoder.endEncoding()

            // GPU 完成后释放信号量，允许下一帧排队
            // 捕获 semaphore 本身（值语义 nonisolated），避免把 @MainActor self 带入 Sendable 闭包
            let semaphore = self.inflightSemaphore
            commandBuffer.addCompletedHandler { _ in
                semaphore.signal()
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - 3D LUT 纹理管理

        private func getOrCreateLUTTexture(cacheKey: String) -> (any MTLTexture)? {
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
