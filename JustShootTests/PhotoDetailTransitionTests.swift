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

    func testNativePresentationPreservesSelectionWhileCoveredAndCanReopenAfterDismissal() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let photo = try await makePhoto()
        let photoID = photo.id
        defer { ImageLoader.shared.removeDiskCache(for: photoID) }
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
        // A full-screen sharing destination makes the viewer disappear without
        // dismissing it. Returning must retain the photo and its presentation.
        let selectedID = selection?.id
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        first.present(cover, animated: false)
        try await waitFor { first.viewIfLoaded?.window == nil && cover.presentingViewController != nil }
        await Task.yield()
        XCTAssertTrue(coordinator.host === first)
        XCTAssertEqual(selection?.id, selectedID)
        XCTAssertEqual(source.currentPhotoID, photoID)
        cover.dismiss(animated: false)
        try await waitFor { first.presentedViewController == nil && first.viewIfLoaded?.window != nil }
        XCTAssertTrue(coordinator.host === first)
        XCTAssertEqual(selection?.id, selectedID)
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

    func testCloseButtonDismissesWithoutAnotherRepresentableUpdate() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let photo = try await makePhoto()
        let photoID = photo.id
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let anchor = PhotoPresentationAnchor()
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer {
            anchor.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            ImageLoader.shared.removeDiskCache(for: photoID)
        }
        var selection: PhotoDetailSelection? = PhotoDetailSelection(startPhoto: photo, photos: [photo])
        let presentation = PhotoDetailPresentation(selection: Binding(get: { selection }, set: { selection = $0 }),
            source: PhotoGridTransitionSource(), container: container)
        let coordinator = PhotoDetailPresentation.Coordinator(presentation)
        coordinator.update(in: anchor)
        try await waitFor {
            guard let host = coordinator.host else { return false }
            return !host.isBeingPresented && host.transitionCoordinator == nil
        }
        try tapClose(in: XCTUnwrap(coordinator.host))
        XCTAssertNil(selection)
        // UIKit must close even when the covered gallery produces no SwiftUI update.
        try await waitFor { coordinator.host == nil && anchor.presentedViewController == nil }

        // A close received during opening must run after the presentation finishes.
        selection = PhotoDetailSelection(startPhoto: photo, photos: [photo])
        coordinator.update(in: anchor)
        try await waitFor { coordinator.host?.isBeingPresented == true }
        selection = nil
        coordinator.update(in: anchor)
        try await waitFor { coordinator.host == nil && anchor.presentedViewController == nil }
    }

    func testStaleDismissedSelectionCannotReopenAndLateCallbackCannotClearNextSession() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let photo = try await makePhoto()
        let photoID = photo.id
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let anchor = PhotoPresentationAnchor()
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer {
            anchor.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            ImageLoader.shared.removeDiskCache(for: photoID)
        }
        let firstSelection = PhotoDetailSelection(startPhoto: photo, photos: [photo])
        var selection: PhotoDetailSelection? = firstSelection
        let source = PhotoGridTransitionSource()
        // Model a binding value captured before the native interactive dismissal.
        let presentation = PhotoDetailPresentation(selection: Binding(get: { firstSelection }, set: { selection = $0 }),
            source: source, container: container)
        let coordinator = PhotoDetailPresentation.Coordinator(presentation)
        coordinator.update(in: anchor)
        try await waitFor {
            guard let host = coordinator.host else { return false }
            return !host.isBeingPresented && host.transitionCoordinator == nil
        }
        let first = try XCTUnwrap(coordinator.host)
        let lateCompletion = first.onDismiss
        first.dismiss(animated: true)
        try await waitFor { coordinator.host == nil && anchor.presentedViewController == nil }
        XCTAssertNil(selection)
        coordinator.update(in: anchor)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(coordinator.host, "A stale binding snapshot must not resurrect the dismissed presentation")
        let nextSelection = PhotoDetailSelection(startPhoto: photo, photos: [photo])
        XCTAssertNotEqual(firstSelection.id, nextSelection.id, "Opening the same photo is a new presentation")
        selection = nextSelection
        coordinator.parent = PhotoDetailPresentation(selection: Binding(get: { selection }, set: { selection = $0 }),
            source: source, container: container)
        coordinator.update(in: anchor)
        try await waitFor {
            guard let host = coordinator.host else { return false }
            return host !== first && !host.isBeingPresented && host.transitionCoordinator == nil
        }
        let next = try XCTUnwrap(coordinator.host)
        lateCompletion?()
        XCTAssertTrue(coordinator.host === next)
        XCTAssertEqual(selection?.id, nextSelection.id)
        try tapClose(in: next)
        try await waitFor { coordinator.host == nil && anchor.presentedViewController == nil }
    }

    func testQueuedPresentationHonorsCancellationAndDismantling() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let photo = try await makePhoto()
        let photoID = photo.id
        defer { ImageLoader.shared.removeDiskCache(for: photoID) }
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

    func testGalleryKeepsChosenLightAppearanceAcrossFirstPhotoAndLastDeletion() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIHostingController(rootView: NavigationStack { GalleryView() }
            .preferredColorScheme(AppAppearance.light.scheme).modelContainer(container))
        window.rootViewController = root
        let photo = try await makePhoto()
        let id = photo.id
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            ImageLoader.shared.removeDiskCache(for: id)
        }
        try await waitFor { root.view.traitCollection.userInterfaceStyle == .light }
        container.mainContext.insert(photo)
        try container.mainContext.save()
        try await waitFor { self.photoGrid(in: root.view)?.numberOfItems(inSection: 0) == 1 }
        XCTAssertEqual(root.view.traitCollection.userInterfaceStyle, .light)
        container.mainContext.delete(photo)
        try container.mainContext.save()
        try await waitFor { self.photoGrid(in: root.view) == nil }
        XCTAssertEqual(root.view.traitCollection.userInterfaceStyle, .light)
    }

    func testGalleryCanScrollLastRowAboveCapsuleTabBar() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        for _ in 0..<120 {
            container.mainContext.insert(Photo(assetLocalIdentifier: nil, imageData: nil))
        }
        try container.mainContext.save()
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let selection = Binding<MainTab>.constant(.photos)
        let root = UIHostingController(rootView: TabView(selection: selection) {
            NavigationStack { GalleryView() }.mainTabItem(.photos)
            Color.clear.mainTabItem(.films)
        }.environment(\.capsuleTabSelection, selection).modelContainer(container))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await waitFor { self.photoGrid(in: root.view)?.numberOfItems(inSection: 0) == 120 }
        let grid = try XCTUnwrap(photoGrid(in: root.view))
        grid.layoutIfNeeded()
        let last = IndexPath(item: 119, section: 0)
        grid.scrollToItem(at: last, at: .bottom, animated: false)
        grid.layoutIfNeeded()
        let cell = try XCTUnwrap(grid.cellForItem(at: last))
        let bar: UITabBar = try XCTUnwrap(identifiedView("main.tabs", in: root.view))
        XCTAssertLessThanOrEqual(cell.convert(cell.bounds, to: window).maxY, bar.convert(bar.bounds, to: window).minY)
    }

    func testCapsuleRestoresSelectionAndExposesFourNamedIconOnlyTabs() async throws {
        var selectedTab = MainTab.library
        let selection = Binding(get: { selectedTab }, set: { selectedTab = $0 })
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIHostingController(rootView: Color.clear.mainTabRoot(.library)
            .environment(\.capsuleTabSelection, selection))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        root.view.layoutIfNeeded()
        let bar: UITabBar = try XCTUnwrap(identifiedView("main.tabs", in: root.view))
        let items = try XCTUnwrap(bar.items)
        XCTAssertEqual(items.map(\.accessibilityLabel), MainTab.allCases.map { String(localized: $0.title) })
        XCTAssertTrue(items.allSatisfy { $0.title == nil && $0.image != nil && $0.selectedImage != nil })
        XCTAssertEqual(bar.selectedItem?.tag, MainTab.library.rawValue)
        let photos = try XCTUnwrap(items.first { $0.tag == MainTab.photos.rawValue })
        bar.delegate?.tabBar?(bar, didSelect: photos)
        XCTAssertEqual(selectedTab, .photos)
    }

    func testGalleryToolbarStaysUnchangedWhileOpeningAndClosingPhoto() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let photo = try await makePhoto()
        let photoID = photo.id
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
            XCTAssertEqual(toolbarItems(detailNavigation).count, 2, "Detail must retain its own close and share buttons")
            detail.dismiss(animated: true)
            try await assertToolbar(navigation, remains: originalButtons)
            try await waitFor { root.presentedViewController == nil && root.transitionCoordinator == nil }
            XCTAssertEqual(toolbarSignature(navigation), originalButtons)
            // Let SwiftUI apply the UIKit dismissal callback to the grid's presentation binding.
            await Task.yield()
        }
        withExtendedLifetime(container) {}
    }

    func testGalleryCloseButtonAndNativeDismissalAllowImmediateSingleTapReopening() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let photo = try await makePhoto()
        let photoID = photo.id
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        let root = UIHostingController(rootView: NavigationStack { GalleryView() }
            .modelContainer(container).tint(.white).preferredColorScheme(.dark))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            ImageLoader.shared.removeDiskCache(for: photoID)
        }
        try await waitFor { self.photoGrid(in: root.view)?.numberOfItems(inSection: 0) == 1 }
        let collection = try XCTUnwrap(photoGrid(in: root.view))
        for cycle in 0..<4 {
            // One user selection only. Do not manually refresh the representable/coordinator.
            collection.delegate?.collectionView?(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
            try await waitFor {
                guard let detail = root.presentedViewController as? PhotoDetailHostingController else { return false }
                return !detail.isBeingPresented && detail.transitionCoordinator == nil
            }
            let detail = try XCTUnwrap(root.presentedViewController as? PhotoDetailHostingController)
            if cycle.isMultiple(of: 2) {
                try tapClose(in: detail)
            } else {
                detail.dismiss(animated: true)
            }
            // The next tap happens as soon as UIKit finishes closing, with no extra
            // run-loop/animation delay to conceal stale gallery selection.
            try await waitFor { root.presentedViewController == nil && root.transitionCoordinator == nil }
        }
    }

    private func tapClose(in detail: UIViewController) throws {
        let navigation = try XCTUnwrap(viewControllers(in: detail).compactMap { $0 as? UINavigationController }.first)
        let item = try XCTUnwrap(navigation.navigationBar.topItem)
        let close = try XCTUnwrap(item.leftBarButtonItems?.first
            ?? item.leadingItemGroups.flatMap(\.barButtonItems).first)
        let action = try XCTUnwrap(close.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: close.target, from: close, for: nil))
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
        identifiedView("gallery.grid", in: view)
    }

    private func identifiedView<T: UIView>(_ identifier: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == identifier, let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.identifiedView(identifier, in: $0) as T? }.first
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "Presentation did not settle")
    }
}
