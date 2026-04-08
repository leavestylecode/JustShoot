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
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    func loadPreview(for photo: Photo, maxPixel: Int) async -> UIImage? {
        let key = "preview_\(photo.id.uuidString)_\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        if let url = previewURL(for: photo, maxPixel: maxPixel),
           fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            cache.setObject(img, forKey: key)
            return img
        }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
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
            if let url = self.previewURL(for: photo, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.9) {
                try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: url, options: .atomic)
            }
            return image
        }.value
    }

    func loadThumbnail(for photo: Photo, maxPixel: Int) async -> UIImage? {
        let key = "thumb_\(photo.id.uuidString)_\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        if let url = thumbnailURL(for: photo, maxPixel: maxPixel),
           fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            cache.setObject(img, forKey: key)
            return img
        }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
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
            guard let self else { return }
            let image = await self.imageLoader.loadPreview(for: photo, maxPixel: maxPixel)
            await MainActor.run {
                if let image {
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

// MARK: - 相册视图（不自带 NavigationStack，由父级 ContentView 提供）
struct GalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Roll.createdAt, order: .reverse) private var rolls: [Roll]
    @State private var selectedDetail: DetailPayload?
    @State private var isSelecting = false
    @State private var selectedPhotos: Set<UUID> = []
    @State private var showDeleteConfirm = false

    private let gridColumns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    private var sortedRolls: [Roll] {
        rolls.sorted { roll1, roll2 in
            let latest1 = roll1.photos.map(\.timestamp).max() ?? roll1.createdAt
            let latest2 = roll2.photos.map(\.timestamp).max() ?? roll2.createdAt
            return latest1 > latest2
        }
    }

    var body: some View {
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
                                selectedDetail = DetailPayload(startPhoto: startPhoto, photos: groupPhotos)
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
        .background(Color.black)
        .navigationTitle(isSelecting ? "已选择 \(selectedPhotos.count) 张" : "相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !rolls.isEmpty {
                    Button(isSelecting ? "全选" : "选择") {
                        if isSelecting {
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
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    Button("取消") {
                        isSelecting = false
                        selectedPhotos.removeAll()
                    }

                    Spacer()

                    Button(action: { showDeleteConfirm = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                            Text("删除")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(selectedPhotos.isEmpty ? .gray : .red)
                    }
                    .disabled(selectedPhotos.isEmpty)
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
        .navigationDestination(item: $selectedDetail) { payload in
            PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos)
        }
    }

    private func deleteSelectedPhotos() {
        let photosToDelete = rolls.flatMap { $0.photos }.filter { selectedPhotos.contains($0.id) }

        for photo in photosToDelete {
            modelContext.delete(photo)
        }

        do {
            try modelContext.save()
        } catch {
            print("❌ 删除照片失败: \(error)")
        }

        selectedPhotos.removeAll()
        isSelecting = false
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

private struct DetailPayload: Identifiable, Equatable, Hashable {
    var id: UUID { startPhoto.id }
    let startPhoto: Photo
    let photos: [Photo]
    static func == (lhs: DetailPayload, rhs: DetailPayload) -> Bool { lhs.startPhoto.id == rhs.startPhoto.id }
    func hash(into hasher: inout Hasher) { hasher.combine(startPhoto.id) }
}

// MARK: - 缩略图视图（不再 fallback 到全尺寸 photo.image）
struct PhotoThumbnailView: View {
    let photo: Photo
    var isSelecting: Bool = false
    var isSelected: Bool = false
    @State private var thumb: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumb {
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

// MARK: - 照片详情（不自带 NavigationStack，由父级导航容器提供）
struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let photo: Photo
    @State private var photos: [Photo]

    @StateObject private var viewModel: PhotoDetailViewModel
    @State private var saveStatus: SaveStatus = .none
    @State private var showingInfo = false
    @State private var currentIndex: Int = 0
    @State private var showDeleteConfirm = false
    @State private var imageScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var isFullScreen = false

    enum SaveStatus {
        case none, saving, success, failed
    }

    init(photo: Photo, allPhotos: [Photo]) {
        self.photo = photo
        self._photos = State(initialValue: allPhotos)
        self._viewModel = StateObject(wrappedValue: PhotoDetailViewModel(photo: photo, allPhotos: allPhotos))
        let initialIndex = allPhotos.firstIndex(of: photo) ?? 0
        self._currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        photoContentView
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isFullScreen)
            .toolbar(isFullScreen ? .hidden : .visible, for: .navigationBar)
            .toolbar(isFullScreen ? .hidden : .visible, for: .bottomBar)
            .toolbar { navigationToolbar }
            .toolbar { bottomToolbar }
            .statusBarHidden(isFullScreen)
            .onAppear {
                if !photos.isEmpty && currentIndex < photos.count {
                    viewModel.updateCurrentPhoto(photos[currentIndex])
                    viewModel.loadImage(for: photos[currentIndex])
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
            .sheet(isPresented: $showingInfo) {
                if currentIndex < photos.count {
                    PhotoInfoPanel(
                        photo: photos[currentIndex],
                        getImageDimensions: getImageDimensions
                    )
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
            }
    }

    @ViewBuilder
    private var photoContentView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !photos.isEmpty {
                VStack(spacing: 0) {
                    photoTabView

                    if !isFullScreen {
                        ScrubberStripView(
                            photos: photos,
                            currentIndex: $currentIndex,
                            itemSize: 40,
                            spacing: 6
                        )
                        .frame(height: 48)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }
                }
            } else {
                emptyPlaceholder
            }
        }
    }

    @ViewBuilder
    private var photoTabView: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photoItem in
                ZoomablePhotoView(
                    photo: photoItem,
                    loadedImage: viewModel.loadedImages[photoItem.id],
                    isLoading: viewModel.isLoading,
                    scale: index == currentIndex ? $imageScale : .constant(1.0),
                    offset: index == currentIndex ? $imageOffset : .constant(.zero),
                    onSingleTap: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isFullScreen.toggle()
                        }
                    }
                )
                .tag(index)
                .onAppear {
                    viewModel.loadImage(for: photoItem)
                }
            }
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .onChange(of: currentIndex) { oldIndex, newIndex in
            imageScale = 1.0
            imageOffset = .zero
            if isFullScreen {
                isFullScreen = false
            }
            if newIndex >= 0 && newIndex < photos.count {
                viewModel.updateCurrentPhoto(photos[newIndex])
            }
        }
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo")
                .font(.system(size: 80))
                .foregroundColor(.gray.opacity(0.5))
            Text("没有照片")
                .font(.title3)
                .foregroundColor(.gray)
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("\(currentIndex + 1) / \(photos.count)")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showingInfo.toggle()
            } label: {
                Image(systemName: showingInfo ? "info.circle.fill" : "info.circle")
            }
            .tint(showingInfo ? .yellow : .white)
        }
    }

    @ToolbarContentBuilder
    private var bottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                saveToPhotoLibrary()
            } label: {
                Image(systemName: saveButtonIcon)
            }
            .tint(saveButtonColor)
            .disabled(saveStatus == .saving)

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    private func deleteCurrentPhoto() {
        guard currentIndex < photos.count else { return }
        let photoToDelete = photos[currentIndex]

        modelContext.delete(photoToDelete)
        do {
            try modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            photos.remove(at: currentIndex)
            viewModel.loadedImages.removeValue(forKey: photoToDelete.id)

            if photos.isEmpty {
                dismiss()
            } else if currentIndex >= photos.count {
                currentIndex = photos.count - 1
                viewModel.updateCurrentPhoto(photos[currentIndex])
            } else {
                viewModel.updateCurrentPhoto(photos[currentIndex])
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

    /// 保存到系统相册（async/await 现代化）
    private func saveToPhotoLibrary() {
        guard !viewModel.currentPhoto.imageData.isEmpty else { return }

        saveStatus = .saving
        let imageData = viewModel.currentPhoto.imageData
        let photo = viewModel.currentPhoto

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    saveStatus = .failed
                    resetSaveStatus()
                }
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
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
                }

                await MainActor.run {
                    saveStatus = .success
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    resetSaveStatus()
                }
            } catch {
                await MainActor.run {
                    saveStatus = .failed
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    resetSaveStatus()
                }
            }
        }
    }

    private func resetSaveStatus() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
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
    var onSingleTap: (() -> Void)?

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
                    .onTapGesture(count: 1) {
                        onSingleTap?()
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

// MARK: - 可拖拽缩略图条（iPhone Camera 风格）
private struct ScrubberStripView: View {
    let photos: [Photo]
    @Binding var currentIndex: Int
    let itemSize: CGFloat
    let spacing: CGFloat

    /// 拖拽产生的额外偏移
    @State private var dragOffset: CGFloat = 0
    /// 拖拽开始时记录的 index
    @State private var dragStartIndex: Int = 0
    /// 是否正在拖拽
    @State private var isDragging = false

    private let feedbackGenerator = UISelectionFeedbackGenerator()

    /// 每个 item 的步进宽度
    private var step: CGFloat { itemSize + spacing }

    /// 当前 index 对应的居中偏移（负值向左移）
    private func offsetForIndex(_ index: Int) -> CGFloat {
        -CGFloat(index) * step
    }

    var body: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2 - itemSize / 2

            HStack(spacing: spacing) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    ThumbnailStripItem(
                        photo: photo,
                        isSelected: index == currentIndex,
                        size: itemSize
                    )
                    .scaleEffect(index == currentIndex ? 1.15 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: currentIndex)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentIndex = index
                        }
                        feedbackGenerator.selectionChanged()
                    }
                }
            }
            .offset(x: centerX + offsetForIndex(currentIndex) + dragOffset)
            .animation(isDragging ? nil : .easeInOut(duration: 0.25), value: currentIndex)
            .animation(isDragging ? nil : .easeOut(duration: 0.2), value: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartIndex = currentIndex
                            feedbackGenerator.prepare()
                        }
                        dragOffset = value.translation.width

                        // 根据拖拽距离计算新 index
                        let indexDelta = Int(round(-dragOffset / step))
                        let newIndex = max(0, min(photos.count - 1, dragStartIndex + indexDelta))
                        if newIndex != currentIndex {
                            currentIndex = newIndex
                            feedbackGenerator.selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = 0
                        }
                    }
            )
        }
        .clipped()
        .padding(.vertical, itemSize * 0.1) // 留出 scaleEffect 放大的空间
        .onAppear {
            feedbackGenerator.prepare()
        }
    }
}

// MARK: - 底部缩略图条项目
private struct ThumbnailStripItem: View {
    let photo: Photo
    let isSelected: Bool
    let size: CGFloat
    @State private var thumb: UIImage?

    var body: some View {
        Group {
            if let image = thumb {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: size, height: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
        )
        .opacity(isSelected ? 1.0 : 0.6)
        .task {
            if thumb == nil {
                thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: Int(size * 2))
            }
        }
    }
}

// MARK: - 照片信息面板
struct PhotoInfoPanel: View {
    let photo: Photo
    let getImageDimensions: (Data) -> (width: Int, height: Int)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.yellow)
                    Text(photo.timestamp, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 14))
                    Spacer()
                }

                Divider()

                HStack {
                    Image(systemName: "film")
                        .foregroundColor(.yellow)
                    Text(photo.filmDisplayName)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                }

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

                if let lat = photo.latitude, let lon = photo.longitude {
                    Divider()
                    HStack {
                        Image(systemName: "location.fill")
                            .foregroundColor(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.6f, %.6f", lat, lon))
                                .font(.system(size: 13, design: .monospaced))
                            if let alt = photo.altitude {
                                Text("海拔 \(String(format: "%.1f", alt))m")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }

                if let device = photo.deviceInfo {
                    Divider()
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundColor(.yellow)
                        Text("\(device.make) \(device.model)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
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
    }
}

