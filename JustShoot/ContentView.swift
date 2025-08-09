import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [Photo]
    @State private var selectedPreset: FilmPreset?
    @State private var showingGallery = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // 渐变背景
                LinearGradient(
                    gradient: Gradient(colors: [Color.black, Color.gray.opacity(0.8)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 40) {
                    Spacer()
                    
                    // App标题
                    VStack(spacing: 8) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                        Text("JustShoot")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        Text("简单 · 纯粹 · 专业")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Spacer()
                    
                    // 四个胶片入口
                    VStack(spacing: 14) {
                        FilmPresetGrid { preset in
                            selectedPreset = preset
                        }

                        // 相册按钮
                        Button(action: {
                            showingGallery = true
                        }) {
                            HStack {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.title2)
                                Text("相册 (\(photos.count))")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(15)
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.horizontal, 40)
                    
                    Spacer()
                }
            }
            .navigationBarHidden(true)
        }
        .fullScreenCover(item: $selectedPreset) { preset in
            CameraView(preset: preset)
        }
        .fullScreenCover(isPresented: $showingGallery) {
            GalleryView()
        }
    }
} 

// MARK: - 胶片预设宫格
struct FilmPresetGrid: View {
    let onSelect: (FilmPreset) -> Void
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    @Query(sort: \Roll.createdAt, order: .reverse) private var rolls: [Roll]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(FilmPreset.allCases) { preset in
                Button {
                    onSelect(preset)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        let active = rolls.first { $0.presetName == preset.rawValue && !$0.isCompleted }
                        let isContinue = (active != nil)
                        let remaining = active?.exposuresRemaining ?? 27
                        let shots = (active?.shotsTaken ?? 0)
                        let capacity = (active?.capacity ?? 27)
                        let accent = accentColor(for: preset)

                        VStack(spacing: 10) {
                            Image(systemName: "camera.filters")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(accent.opacity(0.9))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(preset.displayName)
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text("ISO \(Int(preset.iso))")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.8))
                                if isContinue {
                                    Text("剩余 \(remaining)")
                                        .font(.caption2)
                                        .foregroundColor(accent)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [accent.opacity(0.22), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            if isContinue {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(height: 6)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(accent.opacity(0.9))
                                            .frame(width: max(6, CGFloat(shots) / CGFloat(max(1, capacity)) * UIScreen.main.bounds.width / 2.2), height: 6)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 8)
                            }
                        }
                        // 右上角状态圆点：黄=继续，绿=新建
                        Circle()
                            .fill((isContinue ? Color.yellow : Color.green).opacity(0.95))
                            .frame(width: 10, height: 10)
                            .padding(10)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func accentColor(for preset: FilmPreset) -> Color {
        switch preset {
        case .fujiC200: return Color.teal
        case .fujiPro400H: return Color.orange
        case .fujiProvia100F: return Color.blue
        case .kodakPortra400: return Color.pink
        case .kodakVision5219: return Color.indigo
        case .kodakVision5203: return Color.cyan
        case .kodak5207: return Color.mint
        case .harmanPhoenix200: return Color.red
        }
    }
}