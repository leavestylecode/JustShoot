import SwiftUI
import SwiftData
import UIKit

struct PhotoDetailSelection: Identifiable {
    let id = UUID()
    let startPhoto: Photo
    let photos: [Photo]

    init(startPhoto: Photo, photos: [Photo]) {
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
            if let anchor { coordinator?.resume(in: anchor) }
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
        private var requestedSelection: PhotoDetailSelection?
        private var presentedSelectionID: UUID?
        private var dismissedSelectionID: UUID?

        init(_ parent: PhotoDetailPresentation) { self.parent = parent }

        func update(in anchor: PhotoPresentationAnchor) {
            // Read the binding during updateUIViewController so SwiftUI tracks it even
            // while the covered gallery no longer reads selection in its visible grid.
            let selection = parent.selection
            requestedSelection = selection?.id == dismissedSelectionID ? nil : selection
            scheduleUpdate(in: anchor)
        }

        func resume(in anchor: PhotoPresentationAnchor) {
            host?.completeDismissalIfDetached()
            // Appearance is not a new selection. Re-reading the previous representable's
            // binding here can resurrect the detail after an interactive dismissal.
            scheduleUpdate(in: anchor)
        }

        private func scheduleUpdate(in anchor: PhotoPresentationAnchor) {
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
            requestedSelection = nil
            host?.dismiss(animated: false)
        }

        private func reconcile(in anchor: PhotoPresentationAnchor) {
            guard isActive else { return }
            host?.completeDismissalIfDetached()
            if let host {
                if requestedSelection?.id != presentedSelectionID { dismiss(host) }
                return
            }
            guard let selection = requestedSelection,
                  selection.id != dismissedSelectionID,
                  anchor.viewIfLoaded?.window != nil,
                  anchor.presentedViewController == nil else { return }
            let source = parent.source
            source.currentPhotoID = selection.startPhoto.id
            let initialImage = source.cell(for: selection.startPhoto.id)?.transitionImage
            let usesSystemTransition: Bool
            if #available(iOS 18.0, *) { usesSystemTransition = true }
            else { usesSystemTransition = false }
            let close: () -> Void = { [weak self] in
                guard let self, self.presentedSelectionID == selection.id else { return }
                if self.requestedSelection?.id == selection.id { self.requestedSelection = nil }
                if self.parent.selection?.id == selection.id { self.parent.selection = nil }
                // The button must drive UIKit directly; a hidden SwiftUI source may not
                // send another representable update just because its binding changed.
                if let host = self.host { self.dismiss(host) }
            }
            let content = NavigationStack {
                PhotoDetailView(photo: selection.startPhoto, allPhotos: selection.photos,
                    initialImage: initialImage, usesSystemTransition: usesSystemTransition,
                    onSelectionChanged: { [weak self] photoID in
                        if self?.presentedSelectionID == selection.id { source.currentPhotoID = photoID }
                    }, onClose: close)
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
            controller.onAppear = { [weak self, weak anchor] in
                // A close requested during presentation runs once that transition ends.
                if let anchor { self?.scheduleUpdate(in: anchor) }
            }
            controller.onDismiss = { [weak self, weak anchor, weak controller] in
                guard let self, let controller, self.host === controller else { return }
                self.host = nil
                self.presentedSelectionID = nil
                self.dismissedSelectionID = selection.id
                source.currentPhotoID = nil
                if self.requestedSelection?.id == selection.id { self.requestedSelection = nil }
                if self.parent.selection?.id == selection.id { self.parent.selection = nil }
                if let anchor { self.scheduleUpdate(in: anchor) }
            }
            host = controller
            presentedSelectionID = selection.id
            anchor.present(controller, animated: true)
            controller.presentationController?.delegate = controller
        }

        private func dismiss(_ controller: PhotoDetailHostingController) {
            guard !controller.isBeingPresented, !controller.isBeingDismissed else { return }
            controller.dismiss(animated: true) { [weak controller] in
                controller?.completeDismissalIfDetached()
            }
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

final class PhotoDetailHostingController: UIHostingController<AnyView>, UIAdaptivePresentationControllerDelegate {
    var onAppear: (() -> Void)?
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Interactive zoom can finish detaching after viewDidDisappear. Wait for the
        // transition's outcome; a cancelled swipe or covering share sheet keeps selection.
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
            if !context.isCancelled { self?.completeDismissalIfDetached() }
        }
        DispatchQueue.main.async { [weak self] in self?.completeDismissalIfDetached() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        completeDismissalIfDetached()
    }

    func completeDismissalIfDetached() {
        guard presentingViewController == nil, !isBeingPresented else { return }
        let completion = onDismiss
        onDismiss = nil
        completion?()
    }
}
