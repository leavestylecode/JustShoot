import SwiftUI
import SwiftData
import AVFoundation

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [Photo]
    @State private var isPreloading = true

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(FilmPreset.allCases) { preset in
                        NavigationLink(value: preset) {
                            FilmPresetCard(preset: preset, photoCount: photosCount(for: preset))
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
                    NavigationLink(value: "gallery") {
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
            .navigationDestination(for: String.self) { _ in
                GalleryView()
            }
            .navigationDestination(for: FilmPreset.self) { preset in
                CameraView(preset: preset)
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
        .task {
            await preloadResources()
        }
    }

    private func photosCount(for preset: FilmPreset) -> Int {
        photos.filter { $0.filmPresetName == preset.rawValue }.count
    }

    private func preloadResources() async {
        await Task.detached(priority: .userInitiated) {
            for preset in FilmPreset.allCases {
                FilmProcessor.shared.preload(preset: preset)
            }
        }.value

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
                isPreloading = false
            }
        }
    }
}

// MARK: - 胶片卡片
struct FilmPresetCard: View {
    let preset: FilmPreset
    let photoCount: Int

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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentColor)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(preset.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                HStack(spacing: 8) {
                    Text("ISO \(Int(preset.iso))")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))

                    if photoCount > 0 {
                        Text("\(photoCount) 张")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(accentColor)
                    }
                }
            }

            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
