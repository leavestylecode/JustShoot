import XCTest
import SwiftUI
import SwiftData
import UIKit
@testable import JustShoot

@MainActor
final class PhotoDetailTransitionTests: XCTestCase {
    private func makePhoto() async throws -> Photo {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let photo = Photo(assetLocalIdentifier: nil, imageData: data)
        _ = await ImageLoader.shared.loadThumbnail(imageData: data, photoId: photo.id, maxPixel: 120)
        return photo
    }

    private func grid(_ photos: [Photo], source: PhotoGridTransitionSource) -> (UICollectionView, PhotoGridView.Coordinator) {
        let parent = PhotoGridView(photos: photos, columns: 4, cornerRadius: 8,
            isSelecting: .constant(false), selectedPhotos: .constant([]), onOpen: { _ in }, transitionSource: source)
        let coordinator = PhotoGridView.Coordinator(parent)
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            collectionViewLayout: SquareGridLayout())
        collection.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        coordinator.makeDataSource(for: collection)
        collection.delegate = coordinator
        coordinator.apply(photos: photos, animating: false)
        collection.layoutIfNeeded()
        source.collectionView = collection
        return (collection, coordinator)
    }

    func testZoomSourceFollowsCurrentPhotoAcrossReorderAndDeletion() async throws {
        let first = try await makePhoto(), second = try await makePhoto()
        defer {
            ImageLoader.shared.removeDiskCache(for: first.id)
            ImageLoader.shared.removeDiskCache(for: second.id)
        }
        let source = PhotoGridTransitionSource()
        let (collection, coordinator) = grid([first, second], source: source)
        source.currentPhotoID = second.id
        XCTAssertTrue(source.sourceView === source.cell(for: second.id)?.contentView)
        XCTAssertNotNil(source.sourceView)
        coordinator.apply(photos: [second, first], animating: false)
        collection.layoutIfNeeded()
        XCTAssertTrue(source.sourceView === collection.cellForItem(at: IndexPath(item: 0, section: 0))?.contentView)
        coordinator.apply(photos: [first], animating: false)
        collection.layoutIfNeeded()
        XCTAssertNil(source.sourceView, "A deleted source must fall back instead of zooming to a reused cell")
        source.currentPhotoID = first.id
        XCTAssertNotNil(source.sourceView)
        collection.contentOffset.y = 500
        XCTAssertNil(source.sourceView, "An offscreen source must not return an unrelated visible cell")
    }

    func testCoveredGridKeepsVisibleTransitionImagesButOrdinaryHidingReleasesThem() async throws {
        let photo = try await makePhoto()
        let photoID = photo.id
        defer { ImageLoader.shared.removeDiskCache(for: photoID) }
        let source = PhotoGridTransitionSource()
        let (collection, coordinator) = grid([photo], source: source)
        let cell = try XCTUnwrap(source.cell(for: photo.id))
        source.currentPhotoID = photo.id
        let image = try XCTUnwrap(cell.transitionImage)
        coordinator.setActive(false, in: collection)
        XCTAssertTrue(cell.transitionImage === image)
        coordinator.setActive(true, in: collection)
        source.currentPhotoID = nil
        coordinator.setActive(false, in: collection)
        XCTAssertNil(cell.transitionImage)
    }

    func testNativeDismissalYieldsToMagnifiedPhotoAndDoesNotInstallCompetingPan() throws {
        let viewport = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let photo = ZoomingScrollView(contentView: UIImageView(), naturalSize: CGSize(width: 1200, height: 900),
            dismiss: DragDismissController(usesSystemTransition: true))
        photo.frame = viewport.bounds
        viewport.addSubview(photo)
        photo.layoutIfNeeded()
        let dismissPans = (photo.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
            .filter { $0 !== photo.panGestureRecognizer }
        XCTAssertEqual(dismissPans.count, 1)
        XCTAssertFalse(try XCTUnwrap(dismissPans.first).isEnabled)
        let center = CGPoint(x: 195, y: 422)
        XCTAssertTrue(PhotoDetailHostingController.canBeginDismissal(at: center, in: viewport))
        let alignment = try XCTUnwrap(PhotoDetailHostingController.photoAlignmentRect(in: viewport))
        XCTAssertEqual(alignment.width, viewport.bounds.width, accuracy: 0.5)
        XCTAssertEqual(alignment.height, viewport.bounds.width * 0.75, accuracy: 0.5)
        XCTAssertEqual(alignment.midY, viewport.bounds.midY, accuracy: 0.5)
        photo.setZoomScale(2, animated: false)
        photo.layoutIfNeeded()
        XCTAssertFalse(PhotoDetailHostingController.canBeginDismissal(at: center, in: viewport))
        XCTAssertTrue(photo.isScrollEnabled)
        photo.setZoomScale(1, animated: false)
        XCTAssertTrue(PhotoDetailHostingController.canBeginDismissal(at: center, in: viewport))
    }

    func testNativePresentationClearsSelectionOnExternalDismissAndCanReopen() async throws {
        let photo = try await makePhoto()
        let photoID = photo.id
        defer { ImageLoader.shared.removeDiskCache(for: photoID) }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let source = PhotoGridTransitionSource()
        let (collection, gridCoordinator) = grid([photo], source: source)
        let anchor = PhotoPresentationAnchor()
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        anchor.view.addSubview(collection)
        defer { window.isHidden = true; window.rootViewController = nil }
        var selection: PhotoDetailSelection? = PhotoDetailSelection(startPhoto: photo, photos: [photo])
        let presentation = PhotoDetailPresentation(selection: Binding(get: { selection }, set: { selection = $0 }),
            source: source, container: container)
        let coordinator = PhotoDetailPresentation.Coordinator(presentation)
        coordinator.update(in: anchor)
        try await waitFor { coordinator.host != nil }
        let first = try XCTUnwrap(coordinator.host)
        XCTAssertEqual(first.modalPresentationStyle, .fullScreen)
        if #available(iOS 18.0, *) { XCTAssertNotNil(first.preferredTransition) }
        try await waitFor { first.presentingViewController != nil && !first.isBeingPresented && first.transitionCoordinator == nil }
        // Simulate the same UIKit dismissal used by the interactive zoom gesture.
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Photo detail after native zoom"
        attachment.lifetime = .keepAlways
        add(attachment)
        first.dismiss(animated: false)
        try await waitFor { coordinator.host == nil && anchor.presentedViewController == nil && anchor.transitionCoordinator == nil }
        XCTAssertNil(selection)
        XCTAssertNil(source.currentPhotoID)
        selection = PhotoDetailSelection(startPhoto: photo, photos: [photo])
        coordinator.update(in: anchor)
        try await waitFor { coordinator.host != nil }
        let second = try XCTUnwrap(coordinator.host)
        XCTAssertFalse(first === second)
        try await waitFor { !second.isBeingPresented && second.transitionCoordinator == nil }
        selection = nil
        coordinator.update(in: anchor)
        try await waitFor { coordinator.host == nil }
        withExtendedLifetime(gridCoordinator) {}
    }

    func testQueuedPresentationHonorsCancellationAndDismantling() async throws {
        let photo = try await makePhoto()
        let photoID = photo.id
        defer { ImageLoader.shared.removeDiskCache(for: photoID) }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let anchor = PhotoPresentationAnchor()
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var selection: PhotoDetailSelection? = PhotoDetailSelection(startPhoto: photo, photos: [photo])
        let presentation = PhotoDetailPresentation(selection: Binding(get: { selection }, set: { selection = $0 }),
            source: PhotoGridTransitionSource(), container: container)
        let coordinator = PhotoDetailPresentation.Coordinator(presentation)
        coordinator.update(in: anchor)
        XCTAssertNil(coordinator.host, "Presentation must leave the SwiftUI update before creating its navigation stack")
        selection = nil
        coordinator.update(in: anchor)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(coordinator.host, "The queued update must read the latest selection")
        XCTAssertNil(anchor.presentedViewController)
        selection = PhotoDetailSelection(startPhoto: photo, photos: [photo])
        coordinator.update(in: anchor)
        coordinator.invalidate()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(coordinator.host, "A dismantled presenter must cancel queued work")
        XCTAssertNil(anchor.presentedViewController)
        withExtendedLifetime(container) {}
    }

    func testGalleryToolbarStaysUnchangedWhileOpeningAndClosingPhoto() async throws {
        let photo = try await makePhoto()
        let photoID = photo.id
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        let root = UIHostingController(rootView: TabView {
            NavigationStack { GalleryView() }.tabItem { Label("Photos", systemImage: "photo.stack") }
            Color.black.tabItem { Label("Films", systemImage: "camera.filters") }
        }.modelContainer(container).tint(.white).preferredColorScheme(.dark))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            ImageLoader.shared.removeDiskCache(for: photoID)
        }
        try await waitFor { self.photoGrid(in: root.view)?.numberOfItems(inSection: 0) == 1 }
        let collection = try XCTUnwrap(photoGrid(in: root.view))
        let navigation = try XCTUnwrap(viewControllers(in: root).compactMap { $0 as? UINavigationController }
            .first { collection.isDescendant(of: $0.view) })
        let originalButtons = toolbarSignature(navigation)
        XCTAssertEqual(toolbarItems(navigation).count, 2, "The fixture must show the gallery's layout and selection buttons")
        for _ in 0..<2 {
            collection.delegate?.collectionView?(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
            try await assertToolbar(navigation, remains: originalButtons)
            try await waitFor {
                guard let detail = root.presentedViewController as? PhotoDetailHostingController else { return false }
                return !detail.isBeingPresented && detail.transitionCoordinator == nil
            }
            let detail = try XCTUnwrap(root.presentedViewController as? PhotoDetailHostingController)
            if #available(iOS 18.0, *) { XCTAssertNotNil(detail.preferredTransition) }
            let detailNavigation = try XCTUnwrap(viewControllers(in: detail).compactMap { $0 as? UINavigationController }.first)
            XCTAssertEqual(toolbarItems(detailNavigation).count, 2, "Detail must retain its own close and information buttons")
            detail.dismiss(animated: true)
            try await assertToolbar(navigation, remains: originalButtons)
            try await waitFor { root.presentedViewController == nil && root.transitionCoordinator == nil }
            XCTAssertEqual(toolbarSignature(navigation), originalButtons)
            // Let SwiftUI apply the UIKit dismissal callback to the grid's presentation binding.
            await Task.yield()
        }
        withExtendedLifetime(container) {}
    }

    private func viewControllers(in controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap { viewControllers(in: $0) }
    }

    private func toolbarItems(_ navigation: UINavigationController) -> [UIBarButtonItem] {
        let item = navigation.navigationBar.topItem
        return (item?.leftBarButtonItems ?? []) + (item?.rightBarButtonItems ?? [])
            + (item?.leadingItemGroups ?? []).flatMap(\.barButtonItems)
            + (item?.trailingItemGroups ?? []).flatMap(\.barButtonItems)
    }

    private func toolbarSignature(_ navigation: UINavigationController) -> [String] {
        [navigation.navigationBar.topItem?.title ?? "nil", "hidden=\(navigation.isNavigationBarHidden)"]
            + toolbarItems(navigation).map {
                "\($0.accessibilityLabel ?? $0.title ?? "unlabeled") enabled=\($0.isEnabled)"
            }
    }

    private func assertToolbar(_ navigation: UINavigationController, remains expected: [String],
        file: StaticString = #filePath, line: UInt = #line) async throws {
        // Sample throughout the animation, including the first destination layout.
        // Checking only the final state misses preferences leaking into the source.
        for _ in 0..<60 {
            XCTAssertEqual(toolbarSignature(navigation), expected, file: file, line: line)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func photoGrid(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView, collection.accessibilityIdentifier == "gallery.grid" { return collection }
        return view.subviews.lazy.compactMap { self.photoGrid(in: $0) }.first
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "Presentation did not settle")
    }
}
