import SwiftUI
import SwiftData
import UIKit

struct RecentPhotoThumbnail {
    let id: UUID
    let image: UIImage?
    var captureDate: Date = .distantPast
}

/// A presentation uses one committed snapshot, rather than reading a changing @Query in a sheet.
struct RecentPhotoPresentation: Identifiable {
    let id = UUID()
    let startPhoto: Photo
    let photos: [Photo]

    @MainActor
    static func load(in context: ModelContext, startingAt photoID: UUID? = nil) throws -> Self? {
        // A pending preview probes only its own row until it commits. Do not fetch
        // the entire library on each unrelated capture-completion notification.
        if let photoID {
            var match = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == photoID })
            match.fetchLimit = 1
            guard try context.fetch(match).contains(where: { !$0.isDeleted }) else { return nil }
        }
        let descriptor = FetchDescriptor<Photo>(
            sortBy: [SortDescriptor(\Photo.timestamp)])
        let photos = try context.fetch(descriptor).filter { !$0.isDeleted }
        let selection: Photo?
        if let photoID { selection = photos.first { $0.id == photoID } }
        else { selection = photos.last }
        guard let selected = selection else { return nil }
        return Self(startPhoto: selected, photos: photos)
    }

    @MainActor
    static func latest(in context: ModelContext) throws -> Photo? {
        try context.fetch(latestDescriptor()).first
    }

    static func latestDescriptor() -> FetchDescriptor<Photo> {
        var descriptor = FetchDescriptor<Photo>(
            sortBy: [SortDescriptor(\Photo.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }
}

// MARK: - 左下角最近照片 badge
/// 拍摄页只观察全部拍摄记录中最新一张的索引，切换胶片不会清空或重载缩略图。
///
/// Hint carries the committed photo ID as well as its thumbnail. @Query drives refreshes;
/// tapping fetches a committed snapshot so a just-finished capture opens before @Query catches up.
struct RecentPhotosBadge: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var lastThumbnailHint: RecentPhotoThumbnail?
    let pendingPreview: CapturePreview?
    let isShutterBusy: Bool
    let isProcessing: Bool
    let controlRotationAngle: Angle
    let orientation: UIDeviceOrientation
    var onPresentationChanged: (Bool) -> Void = { _ in }

    @Query private var photos: [Photo]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedReview: RecentPhotoReview?
    @State private var thumbnailRevision = 0
    @State private var openError: String?

    private struct ThumbnailRequest: Hashable {
        let revision: Int
        let photoID: UUID?
    }

    private var currentHint: RecentPhotoThumbnail? {
        guard let hint = lastThumbnailHint,
              photos.first.map({ hint.captureDate >= $0.timestamp }) ?? true else { return nil }
        return hint
    }

    private static let thumbnailMaxPixel = 160
    private var badgeSize: CGFloat { sizeClass == .regular ? 56 : 46 }

    init(
        lastThumbnailHint: Binding<RecentPhotoThumbnail?>,
        pendingPreview: CapturePreview? = nil,
        isShutterBusy: Bool,
        isProcessing: Bool,
        controlRotationAngle: Angle,
        orientation: UIDeviceOrientation,
        onPresentationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self._lastThumbnailHint = lastThumbnailHint
        self.pendingPreview = pendingPreview
        self.isShutterBusy = isShutterBusy
        self.isProcessing = isProcessing
        self.controlRotationAngle = controlRotationAngle
        self.orientation = orientation
        self.onPresentationChanged = onPresentationChanged
        _photos = Query(RecentPhotoPresentation.latestDescriptor())
    }

    var body: some View {
        Button { openRecentPhotos() } label: {
            ZStack {
                if let thumb = pendingPreview?.image ?? currentHint?.image {
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
        .accessibilityHint(pendingPreview != nil ? Text("Preview while saving")
            : photos.isEmpty && currentHint == nil ? Text("No photos yet") : Text("Open larger view"))
        // 仅在快门 race 窗口禁用，让详情页可以在后处理进行中正常打开历史照片。
        .disabled((photos.isEmpty && currentHint == nil && pendingPreview == nil) || isShutterBusy)
        .task(id: ThumbnailRequest(revision: thumbnailRevision, photoID: photos.first?.id)) {
            await loadFromQuery()
        }
        .fullScreenCover(item: $selectedReview, onDismiss: {
            onPresentationChanged(false)
            thumbnailRevision += 1
        }) { review in
            NavigationStack {
                Group {
                    switch review {
                    case let .saved(payload, image):
                        PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos,
                            initialImage: image, onClose: { selectedReview = nil })
                    case let .pending(preview):
                        CapturePreviewReview(preview: preview, onClose: { selectedReview = nil })
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { selectedReview = nil } label: {
                            Image(systemName: "xmark").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Close")
                    }
                }
            }
            .tint(.white)
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
        guard selectedReview == nil else { return }
        if let preview = pendingPreview {
            onPresentationChanged(true)
            selectedReview = .pending(preview)
            return
        }
        let trace = DiagnosticTrace(id: currentHint?.id.uuidString ?? "recent-photos")
        trace.event("recent_photos_open_requested", "has_indexed_photo=\(!photos.isEmpty) has_hint=\(currentHint != nil)")
        do {
            // CaptureCompletion is emitted after the index commit, before @Query necessarily
            // observes it. Fetch on tap so the newly displayed thumbnail opens the new photo.
            guard let payload = try RecentPhotoPresentation.load(in: modelContext) else {
                lastThumbnailHint = nil
                trace.event("recent_photos_open_failed", "reason=no_indexed_photos")
                openError = String(localized: "No saved photos are available yet. Please try again.")
                return
            }
            let image = currentHint?.id == payload.startPhoto.id ? currentHint?.image : nil
            onPresentationChanged(true)
            selectedReview = .saved(payload, image)
            trace.event("recent_photos_open_ready", "count=\(payload.photos.count) selected=\(payload.startPhoto.id)")
        } catch {
            trace.event("recent_photos_open_failed", Diagnostics.errorFields(error))
            openError = String(localized: "Photos could not be loaded. Please try again.")
        }
    }

    @MainActor
    private func loadFromQuery() async {
        let previousHintID = lastThumbnailHint?.id
        do {
            guard let photo = try RecentPhotoPresentation.latest(in: modelContext) else {
                lastThumbnailHint = nil
                return
            }
            if currentHint?.id == photo.id, currentHint?.image != nil { return }
            let thumb = await PhotoImage.thumbnail(for: photo, maxPixel: Self.thumbnailMaxPixel)
            guard !Task.isCancelled, !photo.isDeleted, lastThumbnailHint?.id == previousHintID else { return }
            lastThumbnailHint = RecentPhotoThumbnail(id: photo.id, image: thumb, captureDate: photo.timestamp)
        } catch {
            Diagnostics.emit("recent_thumbnail_failed", fields: Diagnostics.errorFields(error))
        }
    }
}

enum RecentPhotoReview: Identifiable {
    case saved(RecentPhotoPresentation, UIImage?)
    case pending(CapturePreview)

    var id: UUID {
        switch self {
        case let .saved(presentation, _): presentation.id
        case let .pending(preview): preview.id
        }
    }
}

/// The provisional image stays out of Photos/SwiftData. Only its own completion
/// can replace it, and browsing saved photos must not be interrupted by later saves.
struct CapturePreviewReview: View {
    let preview: CapturePreview
    let onClose: () -> Void
    @ObservedObject private var pipeline: CapturePipeline
    @Environment(\.modelContext) private var modelContext
    @Query(RecentPhotoPresentation.latestDescriptor()) private var latestPhotos: [Photo]
    @State private var saved: RecentPhotoPresentation?
    @State private var initialImage: UIImage?
    @State private var openError: String?
    @State private var isRetrying = false

    init(preview: CapturePreview, pipeline: CapturePipeline = .shared, onClose: @escaping () -> Void) {
        self.preview = preview
        self.pipeline = pipeline
        self.onClose = onClose
    }

    var body: some View {
        Group {
            if let saved {
                PhotoDetailView(photo: saved.startPhoto, allPhotos: saved.photos,
                    initialImage: initialImage, onClose: onClose)
            } else {
                VStack(spacing: 16) {
                    Image(uiImage: preview.image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Photo preview")
                    if pipeline.isProcessing(preview.id) || isRetrying {
                        ProgressView("Saving…")
                    } else {
                        Text("Saving paused")
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            isRetrying = true
                            Task { @MainActor in
                                defer { isRetrying = false }
                                loadCommittedPhoto(pipeline.lastCompletion)
                                if saved == nil { await pipeline.retryPending() }
                                loadCommittedPhoto(pipeline.lastCompletion)
                            }
                        }
                    }
                    if !latestPhotos.isEmpty {
                        Button("All Photos", systemImage: "photo.stack") { openSavedPhotos() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
        }
        .onReceive(pipeline.$lastCompletion, perform: loadCommittedPhoto)
        .alert("Unable to open photos", isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } }
        )) {
            Button("OK", role: .cancel) { openError = nil }
        } message: { Text(openError ?? "") }
    }

    private func openSavedPhotos() {
        do {
            saved = try RecentPhotoPresentation.load(in: modelContext)
            initialImage = nil
            if saved == nil { openError = String(localized: "No saved photos are available yet. Please try again.") }
        } catch {
            openError = String(localized: "Photos could not be loaded. Please try again.")
        }
    }

    private func loadCommittedPhoto(_ completion: CaptureCompletion?) {
        guard saved == nil else { return }
        // The publisher may already hold a later capture when this cover first appears.
        // Try the preview's durable identity as well as its matching completion's row ID.
        let photoID = completion?.captureID == preview.id ? completion?.id : preview.id
        do {
            saved = try RecentPhotoPresentation.load(in: modelContext, startingAt: photoID)
            if saved != nil { initialImage = preview.image }
            else if completion?.captureID == preview.id {
                openError = String(localized: "Photos could not be loaded. Please try again.")
            }
        } catch {
            openError = String(localized: "Photos could not be loaded. Please try again.")
        }
    }
}
