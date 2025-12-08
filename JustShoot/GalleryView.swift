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

private struct GalleryToolbar: ToolbarContent {
    let dismiss: DismissAction
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("完成") { dismiss() }
        }
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
    @Query(sort: \Roll.createdAt, order: .reverse) private var rolls: [Roll]
    @State private var detailPayload: DetailPayload?
    @State private var isSelecting = false
    @State private var selectedPhotos: Set<UUID> = []
    @State private var showDeleteConfirm = false

    private let gridColumns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    /// 按最新照片时间排序的胶卷列表
    private var sortedRolls: [Roll] {
        rolls.sorted { roll1, roll2 in
            let latest1 = roll1.photos.map(\.timestamp).max() ?? roll1.createdAt
            let latest2 = roll2.photos.map(\.timestamp).max() ?? roll2.createdAt
            return latest1 > latest2
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: true) {
                    if rolls.isEmpty {
                        VStack {
                            Image(systemName: "photo")
                                .font(.system(size: 80))
                                .foregroundColor(.gray.opacity(0.5))
                            Text("暂无照片")
                                .font(.title3)
                                .foregroundColor(.gray)
                                .padding(.top, 16)
                            Text("前往拍摄页面开始拍照")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.6))
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, minHeight: 400)
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(sortedRolls) { roll in
                                RollSectionView(
                                    roll: roll,
                                    gridColumns: gridColumns,
                                    isSelecting: isSelecting,
                                    selectedPhotos: $selectedPhotos
                                ) { startPhoto, groupPhotos in
                                    if !isSelecting {
                                        let screenBounds = UIScreen.main.bounds
                                        let maxPixel = Int(max(screenBounds.width, screenBounds.height) * UIScreen.main.scale)
                                        Task.detached(priority: .userInitiated) {
                                            _ = await ImageLoader.shared.loadPreview(for: startPhoto, maxPixel: maxPixel)
                                        }
                                        detailPayload = DetailPayload(startPhoto: startPhoto, photos: groupPhotos)
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, isSelecting ? 80 : 16)
                    }
                }

                // 底部删除栏
                if isSelecting && !selectedPhotos.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Button(action: { showDeleteConfirm = true }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 16, weight: .medium))
                                    Text("删除 (\(selectedPhotos.count))")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.red)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .background(
                            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                                .frame(height: 100)
                                .allowsHitTesting(false)
                        )
                    }
                }
            }
            .navigationTitle(isSelecting ? "已选择 \(selectedPhotos.count) 张" : "相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isSelecting ? "取消" : "完成") {
                        if isSelecting {
                            isSelecting = false
                            selectedPhotos.removeAll()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !rolls.isEmpty {
                        Button(isSelecting ? "全选" : "选择") {
                            if isSelecting {
                                // 全选/取消全选
                                let allPhotoIds = Set(rolls.flatMap { $0.photos.map { $0.id } })
                                if selectedPhotos.count == allPhotoIds.count {
                                    selectedPhotos.removeAll()
                                } else {
                                    selectedPhotos = allPhotoIds
                                }
                            } else {
                                isSelecting = true
                            }
                        }
                    }
                }
            }
            .alert("确认删除", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteSelectedPhotos()
                }
            } message: {
                Text("确定要删除选中的 \(selectedPhotos.count) 张照片吗？此操作不可撤销。")
            }
        }
        .sheet(item: $detailPayload) { payload in
            PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos)
        }
    }

    private func deleteSelectedPhotos() {
        // 收集要删除的照片
        let photosToDelete = rolls.flatMap { $0.photos }.filter { selectedPhotos.contains($0.id) }

        for photo in photosToDelete {
            modelContext.delete(photo)
        }

        do {
            try modelContext.save()
            print("✅ 已删除 \(photosToDelete.count) 张照片")
        } catch {
            print("❌ 删除照片失败: \(error)")
        }

        selectedPhotos.removeAll()
        isSelecting = false
    }

    private var flattenedPhotos: [Photo] {
        rolls.flatMap { $0.photos }.sorted(by: { $0.timestamp > $1.timestamp })
    }
}

private struct RollSectionView: View {
    let roll: Roll
    let gridColumns: [GridItem]
    let isSelecting: Bool
    @Binding var selectedPhotos: Set<UUID>
    let onSelect: (Photo, [Photo]) -> Void

    var body: some View {
        let groupPhotos = roll.photos.sorted(by: { $0.timestamp > $1.timestamp })
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(roll.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(roll.shotsTaken)/\(roll.capacity)")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                if roll.isCompleted {
                    Text("已完成")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
            }
            LazyVGrid(columns: gridColumns, spacing: 6) {
                ForEach(groupPhotos) { photo in
                    PhotoThumbnailView(
                        photo: photo,
                        isSelecting: isSelecting,
                        isSelected: selectedPhotos.contains(photo.id)
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if isSelecting {
                            if selectedPhotos.contains(photo.id) {
                                selectedPhotos.remove(photo.id)
                            } else {
                                selectedPhotos.insert(photo.id)
                            }
                        } else {
                            onSelect(photo, groupPhotos)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DetailPayload: Identifiable, Equatable {
    var id: UUID { startPhoto.id }
    let startPhoto: Photo
    let photos: [Photo]
    static func == (lhs: DetailPayload, rhs: DetailPayload) -> Bool { lhs.startPhoto.id == rhs.startPhoto.id }
}

struct PhotoThumbnailView: View {
    let photo: Photo
    var isSelecting: Bool = false
    var isSelected: Bool = false
    @State private var thumb: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumb ?? photo.image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .overlay(
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                                    .scaleEffect(0.8)
                            )
                    }
                }

                // 选择模式下显示选中状态
                if isSelecting {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.blue : Color.black.opacity(0.5))
                            .frame(width: 22, height: 22)

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Circle()
                                .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                        }
                    }
                    .padding(5)
                }

                // 选中时添加边框
                if isSelecting && isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: geometry.size.width, height: geometry.size.width)
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
    @State private var showingInfo = false
    @State private var currentIndex: Int = 0
    @State private var showDeleteConfirm = false
    @State private var imageScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    enum SaveStatus {
        case none, saving, success, failed
    }

    init(photo: Photo, allPhotos: [Photo]) {
        self.photo = photo
        self.allPhotos = allPhotos
        self._viewModel = StateObject(wrappedValue: PhotoDetailViewModel(photo: photo, allPhotos: allPhotos))
        let initialIndex = allPhotos.firstIndex(of: photo) ?? 0
        self._currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                // 照片显示区域
                if !allPhotos.isEmpty {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(allPhotos.enumerated()), id: \.element.id) { index, photoItem in
                            ZoomablePhotoView(
                                photo: photoItem,
                                loadedImage: viewModel.loadedImages[photoItem.id],
                                isLoading: viewModel.isLoading,
                                scale: index == currentIndex ? $imageScale : .constant(1.0),
                                offset: index == currentIndex ? $imageOffset : .constant(.zero)
                            )
                            .tag(index)
                            .onAppear {
                                viewModel.loadImage(for: photoItem)
                            }
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    .onChange(of: currentIndex) { _, newIndex in
                        // 切换照片时重置缩放
                        imageScale = 1.0
                        imageOffset = .zero
                        if newIndex >= 0 && newIndex < allPhotos.count {
                            let newPhoto = allPhotos[newIndex]
                            viewModel.updateCurrentPhoto(newPhoto)
                        }
                    }
                } else {
                    // 没有照片时的占位符
                    VStack(spacing: 16) {
                        Image(systemName: "photo")
                            .font(.system(size: 80))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("没有照片")
                            .font(.title3)
                            .foregroundColor(.gray)
                    }
                }

                // 底部信息面板（可展开）
                VStack {
                    Spacer()
                    PhotoInfoPanel(
                        photo: viewModel.currentPhoto,
                        isExpanded: $showingInfo,
                        getImageDimensions: getImageDimensions
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左侧：关闭按钮
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }

                // 中间：照片计数
                ToolbarItem(placement: .principal) {
                    Text("\(currentIndex + 1) / \(allPhotos.count)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }

                // 右侧：操作按钮
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // 信息按钮
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showingInfo.toggle()
                        }
                    }) {
                        Image(systemName: showingInfo ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 16))
                            .foregroundColor(showingInfo ? .yellow : .white)
                    }

                    // 保存按钮
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        saveToPhotoLibrary()
                    }) {
                        Image(systemName: saveButtonIcon)
                            .font(.system(size: 16))
                            .foregroundColor(saveButtonColor)
                    }
                    .disabled(saveStatus == .saving)

                    // 删除按钮
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showDeleteConfirm = true
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                    }
                }
            }
            .toolbarBackground(Color.black.opacity(0.8), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !allPhotos.isEmpty && currentIndex < allPhotos.count {
                viewModel.updateCurrentPhoto(allPhotos[currentIndex])
                viewModel.loadImage(for: allPhotos[currentIndex])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            viewModel.imageLoader.clearCache()
        }
        .alert("删除照片", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deleteCurrentPhoto()
            }
        } message: {
            Text("确定要删除这张照片吗？此操作不可撤销。")
        }
    }

    private func deleteCurrentPhoto() {
        guard currentIndex < allPhotos.count else { return }
        let photoToDelete = allPhotos[currentIndex]

        modelContext.delete(photoToDelete)
        do {
            try modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            if allPhotos.count <= 1 {
                dismiss()
            } else if currentIndex >= allPhotos.count - 1 {
                currentIndex = max(0, currentIndex - 1)
            }
        } catch {
            print("❌ 删除照片失败: \(error)")
        }
    }

    private var saveButtonIcon: String {
        switch saveStatus {
        case .none: return "square.and.arrow.down"
        case .saving: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var saveButtonColor: Color {
        switch saveStatus {
        case .none: return .white
        case .saving: return .blue
        case .success: return .green
        case .failed: return .red
        }
    }

    private func getImageDimensions(from imageData: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        return (width, height)
    }

    private func saveToPhotoLibrary() {
        guard viewModel.currentPhoto.image != nil else { return }

        saveStatus = .saving

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    self.saveStatus = .failed
                    self.resetSaveStatus()
                    return
                }

                let imageData = self.viewModel.currentPhoto.imageData
                let photo = self.viewModel.currentPhoto

                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = photo.timestamp

                    if let lat = photo.latitude, let lon = photo.longitude {
                        let location = CLLocation(
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            altitude: photo.altitude ?? 0,
                            horizontalAccuracy: 10,
                            verticalAccuracy: 10,
                            timestamp: photo.locationTimestamp ?? photo.timestamp
                        )
                        request.location = location
                    }

                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = "public.jpeg"
                    request.addResource(with: .photo, data: imageData, options: options)
                }) { success, _ in
                    DispatchQueue.main.async {
                        self.saveStatus = success ? .success : .failed
                        UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
                        self.resetSaveStatus()
                    }
                }
            }
        }
    }

    private func resetSaveStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveStatus = .none
        }
    }
}

// MARK: - 可缩放照片视图
struct ZoomablePhotoView: View {
    let photo: Photo
    let loadedImage: UIImage?
    let isLoading: Bool
    @Binding var scale: CGFloat
    @Binding var offset: CGSize

    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newScale = lastScale * value
                                scale = min(max(newScale, 1.0), 5.0)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.0 {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        scale = 1.0
                                        offset = .zero
                                    }
                                    lastScale = 1.0
                                }
                            }
                    )
                    .simultaneousGesture(
                        scale > 1.0 ?
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: value.translation.width,
                                    height: value.translation.height
                                )
                            }
                            .onEnded { _ in
                                // 限制拖动范围
                                let maxOffset = (scale - 1) * min(geometry.size.width, geometry.size.height) / 2
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    offset.width = min(max(offset.width, -maxOffset), maxOffset)
                                    offset.height = min(max(offset.height, -maxOffset), maxOffset)
                                }
                            }
                        : nil
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                                lastScale = 1.0
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                    Text("加载中...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
    }
}

// MARK: - 照片信息面板
struct PhotoInfoPanel: View {
    let photo: Photo
    @Binding var isExpanded: Bool
    let getImageDimensions: (Data) -> (width: Int, height: Int)?

    var body: some View {
        VStack(spacing: 0) {
            // 收起状态：简要信息条
            if !isExpanded {
                HStack(spacing: 16) {
                    // 胶片类型
                    Label(photo.filmDisplayName, systemImage: "film")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)

                    Spacer()

                    // 拍摄时间
                    Text(photo.timestamp, style: .date)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.7))
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded = true
                    }
                }
            }

            // 展开状态：完整信息
            if isExpanded {
                VStack(spacing: 16) {
                    // 拖动指示条
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 36, height: 4)
                        .padding(.top, 8)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isExpanded = false
                            }
                        }

                    // 拍摄时间
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(.yellow)
                        Text(photo.timestamp, format: .dateTime.year().month().day().hour().minute())
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                        Spacer()
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // 胶片信息
                    HStack {
                        Image(systemName: "film")
                            .foregroundColor(.yellow)
                        Text(photo.filmDisplayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }

                    // 曝光参数网格
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        ExifInfoCard(icon: "camera.aperture", title: "光圈", value: photo.aperture)
                        ExifInfoCard(icon: "timer", title: "快门", value: photo.shutterSpeed)
                        ExifInfoCard(icon: "speedometer", title: "ISO", value: photo.iso)
                        ExifInfoCard(icon: "scope", title: "焦距", value: photo.focalLength)
                        ExifInfoCard(icon: "bolt.fill", title: "闪光灯", value: photo.flashMode)
                        if let dims = getImageDimensions(photo.imageData) {
                            ExifInfoCard(icon: "aspectratio", title: "尺寸", value: "\(dims.width)×\(dims.height)")
                        } else {
                            ExifInfoCard(icon: "aspectratio", title: "尺寸", value: "未知")
                        }
                    }

                    // 位置信息
                    if let lat = photo.latitude, let lon = photo.longitude {
                        Divider().background(Color.white.opacity(0.2))
                        HStack {
                            Image(systemName: "location.fill")
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "%.6f, %.6f", lat, lon))
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                if let alt = photo.altitude {
                                    Text("海拔 \(String(format: "%.1f", alt))m")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                            Spacer()
                        }
                    }

                    // 设备信息
                    if let device = photo.deviceInfo {
                        Divider().background(Color.white.opacity(0.2))
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundColor(.yellow)
                            Text("\(device.make) \(device.model)")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.9))
                        .shadow(color: .black.opacity(0.3), radius: 10, y: -5)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - EXIF 信息卡片
struct ExifInfoCard: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.yellow.opacity(0.8))
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// 导航栏样式扩展
extension View {
    func navigationBarStyle(color: Color, backgroundColor: Color) -> some View {
        self.toolbarBackground(backgroundColor, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
} 