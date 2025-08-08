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
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(FilmPreset.allCases) { preset in
                Button {
                    onSelect(preset)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.filters")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(width: 44, height: 44)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(preset.displayName)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("ISO \(Int(preset.iso))")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 8)
    }
}