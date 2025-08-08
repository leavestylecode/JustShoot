import SwiftUI
import SwiftData
import PhotosUI
import ImageIO

// MARK: - 图片加载器
class ImageLoader: ObservableObject {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    
    init() {
        // 设置缓存限制
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }
    
    // 详情页预览：按给定像素下采样，避免解码原图
    func loadPreview(for photo: Photo, maxPixel: Int) async -> UIImage? {
        let key = "preview_\(photo.id.uuidString)_\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // 磁盘缓存优先
        if let url = previewURL(for: photo, maxPixel: maxPixel),
           fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            cache.setObject(img, forKey: key)
            return img
        }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let src = CGImageSourceCreateWithData(photo.imageData as CFData, options as CFDictionary) else { return nil }
            let downOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 256),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, downOptions as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cgThumb)
            self.cache.setObject(image, forKey: key)
            // 持久化至磁盘
            if let url = self.previewURL(for: photo, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.9) {
                try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: url, options: .atomic)
            }
            return image
        }.value
    }

    // 生成缩略图（使用 CGImageSource 硬件加速缩放，极快）
    func loadThumbnail(for photo: Photo, maxPixel: Int) async -> UIImage? {
        let key = "thumb_\(photo.id.uuidString)_\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // 磁盘缓存优先
        if let url = thumbnailURL(for: photo, maxPixel: maxPixel),
           fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            cache.setObject(img, forKey: key)
            return img
        }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let src = CGImageSourceCreateWithData(photo.imageData as CFData, options as CFDictionary) else { return nil }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 96),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cgThumb)
            self.cache.setObject(image, forKey: key)
            // 持久化至磁盘
            if let url = self.thumbnailURL(for: photo, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.85) {
                try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: url, options: .atomic)
            }
            return image
        }.value
    }

    private func thumbsDirectory() -> URL? {
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Thumbs", isDirectory: true)
    }

    private func thumbnailURL(for photo: Photo, maxPixel: Int) -> URL? {
        guard let dir = thumbsDirectory() else { return nil }
        return dir.appendingPathComponent("\(photo.id.uuidString)_t_\(maxPixel).jpg")
    }

    private func previewDirectory() -> URL? {
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Previews", isDirectory: true)
    }

    private func previewURL(for photo: Photo, maxPixel: Int) -> URL? {
        guard let dir = previewDirectory() else { return nil }
        return dir.appendingPathComponent("\(photo.id.uuidString)_p_\(maxPixel).jpg")
    }
    
    private func optimizeImage(_ image: UIImage, for photo: Photo) -> UIImage {
        let maxSize = CGSize(width: 1200, height: 1200) // 限制最大尺寸
        
        let size = image.size
        if size.width <= maxSize.width && size.height <= maxSize.height {
            return image
        }
        
        let scale = min(maxSize.width / size.width, maxSize.height / size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let optimizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return optimizedImage ?? image
    }
    
    func clearCache() {
        cache.removeAllObjects()
    }
}

// MARK: - 照片详情视图模型
class PhotoDetailViewModel: ObservableObject {
    @Published var currentPhoto: Photo
    @Published var loadedImages: [UUID: UIImage] = [:]
    @Published var isLoading: Bool = false
    
    let imageLoader = ImageLoader.shared
    private let allPhotos: [Photo]
    
    init(photo: Photo, allPhotos: [Photo]) {
        self.currentPhoto = photo
        self.allPhotos = allPhotos
    }
    
    func loadImage(for photo: Photo) {
        let photoId = photo.id
        if loadedImages[photoId] != nil { return }

        Task { @MainActor in
            isLoading = true
        }

        let maxPixel = Int(max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let image = await self.imageLoader.loadPreview(for: photo, maxPixel: maxPixel)
            await MainActor.run {
                if let image = image {
                    self.loadedImages[photoId] = image
                }
                self.isLoading = false
            }
        }
    }
    
    func preloadImages(around index: Int) {
        let range = max(0, index - 1)...min(allPhotos.count - 1, index + 1)
        
        Task { @MainActor in
            for i in range {
                let photo = allPhotos[i]
                self.loadImage(for: photo)
            }
        }
    }
    
    func updateCurrentPhoto(_ photo: Photo) {
        currentPhoto = photo
        preloadImages(around: allPhotos.firstIndex(of: photo) ?? 0)
    }
}

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
                    LazyVGrid(columns: gridColumns, spacing: 4) {
                        ForEach(photos) { photo in
                            PhotoThumbnailView(photo: photo)
                                .aspectRatio(1, contentMode: .fit)
                                .cornerRadius(12)
                                .clipped()
                                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                                .onTapGesture {
                                    selectedPhoto = photo
                                    capturedPhoto = photo
                                    showingPhotoDetail = true
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
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
                PhotoDetailView(photo: photoToShow, allPhotos: photos)
            }
        }
    }
}

struct PhotoThumbnailView: View {
    let photo: Photo
    @State private var thumb: UIImage?
    
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = thumb ?? photo.image {
                    ZStack(alignment: .bottomLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .clipped()
                        // 角标显示胶片名
                        if let name = photo.filmPreset?.displayName {
                            Text(name)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .padding(6)
                        }
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundColor(.gray)
                        )
                }
            }
            .task {
                if thumb == nil {
                    let maxPixel = Int(UIScreen.main.bounds.width / 3.0 * UIScreen.main.scale)
                    thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: maxPixel)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let photo: Photo
    let allPhotos: [Photo]
    
    @StateObject private var viewModel: PhotoDetailViewModel
    @State private var saveStatus: SaveStatus = .none
    @State private var showingInfo = true
    @State private var currentIndex: Int = 0
    
    enum SaveStatus {
        case none, saving, success, failed
    }
    
    init(photo: Photo, allPhotos: [Photo]) {
        self.photo = photo
        self.allPhotos = allPhotos
        self._viewModel = StateObject(wrappedValue: PhotoDetailViewModel(photo: photo, allPhotos: allPhotos))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                // 关闭按钮 - 圆形设计
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                // 照片计数 - 居中显示
                Text("\(currentIndex + 1) / \(allPhotos.count)")
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                
                Spacer()
                
                // 保存按钮 - 圆形设计
                Button(action: saveToPhotoLibrary) {
                    Image(systemName: saveButtonIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(saveButtonBackgroundColor)
                        .clipShape(Circle())
                }
                .disabled(saveStatus == .saving)
            }
            .padding()
            .background(Color.black)
            
            // 照片显示区域
            if !allPhotos.isEmpty {
                TabView(selection: $currentIndex) {
                    ForEach(Array(allPhotos.enumerated()), id: \.element.id) { index, photoItem in
                        OptimizedPhotoView(
                            photo: photoItem,
                            loadedImage: viewModel.loadedImages[photoItem.id],
                            isLoading: viewModel.isLoading
                        )
                        .tag(index)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingInfo.toggle()
                            }
                        }
                        .onAppear {
                            viewModel.loadImage(for: photoItem)
                        }
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.1), value: currentIndex)
                .onChange(of: currentIndex) { _, newIndex in
                    if newIndex >= 0 && newIndex < allPhotos.count {
                        let newPhoto = allPhotos[newIndex]
                        viewModel.updateCurrentPhoto(newPhoto)
                    }
                }
                .background(Color.black)
            } else {
                // 没有照片时的占位符
                Spacer()
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 100))
                        .foregroundColor(.gray)
                    Text("没有照片")
                        .font(.title2)
                        .foregroundColor(.gray)
                        .padding(.top, 16)
                }
                Spacer()
            }
            
            // 底部信息面板
            if showingInfo {
                ScrollView {
                    VStack(spacing: 12) {
                        // 拍摄时间
                        Text("\(viewModel.currentPhoto.timestamp, formatter: detailDateFormatter)")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.bottom, 4)

                        // 胶片类型
                        HStack(spacing: 8) {
                            Text("胶片")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(viewModel.currentPhoto.filmDisplayName)
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 2)
                        
                        // 拍摄参数和设备信息合并显示
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            ExifInfoView(title: "ISO", value: viewModel.currentPhoto.iso)
                            ExifInfoView(title: "快门", value: viewModel.currentPhoto.shutterSpeed)
                            ExifInfoView(title: "光圈", value: viewModel.currentPhoto.aperture)
                            ExifInfoView(title: "焦距", value: viewModel.currentPhoto.focalLength)
                            ExifInfoView(title: "曝光", value: viewModel.currentPhoto.exposureMode)
                            ExifInfoView(title: "闪光灯", value: viewModel.currentPhoto.flashMode)
                            
                            if let device = viewModel.currentPhoto.deviceInfo {
                                ExifInfoView(title: "制造商", value: device.make)
                                ExifInfoView(title: "型号", value: device.model)
                                ExifInfoView(title: "镜头", value: viewModel.currentPhoto.lensInfo)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.35)
                .background(Color.black.opacity(0.95))
                .cornerRadius(16)
                .transition(.move(edge: .bottom))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            initializeCurrentIndex()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            // 响应内存警告，清理缓存
            viewModel.imageLoader.clearCache()
        }
    }
    
    private func initializeCurrentIndex() {
        // 查找当前照片在数组中的索引
        for (index, photoItem) in allPhotos.enumerated() {
            if photoItem.id == photo.id {
                currentIndex = index
                viewModel.updateCurrentPhoto(photoItem)
                return
            }
        }
        
        // 如果没找到，默认使用第一张
        currentIndex = 0
        if !allPhotos.isEmpty {
            viewModel.updateCurrentPhoto(allPhotos[0])
        }
    }
    
    // 计算属性
    private var saveButtonIcon: String {
        switch saveStatus {
        case .none: return "square.and.arrow.down"
        case .saving: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }
    
    private var saveButtonBackgroundColor: Color {
        switch saveStatus {
        case .none: return Color.black.opacity(0.6)
        case .saving: return Color.blue.opacity(0.8)
        case .success: return Color.green.opacity(0.8)
        case .failed: return Color.red.opacity(0.8)
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
        guard let image = viewModel.currentPhoto.image else {
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
        let imageData = viewModel.currentPhoto.imageData
        
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

// MARK: - 优化的照片视图组件
struct OptimizedPhotoView: View {
    let photo: Photo
    let loadedImage: UIImage?
    let isLoading: Bool
    
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                } else if isLoading {
                    // 加载状态
                    VStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                        Text("加载中...")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                } else {
                    // 加载失败或占位符
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            }
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
                .font(.caption2)
                .foregroundColor(.gray)
                .fontWeight(.medium)
            Text(value)
                .font(.caption)
                .foregroundColor(.white)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 45)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
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