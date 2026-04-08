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
        let photoId = photo.id
        let key = "preview_\(photoId.uuidString)_\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        if let url = previewURL(for: photoId, maxPixel: maxPixel),
           fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            cache.setObject(img, forKey: key)
            return img
        }

        // Extract imageData on calling actor before dispatching to background
        let imageData = photo.imageData

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let src = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }
            let downOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 256),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, downOptions as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cgThumb)
            self.cache.setObject(image, forKey: key)
            if let url = self.previewURL(for: photoId, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.9) {
                try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: url, options: .atomic)
            }
            return image
        }.value
    }

    func loadThumbnail(for photo: Photo, maxPixel: Int) async -> UIImage? {
        let photoId = photo.id
        let key = "thumb_\(photoId.uuidString)_\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        if let url = thumbnailURL(for: photoId, maxPixel: maxPixel),
           fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            cache.setObject(img, forKey: key)
            return img
        }

        // Extract imageData on calling actor before dispatching to background
        let imageData = photo.imageData

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let src = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 96),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cgThumb)
            self.cache.setObject(image, forKey: key)
            if let url = self.thumbnailURL(for: photoId, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.85) {
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

    private func thumbnailURL(for photoId: UUID, maxPixel: Int) -> URL? {
        guard let dir = thumbsDirectory() else { return nil }
        return dir.appendingPathComponent("\(photoId.uuidString)_t_\(maxPixel).jpg")
    }

    private func previewDirectory() -> URL? {
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Previews", isDirectory: true)
    }

    private func previewURL(for photoId: UUID, maxPixel: Int) -> URL? {
        guard let dir = previewDirectory() else { return nil }
        return dir.appendingPathComponent("\(photoId.uuidString)_p_\(maxPixel).jpg")
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}

// MARK: - 照片详情视图模型
class PhotoDetailViewModel: ObservableObject {
    @Published var loadedImages: [UUID: UIImage] = [:]

    let imageLoader = ImageLoader.shared

    func loadImage(for photo: Photo) {
        let photoId = photo.id
        if loadedImages[photoId] != nil { return }

        let maxPixel = Int(max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale)
        // Use Task (not Task.detached) so loadPreview extracts imageData on MainActor
        // before dispatching its own background work
        Task { [weak self] in
            guard let self else { return }
            let image = await self.imageLoader.loadPreview(for: photo, maxPixel: maxPixel)
            if let image {
                self.loadedImages[photoId] = image
            }
        }
    }

    func preloadImages(around index: Int, in photos: [Photo]) {
        guard !photos.isEmpty else { return }
        let lo = max(0, index - 1)
        let hi = min(photos.count - 1, index + 1)
        for i in lo...hi {
            loadImage(for: photos[i])
        }
    }
}

// MARK: - 相册视图
struct GalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.timestamp, order: .reverse) private var photos: [Photo]
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

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if photos.isEmpty {
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
                LazyVGrid(columns: gridColumns, spacing: 6) {
                    ForEach(photos) { photo in
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
                                let screenBounds = UIScreen.main.bounds
                                let maxPixel = Int(max(screenBounds.width, screenBounds.height) * UIScreen.main.scale)
                                Task {
                                    _ = await ImageLoader.shared.loadPreview(for: photo, maxPixel: maxPixel)
                                }
                                selectedDetail = DetailPayload(startPhoto: photo, photos: Array(photos))
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
        .background(Color.black)
        .navigationTitle(isSelecting ? "已选择 \(selectedPhotos.count) 张" : "相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !photos.isEmpty {
                    Button(isSelecting ? "全选" : "选择") {
                        if isSelecting {
                            let allPhotoIds = Set(photos.map { $0.id })
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
        let photosToDelete = photos.filter { selectedPhotos.contains($0.id) }

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

private struct DetailPayload: Identifiable, Equatable, Hashable {
    var id: UUID { startPhoto.id }
    let startPhoto: Photo
    let photos: [Photo]
    static func == (lhs: DetailPayload, rhs: DetailPayload) -> Bool { lhs.startPhoto.id == rhs.startPhoto.id }
    func hash(into hasher: inout Hasher) { hasher.combine(startPhoto.id) }
}

// MARK: - 缩略图视图
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

// MARK: - 照片详情
struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let photo: Photo
    @State private var photos: [Photo]

    @StateObject private var viewModel = PhotoDetailViewModel()
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

    private var currentPhoto: Photo? {
        guard currentIndex >= 0 && currentIndex < photos.count else { return nil }
        return photos[currentIndex]
    }

    init(photo: Photo, allPhotos: [Photo]) {
        self.photo = photo
        self._photos = State(initialValue: allPhotos)
        let initialIndex = allPhotos.firstIndex(of: photo) ?? 0
        self._currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !photos.isEmpty {
                VStack(spacing: 0) {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photoItem in
                            ZoomablePhotoView(
                                loadedImage: viewModel.loadedImages[photoItem.id],
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
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .disabled(imageScale > 1.0)

                    ScrubberStripView(
                        photos: photos,
                        currentIndex: $currentIndex,
                        itemSize: 40,
                        spacing: 6
                    )
                    .padding(.vertical, 6)
                    .opacity(isFullScreen ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: isFullScreen)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "photo")
                        .font(.system(size: 80))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("没有照片")
                        .font(.title3)
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isFullScreen)
        .toolbar(isFullScreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(isFullScreen ? .hidden : .visible, for: .bottomBar)
        .toolbar { navigationToolbar }
        .toolbar { bottomToolbar }
        .statusBarHidden(isFullScreen)
        .onChange(of: currentIndex) { _, newIndex in
            imageScale = 1.0
            imageOffset = .zero
            if newIndex >= 0 && newIndex < photos.count {
                viewModel.preloadImages(around: newIndex, in: photos)
            }
        }
        .onAppear {
            if !photos.isEmpty {
                viewModel.preloadImages(around: currentIndex, in: photos)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            viewModel.imageLoader.clearCache()
        }
        .alert("删除照片", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteCurrentPhoto() }
        } message: {
            Text("确定要删除这张照片吗？此操作不可撤销。")
        }
        .sheet(isPresented: $showingInfo) {
            if let photo = currentPhoto {
                PhotoInfoPanel(photo: photo, getImageDimensions: getImageDimensions)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let photo = currentPhoto {
                VStack(spacing: 1) {
                    Text(photo.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline.weight(.semibold))
                    Text("\(currentIndex + 1) / \(photos.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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

    // MARK: - Actions

    private func deleteCurrentPhoto() {
        guard let photoToDelete = currentPhoto else { return }

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
        guard let photo = currentPhoto, !photo.imageData.isEmpty else { return }

        saveStatus = .saving
        let imageData = photo.imageData
        let photoRef = photo

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
                    request.creationDate = photoRef.timestamp

                    if let lat = photoRef.latitude, let lon = photoRef.longitude {
                        request.location = CLLocation(
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            altitude: photoRef.altitude ?? 0,
                            horizontalAccuracy: 10,
                            verticalAccuracy: 10,
                            timestamp: photoRef.locationTimestamp ?? photoRef.timestamp
                        )
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
    let loadedImage: UIImage?
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
                                scale = min(max(lastScale * value, 1.0), 5.0)
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
                    .highPriorityGesture(
                        scale > 1.0 ?
                        DragGesture()
                            .onChanged { value in
                                offset = value.translation
                            }
                            .onEnded { _ in
                                let maxOff = (scale - 1) * min(geometry.size.width, geometry.size.height) / 2
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    offset.width = min(max(offset.width, -maxOff), maxOff)
                                    offset.height = min(max(offset.height, -maxOff), maxOff)
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
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
    }
}

// MARK: - 可拖拽缩略图条
private struct ScrubberStripView: View {
    let photos: [Photo]
    @Binding var currentIndex: Int
    let itemSize: CGFloat
    let spacing: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex: Int = 0
    @State private var isDragging = false
    @State private var containerWidth: CGFloat = 0

    private let feedbackGenerator = UISelectionFeedbackGenerator()
    private let selectedSize: CGFloat = 50

    private var step: CGFloat { itemSize + spacing }

    private func offsetForIndex(_ index: Int) -> CGFloat {
        -CGFloat(index) * step
    }

    private var centerOffset: CGFloat {
        containerWidth / 2 - itemSize / 2
    }

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                let isSelected = index == currentIndex
                let displaySize = isSelected ? selectedSize : itemSize

                ThumbnailStripItem(photo: photo, size: displaySize)
                    .overlay(
                        RoundedRectangle(cornerRadius: isSelected ? 5 : 3, style: .continuous)
                            .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: isSelected ? 2 : 0)
                    )
                    .opacity(isSelected ? 1.0 : 0.5)
                    .animation(.easeOut(duration: 0.15), value: currentIndex)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentIndex = index
                        }
                        feedbackGenerator.selectionChanged()
                    }
            }
        }
        .offset(x: centerOffset + offsetForIndex(currentIndex) + dragOffset)
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
        .frame(maxWidth: .infinity)
        .frame(height: selectedSize)
        .clipped()
        .background(GeometryReader { geo in
            Color.clear.onAppear { containerWidth = geo.size.width }
        })
        .onAppear {
            feedbackGenerator.prepare()
        }
    }
}

// MARK: - 缩略图项
private struct ThumbnailStripItem: View {
    let photo: Photo
    let size: CGFloat
    @State private var thumb: UIImage?

    var body: some View {
        Group {
            if let image = thumb {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 45 ? 5 : 3, style: .continuous))
        .task {
            if thumb == nil {
                thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: Int(size * 3))
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
