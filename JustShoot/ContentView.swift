import SwiftUI
import SwiftData
import AVFoundation
import CoreLocation

// MARK: - 按压缩放按钮样式
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [Photo]
    @State private var selectedPreset: FilmPreset?
    @State private var showingGallery = false
    @State private var isPreloading = true

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(FilmPreset.allCases) { preset in
                        FilmPresetCard(preset: preset, rolls: rolls) {
                            selectedPreset = preset
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(Color.black)
            .navigationTitle("JustShoot")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showingGallery = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 15, weight: .medium))
                            if photos.count > 0 {
                                Text("\(photos.count)")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isPreloading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                        Text("正在准备相机...")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.9))
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $selectedPreset) { preset in
            CameraView(preset: preset)
        }
        .fullScreenCover(isPresented: $showingGallery) {
            GalleryView()
        }
        .task {
            await preloadResources()
        }
    }

    @Query(sort: \Roll.createdAt, order: .reverse) private var rolls: [Roll]

    /// 预加载相机资源：LUT 文件 + 相机权限预请求
    private func preloadResources() async {
        // 1. 预加载所有 LUT 文件（后台线程）
        await Task.detached(priority: .userInitiated) {
            for preset in FilmPreset.allCases {
                FilmProcessor.shared.preload(preset: preset)
            }
        }.value

        // 2. 预请求相机权限（让用户提前授权，避免进入相机时弹窗）
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        // 3. 预请求位置权限
        let locationManager = CLLocationManager()
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        // 完成预加载
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
                isPreloading = false
            }
        }
    }
}

// MARK: - 胶卷卡片
struct FilmPresetCard: View {
    let preset: FilmPreset
    let rolls: [Roll]
    let onTap: () -> Void

    @State private var isPressed = false

    private var activeRoll: Roll? {
        rolls.first { $0.presetName == preset.rawValue && !$0.isCompleted }
    }

    private var hasActiveRoll: Bool { activeRoll != nil }
    private var shotsTaken: Int { activeRoll?.shotsTaken ?? 0 }
    private var capacity: Int { activeRoll?.capacity ?? 27 }
    private var progress: CGFloat { CGFloat(shotsTaken) / CGFloat(max(1, capacity)) }

    private var accentColor: Color {
        switch preset {
        case .fujiC200: return Color(red: 0.2, green: 0.7, blue: 0.6)
        case .fujiPro400H: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .fujiProvia100F: return Color(red: 0.3, green: 0.5, blue: 0.9)
        case .kodakPortra400: return Color(red: 0.95, green: 0.5, blue: 0.5)
        case .kodakVision5219: return Color(red: 0.4, green: 0.3, blue: 0.7)
        case .kodakVision5203: return Color(red: 0.3, green: 0.7, blue: 0.8)
        case .kodak5207: return Color(red: 0.4, green: 0.8, blue: 0.6)
        case .harmanPhoenix200: return Color(red: 0.9, green: 0.3, blue: 0.3)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // 左侧色块图标
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentColor)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                )

            // 中间信息
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                HStack(spacing: 8) {
                    Text("ISO \(Int(preset.iso))")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))

                    if hasActiveRoll {
                        Text("\(shotsTaken)/\(capacity)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(accentColor)
                    }
                }
            }

            Spacer()

            // 右侧状态
            VStack(alignment: .trailing, spacing: 6) {
                if hasActiveRoll {
                    // 进度条
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 50, height: 4)
                        Capsule()
                            .fill(accentColor)
                            .frame(width: 50 * progress, height: 4)
                    }
                    Text("继续")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accentColor)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(isPressed ? 0.12 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(hasActiveRoll ? accentColor.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isPressed)
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        }
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}