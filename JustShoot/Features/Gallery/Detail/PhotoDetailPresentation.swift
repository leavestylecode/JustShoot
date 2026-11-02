import SwiftUI
import SwiftData
import UIKit

struct PhotoDetailSelection: Identifiable {
    let id: UUID
    let startPhoto: Photo
    let photos: [Photo]

    init(startPhoto: Photo, photos: [Photo]) {
        id = startPhoto.id
        self.startPhoto = startPhoto
        self.photos = photos
    }
}

/// Resolve a fresh cell by photo identity for both directions of the transition.
/// Never retain a reusable cell or use an index captured before a deletion/reorder.
@MainActor
final class PhotoGridTransitionSource {
    weak var collectionView: UICollectionView?
    var currentPhotoID: UUID?

    func cell(for id: UUID) -> PhotoCell? {
        guard let collectionView,
              let dataSource = collectionView.dataSource as? UICollectionViewDiffableDataSource<Int, UUID>,
              let indexPath = dataSource.indexPath(for: id),
              let cell = collectionView.cellForItem(at: indexPath) as? PhotoCell,
              cell.frame.intersects(collectionView.bounds) else { return nil }
        return cell
    }

    var sourceView: UIView? {
        guard let currentPhotoID, let cell = cell(for: currentPhotoID),
              cell.transitionImage != nil else { return nil }
        return cell.contentView
    }
}

/// UIKit supplies the grid's real source view without replacing reusable cells with
/// hosting views. Presentation owns the native zoom gesture; image zoom/paging stay in SwiftUI.
struct PhotoDetailPresentation: UIViewControllerRepresentable {
    @Binding var selection: PhotoDetailSelection?
    let source: PhotoGridTransitionSource
    let container: ModelContainer

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PhotoPresentationAnchor {
        let anchor = PhotoPresentationAnchor()
        anchor.onAppear = { [weak coordinator = context.coordinator, weak anchor] in
            if let anchor { coordinator?.update(in: anchor) }
        }
        return anchor
    }

    func updateUIViewController(_ anchor: PhotoPresentationAnchor, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(in: anchor)
    }

    static func dismantleUIViewController(_ anchor: PhotoPresentationAnchor, coordinator: Coordinator) {
        anchor.onAppear = nil
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator {
        var parent: PhotoDetailPresentation
        private(set) var host: PhotoDetailHostingController?
        private var updateScheduled = false
        private var isActive = true

        init(_ parent: PhotoDetailPresentation) { self.parent = parent }

        func update(in anchor: PhotoPresentationAnchor) {
            guard isActive, !updateScheduled else { return }
            updateScheduled = true
            // Building the destination navigation stack inside a SwiftUI view update
            // can briefly merge its toolbar preferences into the presenting stack.
            // Coalesce changes and create/present it after that update has finished.
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self else { return }
                self.updateScheduled = false
                if let anchor { self.reconcile(in: anchor) }
            }
        }

        func invalidate() {
            isActive = false
            host?.dismiss(animated: false)
        }

        private func reconcile(in anchor: PhotoPresentationAnchor) {
            guard isActive else { return }
            guard let selection = parent.selection else {
                guard let host, !host.isBeingDismissed else { return }
                if host.isBeingPresented {
                    host.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self, weak anchor] _ in
                        if let anchor { self?.update(in: anchor) }
                    }
                } else {
                    host.dismiss(animated: true)
                }
                return
            }
            guard host == nil, anchor.viewIfLoaded?.window != nil,
                  anchor.presentedViewController == nil else { return }
            let source = parent.source
            source.currentPhotoID = selection.id
            let initialImage = source.cell(for: selection.id)?.transitionImage
            let usesSystemTransition: Bool
            if #available(iOS 18.0, *) { usesSystemTransition = true }
            else { usesSystemTransition = false }
            let close: () -> Void = { [weak self] in self?.parent.selection = nil }
            let content = NavigationStack {
                PhotoDetailView(photo: selection.startPhoto, allPhotos: selection.photos,
                    initialImage: initialImage, usesSystemTransition: usesSystemTransition,
                    onSelectionChanged: { source.currentPhotoID = $0 }, onClose: close)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(action: close) { Image(systemName: "xmark").fontWeight(.semibold) }
                                .accessibilityLabel("Close")
                        }
                    }
            }
            .modelContainer(parent.container)
            .dynamicTypeSize(.large)
            .tint(.white)
            .preferredColorScheme(.dark)
            let controller = PhotoDetailHostingController(rootView: AnyView(content))
            controller.modalPresentationStyle = .fullScreen
            // Older systems use a quiet fade instead of an unrelated vertical sheet motion.
            controller.modalTransitionStyle = .crossDissolve
            if #available(iOS 18.0, *) {
                let options = UIViewController.Transition.ZoomOptions()
                options.interactiveDismissShouldBegin = { [weak controller] context in
                    context.willBegin && controller.map {
                        PhotoDetailHostingController.canBeginDismissal(at: context.location, in: $0.view)
                    } == true
                }
                options.alignmentRectProvider = { context in
                    PhotoDetailHostingController.photoAlignmentRect(in: context.zoomedViewController.view)
                }
                controller.preferredTransition = .zoom(options: options) { _ in source.sourceView }
            }
            controller.onDismiss = { [weak self] in
                guard let self else { return }
                self.host = nil
                source.currentPhotoID = nil
                if self.parent.selection?.id == selection.id { self.parent.selection = nil }
            }
            host = controller
            anchor.present(controller, animated: true)
        }
    }
}

final class PhotoPresentationAnchor: UIViewController {
    var onAppear: (() -> Void)?

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }
}

final class PhotoDetailHostingController: UIHostingController<AnyView> {
    var onDismiss: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    static func canBeginDismissal(at point: CGPoint, in view: UIView) -> Bool {
        guard let photo = photoViewport(at: point, in: view) else { return true }
        return photo.zoomScale <= photo.minimumZoomScale + 0.01
    }

    static func photoAlignmentRect(in view: UIView) -> CGRect? {
        view.layoutIfNeeded()
        guard let photo = photoViewport(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY), in: view) else { return nil }
        return photo.contentView.convert(photo.contentView.bounds, to: view)
    }

    private static func photoViewport(at point: CGPoint, in view: UIView) -> ZoomingScrollView? {
        var hit = view.hitTest(point, with: nil)
        while let candidate = hit {
            if let photo = candidate as? ZoomingScrollView { return photo }
            hit = candidate.superview
        }
        return nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A share sheet covering the viewer must not clear its selection.
        if isBeingDismissed || presentingViewController == nil {
            let completion = onDismiss
            onDismiss = nil
            completion?()
        }
    }
}
