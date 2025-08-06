import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [Photo]
    @State private var showingCamera = false
    @State private var showingGallery = false
    
    var body: some View {
        // 打印数据存储位置
        let _ = print("📂 SwiftData存储位置:")
        let _ = print("📍 Documents目录: \(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "未知")")
        
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
                    
                    // 主要功能按钮
                    VStack(spacing: 20) {
                        // 相机按钮
                        Button(action: {
                            showingCamera = true
                        }) {
                            HStack {
                                Image(systemName: "camera.fill")
                                    .font(.title2)
                                Text("拍照")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(Color.white)
                            .cornerRadius(15)
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
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
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView()
        }
        .fullScreenCover(isPresented: $showingGallery) {
            GalleryView()
        }
    }
} 