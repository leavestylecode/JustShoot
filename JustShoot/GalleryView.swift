import SwiftUI
import SwiftData
import PhotosUI

struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.timestamp, order: .reverse) private var photos: [Photo]
    @State private var selectedPhoto: Photo?
    @State private var capturedPhoto: Photo?
    @State private var showingPhotoDetail = false
    
    private let gridColumns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                if photos.isEmpty {
                    VStack {
                        Image(systemName: "photo")
                            .font(.system(size: 100))
                            .foregroundColor(.gray)
                        Text("暂无照片")
                            .font(.title2)
                            .foregroundColor(.gray)
                            .padding(.top, 16)
                        Text("前往拍摄页面开始拍照")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(photos) { photo in
                            PhotoThumbnailView(photo: photo)
                                .aspectRatio(1, contentMode: .fit)
                                .onTapGesture {
                                    selectedPhoto = photo
                                    capturedPhoto = photo
                                    showingPhotoDetail = true
                                }
                        }
                    }
                    .padding(2)
                }
            }
            .navigationTitle("相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                }
            })
        }
        .sheet(isPresented: $showingPhotoDetail) {
            if let photoToShow = selectedPhoto ?? capturedPhoto ?? photos.first {
                PhotoDetailView(photo: photoToShow)
            }
        }
    }
}

struct PhotoThumbnailView: View {
    let photo: Photo
    
    var body: some View {
        Group {
            if let image = photo.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundColor(.gray)
                    )
            }
        }
    }
}

struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.timestamp, order: .reverse) private var allPhotos: [Photo]
    
    let photo: Photo
    @State private var currentPhoto: Photo
    @State private var saveStatus: SaveStatus = .none
    @State private var showingInfo = true
    @State private var currentIndex: Int = 0
    
    enum SaveStatus {
        case none, saving, success, failed
    }
    
    init(photo: Photo) {
        self.photo = photo
        self._currentPhoto = State(initialValue: photo)
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 全屏照片显示区域 - 支持左右滑动
            if !allPhotos.isEmpty {
                TabView(selection: $currentIndex) {
                    ForEach(Array(allPhotos.enumerated()), id: \.element.id) { index, photoItem in
                        GeometryReader { geometry in
                            if let image = photoItem.image {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.black)
                            } else {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .overlay(
                                        VStack {
                                            Image(systemName: "photo")
                                                .font(.system(size: 50))
                                                .foregroundColor(.gray)
                                            Text("图片加载失败")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                                .padding(.top, 8)
                                        }
                                    )
                            }
                        }
                        .tag(index)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingInfo.toggle()
                            }
                        }
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.1), value: currentIndex)
                .onChange(of: currentIndex) { _, newIndex in
                    if newIndex >= 0 && newIndex < allPhotos.count {
                        currentPhoto = allPhotos[newIndex]
                    }
                }
            } else {
                // 没有照片时的占位符
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 100))
                        .foregroundColor(.gray)
                    Text("没有照片")
                        .font(.title2)
                        .foregroundColor(.gray)
                        .padding(.top, 16)
                }
            }
            
            // 顶部工具栏（悬浮）
            VStack {
                if showingInfo {
                    HStack {
                        Button("完成") {
                            dismiss()
                        }
                        .foregroundColor(.white)
                        
                        Spacer()
                        
                        Text("\(currentIndex + 1) / \(allPhotos.count)")
                            .foregroundColor(.white)
                            .font(.caption)
                        
                        Spacer()
                        
                        // 下载按钮
                        Button(action: saveToPhotoLibrary) {
                            HStack(spacing: 4) {
                                Image(systemName: saveButtonIcon)
                                    .foregroundColor(.white)
                                Text(saveButtonText)
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(15)
                        }
                        .disabled(saveStatus == .saving)
                    }
                    .padding()
                    .background(LinearGradient(gradient: Gradient(colors: [Color.black.opacity(0.6), Color.clear]), startPoint: .top, endPoint: .bottom))
                    .transition(.move(edge: .top))
                }
                Spacer()
            }
            
            // 底部信息面板（悬浮，可滚动）
            VStack {
                Spacer()
                if showingInfo {
                    ScrollView {
                        VStack(spacing: 15) {
                            // 拍摄时间
                            VStack(spacing: 4) {
                                Text("拍摄时间")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text("\(currentPhoto.timestamp, formatter: detailDateFormatter)")
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                            
                            VStack(spacing: 15) {
                                // 基本拍摄参数
                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 12) {
                                    ExifInfoView(title: "ISO", value: currentPhoto.iso)
                                    ExifInfoView(title: "快门", value: currentPhoto.shutterSpeed)
                                    ExifInfoView(title: "光圈", value: currentPhoto.aperture)
                                    ExifInfoView(title: "焦距", value: currentPhoto.focalLength)
                                    ExifInfoView(title: "曝光", value: currentPhoto.exposureMode)
                                    ExifInfoView(title: "闪光灯", value: currentPhoto.flashMode)
                                }
                                
                                // GPS位置信息
                                if let gps = currentPhoto.gpsInfo {
                                    VStack(spacing: 8) {
                                        Text("📍 位置信息")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        
                                        LazyVGrid(columns: [
                                            GridItem(.flexible()),
                                            GridItem(.flexible())
                                        ], spacing: 10) {
                                            ExifInfoView(title: "纬度", value: gps.latitude)
                                            ExifInfoView(title: "经度", value: gps.longitude)
                                            ExifInfoView(title: "海拔", value: gps.altitude)
                                            ExifInfoView(title: "镜头", value: currentPhoto.lensInfo)
                                        }
                                    }
                                }
                                
                                // 设备信息
                                if let device = currentPhoto.deviceInfo {
                                    VStack(spacing: 8) {
                                        Text("📱 设备信息")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        
                                        LazyVGrid(columns: [
                                            GridItem(.flexible()),
                                            GridItem(.flexible())
                                        ], spacing: 10) {
                                            ExifInfoView(title: "制造商", value: device.make)
                                            ExifInfoView(title: "型号", value: device.model)
                                            ExifInfoView(title: "软件", value: device.software)
                                            if currentPhoto.gpsInfo == nil {
                                                ExifInfoView(title: "镜头", value: currentPhoto.lensInfo)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical, 20)
                    }
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.4) // 最大占屏幕高度40%
                    .background(LinearGradient(gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.8)]), startPoint: .top, endPoint: .bottom))
                    .transition(.move(edge: .bottom))
                }
            }
        }
        .onAppear {
            initializeCurrentIndex()
        }
    }
    
    private func initializeCurrentIndex() {
        // 查找当前照片在数组中的索引
        for (index, photoItem) in allPhotos.enumerated() {
            if photoItem.id == photo.id {
                currentIndex = index
                currentPhoto = photoItem
                return
            }
        }
        
        // 如果没找到，默认使用第一张
        currentIndex = 0
        if !allPhotos.isEmpty {
            currentPhoto = allPhotos[0]
        }
    }
    
    // 计算属性
    private var saveButtonIcon: String {
        switch saveStatus {
        case .none: return "square.and.arrow.down"
        case .saving: return "square.and.arrow.down"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
    
    private var saveButtonText: String {
        switch saveStatus {
        case .none: return "保存"
        case .saving: return "保存中..."
        case .success: return "已保存"
        case .failed: return "保存失败"
        }
    }
    
    // 日期格式化器
    private var detailDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }
    
    // 保存到照片库
    private func saveToPhotoLibrary() {
        guard let image = currentPhoto.image else {
            print("❌ 保存失败：图片为空")
            return
        }

        saveStatus = .saving
        print("📱 开始保存照片到相册")

        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    self.handleAuthorizationStatus(status, image: image)
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    self.handleAuthorizationStatus(status, image: image)
                }
            }
        }
    }

    private func handleAuthorizationStatus(_ status: PHAuthorizationStatus, image: UIImage) {
        switch status {
        case .authorized, .limited:
            print("✅ 照片库权限获得，开始保存")
            saveImageToPhotoLibrary(image)

        case .denied:
            print("❌ 照片库权限被拒绝")
            saveStatus = .failed
            resetSaveStatus()

        case .restricted:
            print("❌ 照片库权限受限")
            saveStatus = .failed
            resetSaveStatus()

        case .notDetermined:
            print("❌ 照片库权限未确定")
            saveStatus = .failed
            resetSaveStatus()

        @unknown default:
            print("❌ 未知的照片库权限状态")
            saveStatus = .failed
            resetSaveStatus()
        }
    }

    private func saveImageToPhotoLibrary(_ image: UIImage) {
        // 使用原始数据保存以保留完整元数据
        let imageData = currentPhoto.imageData
        
        print("📱 使用原始数据保存照片以保留完整元数据")
        
        PHPhotoLibrary.shared().performChanges({
            // 使用原始数据创建照片请求，这样会保留所有元数据
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: imageData, options: nil)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    print("✅ 照片保存成功（含完整元数据）")
                    self.saveStatus = .success
                } else {
                    print("❌ 照片保存失败: \(error?.localizedDescription ?? "未知错误")")
                    self.saveStatus = .failed
                }
                self.resetSaveStatus()
            }
        }
    }

    private func resetSaveStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveStatus = .none
        }
    }
}

// EXIF 信息组件
struct ExifInfoView: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.caption)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.1))
        .cornerRadius(8)
    }
}

// 导航栏样式扩展
extension View {
    func navigationBarStyle(color: Color, backgroundColor: Color) -> some View {
        self.toolbarBackground(backgroundColor, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
} 