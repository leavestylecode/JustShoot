import SwiftUI
import SwiftData
import UIKit

struct RecentPhotoThumbnail {
    let id: UUID
    let filterName: String
    let image: UIImage?
    var captureDate: Date = .distantPast
}

/// A presentation uses one committed snapshot, rather than reading a changing @Query in a sheet.
struct RecentPhotoPresentation: Identifiable {
    let id = UUID()
    let startPhoto: Photo
    let photos: [Photo]

    @MainActor
    static func load(in context: ModelContext, filterName: String, startingAt photoID: UUID? = nil) throws -> Self? {
        let descriptor = FetchDescriptor<Photo>(
            predicate: #Predicate { $0.filmPresetName == filterName },
            sortBy: [SortDescriptor(\Photo.timestamp)])
        let photos = try context.fetch(descriptor).filter { !$0.isDeleted }
        let selection: Photo?
        if let photoID { selection = photos.first { $0.id == photoID } }
        else { selection = photos.last }
        guard let selected = selection else { return nil }
        return Self(startPhoto: selected, photos: photos)
    }

    @MainActor
    static func latest(in context: ModelContext, filterName: String) throws -> Photo? {
        try context.fetch(latestDescriptor(filterName: filterName)).first
    }

    static func latestDescriptor(filterName: String) -> FetchDescriptor<Photo> {
        var descriptor = FetchDescriptor<Photo>(
            predicate: #Predicate { $0.filmPresetName == filterName },
            sortBy: [SortDescriptor(\Photo.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }
}

// MARK: - 左下角最近照片 badge
/// 拍摄页左下角"最近一张"缩略图。持有按当前 `source.photoFilterName` 过滤的 @Query——
/// CameraView 切换 `source` 时此视图随 `init` 重建，只观察该胶片最新一张的索引。
///
/// Hint carries the committed photo ID as well as its thumbnail. @Query drives refreshes;
/// tapping fetches a committed snapshot so a just-finished capture opens before @Query catches up.
struct RecentPhotosBadge: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let source: FilmSource
    @Binding var lastThumbnailHint: RecentPhotoThumbnail?
    let pendingPreview: CapturePreview?
    let isShutterBusy: Bool
    let isProcessing: Bool
    let controlRotationAngle: Angle
    let orientation: UIDeviceOrientation
    var onPresentationChanged: (Bool) -> Void = { _ in }

    @Query private var photos: [Photo]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedDetail: RecentPhotoPresentation?
    @State private var selectedPending: CapturePreview?
    @State private var openError: String?

    private struct ThumbnailRequest: Hashable {
        let sourceID: String
        let photoID: UUID?
    }

    private var currentHint: RecentPhotoThumbnail? {
        guard let hint = lastThumbnailHint, hint.filterName == source.photoFilterName,
              photos.first.map({ hint.captureDate >= $0.timestamp }) ?? true else { return nil }
        return hint
    }

    private var currentPreview: CapturePreview? {
        pendingPreview?.filterName == source.photoFilterName ? pendingPreview : nil
    }

    private static let thumbnailMaxPixel = 160
    private var badgeSize: CGFloat { sizeClass == .regular ? 56 : 46 }

    init(
        source: FilmSource,
        lastThumbnailHint: Binding<RecentPhotoThumbnail?>,
        pendingPreview: CapturePreview? = nil,
        isShutterBusy: Bool,
        isProcessing: Bool,
        controlRotationAngle: Angle,
        orientation: UIDeviceOrientation,
        onPresentationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.source = source
        self._lastThumbnailHint = lastThumbnailHint
        self.pendingPreview = pendingPreview
        self.isShutterBusy = isShutterBusy
        self.isProcessing = isProcessing
        self.controlRotationAngle = controlRotationAngle
        self.orientation = orientation
        self.onPresentationChanged = onPresentationChanged
        let filterName = source.photoFilterName
        _photos = Query(RecentPhotoPresentation.latestDescriptor(filterName: filterName))
    }

    var body: some View {
        Button { openRecentPhotos() } label: {
            ZStack {
                if let thumb = currentPreview?.image ?? currentHint?.image {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: badgeSize, height: badgeSize)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: badgeSize, height: badgeSize)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
                if isShutterBusy || isProcessing {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.4))
                        .frame(width: badgeSize, height: badgeSize)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.7)
                }
            }
            .rotationEffect(controlRotationAngle)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
        }
        .accessibilityLabel("Most recent photo")
        .accessibilityValue(isShutterBusy ? Text("Capturing") : isProcessing ? Text("Saving…") : Text(""))
        .accessibilityHint(currentPreview != nil ? Text("Preview while saving")
            : photos.isEmpty && currentHint == nil ? Text("No photos yet") : Text("Open larger view"))
        // 仅在快门 race 窗口禁用，让详情页可以在后处理进行中正常打开历史照片。
        .disabled((photos.isEmpty && currentHint == nil && currentPreview == nil) || isShutterBusy)
        .task(id: ThumbnailRequest(sourceID: source.id, photoID: photos.first?.id)) {
            if lastThumbnailHint?.filterName != source.photoFilterName { lastThumbnailHint = nil }
            await loadFromQuery()
        }
        .onChange(of: selectedDetail?.id) { _, id in
            if id != nil { onPresentationChanged(true) }
        }
        .onChange(of: selectedPending?.id) { _, id in
            if id != nil { onPresentationChanged(true) }
        }
        .fullScreenCover(item: $selectedPending, onDismiss: { onPresentationChanged(false) }) { preview in
            CapturePreviewReview(preview: preview)
                .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $selectedDetail, onDismiss: { onPresentationChanged(false) }) { payload in
            NavigationStack {
                PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { selectedDetail = nil } label: {
                                Image(systemName: "xmark")
                                    .fontWeight(.semibold)
                            }
                            .tint(.white)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .alert("Unable to open photos", isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } }
        )) {
            Button("OK", role: .cancel) { openError = nil }
        } message: { Text(openError ?? "") }
    }

    @MainActor
    private func openRecentPhotos() {
        if let preview = currentPreview {
            selectedPending = preview
            return
        }
        let trace = DiagnosticTrace(id: currentHint?.id.uuidString ?? "recent-photos")
        trace.event("recent_photos_open_requested", "has_indexed_photo=\(!photos.isEmpty) has_hint=\(currentHint != nil)")
        do {
            // CaptureCompletion is emitted after the index commit, before @Query necessarily
            // observes it. Fetch on tap so the newly displayed thumbnail opens the new photo.
            guard let payload = try RecentPhotoPresentation.load(in: modelContext, filterName: source.photoFilterName) else {
                lastThumbnailHint = nil
                trace.event("recent_photos_open_failed", "reason=no_indexed_photos")
                openError = String(localized: "No saved photos are available yet. Please try again.")
                return
            }
            selectedDetail = payload
            trace.event("recent_photos_open_ready", "count=\(payload.photos.count) selected=\(payload.startPhoto.id)")
        } catch {
            trace.event("recent_photos_open_failed", Diagnostics.errorFields(error))
            openError = String(localized: "Photos could not be loaded. Please try again.")
        }
    }

    @MainActor
    private func loadFromQuery() async {
        let filterName = source.photoFilterName
        let previousHintID = lastThumbnailHint?.id
        do {
            guard let photo = try RecentPhotoPresentation.latest(in: modelContext, filterName: filterName) else {
                lastThumbnailHint = nil
                return
            }
            if currentHint?.id == photo.id, currentHint?.image != nil { return }
            let thumb = await PhotoImage.thumbnail(for: photo, maxPixel: Self.thumbnailMaxPixel)
            guard !Task.isCancelled, lastThumbnailHint?.id == previousHintID else { return }
            lastThumbnailHint = RecentPhotoThumbnail(id: photo.id, filterName: filterName, image: thumb, captureDate: photo.timestamp)
        } catch {
            Diagnostics.emit("recent_thumbnail_failed", fields: Diagnostics.errorFields(error))
        }
    }
}

/// The provisional image stays out of Photos/SwiftData. Replace the open preview
/// only after the matching capture commits, so older completions cannot replace it.
struct CapturePreviewReview: View {
    let preview: CapturePreview
    @ObservedObject private var pipeline: CapturePipeline
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var saved: RecentPhotoPresentation?
    @State private var openError: String?

    init(preview: CapturePreview, pipeline: CapturePipeline = .shared) {
        self.preview = preview
        self.pipeline = pipeline
    }

    var body: some View {
        NavigationStack {
            Group {
                if let saved {
                    PhotoDetailView(photo: saved.startPhoto, allPhotos: saved.photos)
                } else {
                    VStack(spacing: 16) {
                        Image(uiImage: preview.image)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel("Photo preview")
                        if pipeline.isProcessing(preview.id) {
                            ProgressView("Saving…")
                        } else {
                            Text(openError ?? String(localized: "Saving paused"))
                                .foregroundStyle(.secondary)
                            Button("Retry") {
                                Task {
                                    loadCommittedPhoto(pipeline.lastCompletion)
                                    if saved == nil { await pipeline.retryPending() }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").fontWeight(.semibold) }
                }
            }
            .onReceive(pipeline.$lastCompletion, perform: loadCommittedPhoto)
        }
    }

    private func loadCommittedPhoto(_ completion: CaptureCompletion?) {
        guard let completion, completion.captureID == preview.id else { return }
        do {
            saved = try RecentPhotoPresentation.load(in: modelContext, filterName: preview.filterName, startingAt: completion.id)
            if saved == nil { openError = String(localized: "Photos could not be loaded. Please try again.") }
        } catch {
            openError = String(localized: "Photos could not be loaded. Please try again.")
        }
    }
}
