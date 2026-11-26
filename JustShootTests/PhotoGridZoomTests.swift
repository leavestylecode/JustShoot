import UIKit
import SwiftData
import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class PhotoGridZoomTests: XCTestCase {
    private func makeGrid(count: Int, columns: Int = 4) ->
        (UICollectionView, SquareGridLayout, UICollectionViewDiffableDataSource<Int, Int>) {
        let layout = SquareGridLayout(columns: columns)
        let grid = UICollectionView(frame: CGRect(x: 0, y: 0, width: 393, height: 600), collectionViewLayout: layout)
        grid.contentInsetAdjustmentBehavior = .never
        grid.contentInset = UIEdgeInsets(top: 40, left: 0, bottom: 64, right: 0)
        grid.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "test")
        let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: grid) { view, path, _ in
            view.dequeueReusableCell(withReuseIdentifier: "test", for: path)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(Array(0..<count))
        dataSource.applySnapshotUsingReloadData(snapshot)
        grid.layoutIfNeeded()
        return (grid, layout, dataSource)
    }

    func testZoomKeepsFocalPointAtSameViewportHeightFromDeepInLibrary() throws {
        let (grid, layout, dataSource) = makeGrid(count: 6_000)
        grid.contentOffset.y = 24_000
        grid.layoutIfNeeded()
        let point = CGPoint(x: 162, y: 254)
        let anchor = try XCTUnwrap(layout.anchor(at: point))
        let identifier = dataSource.itemIdentifier(for: anchor.indexPath)
        let initialSide = layout.tileSide

        for columns in [3, 2, 1, 4, 6, 9] {
            layout.update(columns: columns, around: anchor)
            let tile = try XCTUnwrap(layout.layoutAttributesForItem(at: anchor.indexPath))
            XCTAssertEqual(tile.frame.minY + tile.frame.height * anchor.tilePoint.y - grid.contentOffset.y,
                           point.y, accuracy: 1)
            XCTAssertEqual(dataSource.itemIdentifier(for: tile.indexPath), identifier)
            XCTAssertEqual(grid.contentOffset.x, 0, accuracy: 1)
            let visible = try XCTUnwrap(layout.layoutAttributesForElements(in: grid.bounds))
            XCTAssertTrue(visible.contains { $0.indexPath == anchor.indexPath })
            XCTAssertLessThan(visible.count, 250)
            if columns < 4 { XCTAssertGreaterThan(tile.frame.width, initialSide) }
        }
    }

    func testZoomKeepsOneNonoverlappingTilePerSlotWhileRowsReflow() throws {
        let (grid, layout, dataSource) = makeGrid(count: 6_000)
        let anchor = SquareGridLayout.Anchor(indexPath: IndexPath(item: 4_167, section: 0),
            tilePoint: CGPoint(x: 0.35, y: 0.6), viewportPoint: CGPoint(x: 209, y: 235))
        let wide = layout.geometry(for: 3).side
        let narrow = layout.geometry(for: 4).side
        let presentation = PhotoGridZoomFrame(grid: layout.geometry, side: wide + (narrow - wide) * 0.47,
            anchor: anchor, leadingSlots: [3: 1, 4: 0], leadingX: PhotoGridGeometry.margin)
        let viewport = CGRect(origin: .zero, size: grid.bounds.size).insetBy(dx: PhotoGridGeometry.margin, dy: 0)
        let items = presentation.items(in: viewport)
        let focus = presentation.focalSlot
        XCTAssertEqual(items[focus], anchor.indexPath.item)
        XCTAssertEqual(items.values.filter { $0 == anchor.indexPath.item }.count, 1)
        XCTAssertEqual(anchor.point(in: presentation.frame(at: focus)).y, anchor.viewportPoint.y, accuracy: 0.001)
        XCTAssertEqual(presentation.frame(at: .init(row: 0, column: 0)).minX, viewport.minX)
        XCTAssertEqual(items[.init(row: 1, column: 3)], 4_167 + 4)
        XCTAssertEqual(items[.init(row: 3, column: 1)], 4_167 + 3 * 3)
        for slot in items.keys {
            let right = PhotoGridGeometry.Slot(row: slot.row, column: slot.column + 1)
            let below = PhotoGridGeometry.Slot(row: slot.row + 1, column: slot.column)
            XCTAssertFalse(presentation.frame(at: slot).intersects(presentation.frame(at: right)))
            XCTAssertFalse(presentation.frame(at: slot).intersects(presentation.frame(at: below)))
        }
        XCTAssertEqual(dataSource.itemIdentifier(for: anchor.indexPath), 4_167)
    }

    func testChangingDensityChoosesCloserColumnAndMatchesTheSettledLayout() throws {
        let (grid, layout, dataSource) = makeGrid(count: 6_000)
        let path = IndexPath(item: 4_167, section: 0)
        grid.scrollToItem(at: path, at: .centeredVertically, animated: false)
        grid.layoutIfNeeded()
        let oldFrame = try XCTUnwrap(layout.layoutAttributesForItem(at: path)?.frame)
        let point = CGPoint(x: oldFrame.midX, y: oldFrame.midY - grid.bounds.minY)
        var anchor = try XCTUnwrap(layout.anchor(at: point))
        let leadingSlots = layout.zoomLeadingSlots(for: anchor)
        let leading = try XCTUnwrap(leadingSlots[3])
        XCTAssertEqual(leading, 2)
        let unaligned = layout.geometry(for: 3, leadingSlots: 0).frame(for: path.item)
        let aligned = layout.geometry(for: 3, leadingSlots: leading).frame(for: path.item)
        XCTAssertLessThan(abs(aligned.midX - oldFrame.midX), abs(unaligned.midX - oldFrame.midX))
        anchor.viewportPoint.y = layout.alignedViewportY(for: anchor, columns: 3, leadingSlots: leading)
        let settled = PhotoGridZoomFrame(grid: layout.geometry, side: layout.geometry(for: 3).side,
            anchor: anchor, leadingSlots: leadingSlots, leadingX: PhotoGridGeometry.margin)

        layout.update(columns: 3, leadingSlots: leading, around: anchor)
        let finalFrame = try XCTUnwrap(layout.layoutAttributesForItem(at: path)?.frame)
            .offsetBy(dx: -grid.bounds.minX, dy: -grid.bounds.minY)
        let focus = settled.frame(at: settled.focalSlot)
        XCTAssertEqual(focus.minX, finalFrame.minX, accuracy: 0.001)
        // UIKit rounds the scroll position to a display pixel.
        let pixel = 1 / max(1, grid.traitCollection.displayScale)
        XCTAssertEqual(focus.minY, finalFrame.minY, accuracy: pixel)
        XCTAssertEqual(focus.width, finalFrame.width, accuracy: 0.001)
        XCTAssertEqual(dataSource.itemIdentifier(for: path), 4_167)
        let viewport = CGRect(origin: .zero, size: grid.bounds.size).insetBy(dx: PhotoGridGeometry.margin, dy: 0)
        for (slot, item) in settled.items(in: viewport) {
            let resting = layout.geometry.frame(for: item).offsetBy(dx: -grid.bounds.minX, dy: -grid.bounds.minY)
            let preview = settled.frame(at: slot)
            XCTAssertEqual(preview.minX, resting.minX, accuracy: pixel)
            XCTAssertEqual(preview.minY, resting.minY, accuracy: pixel)
        }
    }

    func testResizingRevealsAPartialTrailingColumnWithoutShiftingTheLeadingEdge() throws {
        let (grid, layout, dataSource) = makeGrid(count: 600)
        let anchor = SquareGridLayout.Anchor(indexPath: IndexPath(item: 302, section: 0),
            tilePoint: CGPoint(x: 0.5, y: 0.5), viewportPoint: CGPoint(x: 100, y: 250))
        let viewport = CGRect(origin: .zero, size: grid.bounds.size).insetBy(dx: PhotoGridGeometry.margin, dy: 0)
        let wide = layout.geometry(for: 3).side
        let narrow = layout.geometry(for: 4).side
        let transition = PhotoGridZoomFrame(grid: layout.geometry, side: wide + (narrow - wide) * 0.25,
            anchor: anchor, leadingSlots: [:], leadingX: viewport.minX)
        let items = transition.items(in: viewport)
        let trailing = PhotoGridGeometry.Slot(row: 0, column: 3)
        XCTAssertNotNil(items[trailing])
        XCTAssertEqual(transition.frame(at: .init(row: 0, column: 0)).minX, viewport.minX)
        XCTAssertGreaterThan(transition.frame(at: trailing).maxX, viewport.maxX)
        XCTAssertTrue(items.values.allSatisfy { (0..<600).contains($0) })
        XCTAssertEqual(dataSource.itemIdentifier(for: anchor.indexPath), 302)
    }

    func testShortLibraryUsesLegalScrollBoundsWithSelectionPreserved() throws {
        let (grid, layout, dataSource) = makeGrid(count: 6, columns: 1)
        grid.allowsSelectionDuringEditing = true
        grid.isEditing = true
        let item = IndexPath(item: 5, section: 0)
        grid.selectItem(at: item, animated: false, scrollPosition: .bottom)
        XCTAssertEqual(grid.indexPathsForSelectedItems, [item])
        grid.layoutIfNeeded()
        let oldTile = try XCTUnwrap(layout.layoutAttributesForItem(at: item)).frame
        let anchor = SquareGridLayout.Anchor(indexPath: item, tilePoint: CGPoint(x: 0.5, y: 0.5),
            viewportPoint: CGPoint(x: oldTile.midX, y: oldTile.midY - grid.contentOffset.y))
        XCTAssertNil(layout.zoomLeadingSlots(for: anchor)[9])
        layout.update(columns: 9, around: anchor)

        let tile = try XCTUnwrap(layout.layoutAttributesForItem(at: item))
        XCTAssertLessThanOrEqual(tile.frame.maxX, grid.bounds.width)
        XCTAssertEqual(grid.contentOffset.y, -grid.adjustedContentInset.top, accuracy: 0.5)
        XCTAssertEqual(grid.indexPathsForSelectedItems, [item])
        XCTAssertEqual(dataSource.itemIdentifier(for: item), 5)
    }

    func testAccessibilityCanZoomOneStepAroundTheFocusedCell() throws {
        let (grid, layout, dataSource) = makeGrid(count: 100)
        let zoom = PhotoGridZoom()
        zoom.install(in: grid, layout: layout)
        defer { zoom.uninstall() }
        var chosen: Int?
        zoom.onChooseColumns = { chosen = $0 }
        let cell = try XCTUnwrap(grid.cellForItem(at: IndexPath(item: 12, section: 0)))
        XCTAssertTrue(zoom.adjust(in: cell, by: -1))
        zoom.completeImmediately()
        XCTAssertEqual(chosen, 3)
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(dataSource.itemIdentifier(for: IndexPath(item: 12, section: 0)), 12)
    }

    func testBrowseTapZoomsFromDenseLayoutsAndOpensAtThreeColumnsOrFewer() throws {
        let (grid, layout, dataSource) = makeGrid(count: 600, columns: 9)
        let zoom = PhotoGridZoom()
        zoom.install(in: grid, layout: layout)
        defer { zoom.uninstall() }
        let path = IndexPath(item: 275, section: 0)
        for columns in [4, 5, 9] {
            layout.update(columns: columns, around: nil)
            grid.scrollToItem(at: path, at: .centeredVertically, animated: false)
            grid.layoutIfNeeded()
            XCTAssertTrue(zoom.handleBrowseTap(at: path))
            zoom.completeImmediately()
            XCTAssertEqual(layout.columns, 3)
            XCTAssertNotNil(grid.cellForItem(at: path))
        }
        for columns in [3, 2, 1] {
            layout.update(columns: columns, around: nil)
            XCTAssertFalse(zoom.handleBrowseTap(at: path))
        }
        XCTAssertEqual(dataSource.itemIdentifier(for: path), 275)
    }

    func testPinchTracksScaleAndRestoresOneFingerScrollingOnRelease() async throws {
        let (grid, layout, dataSource) = makeGrid(count: 600)
        grid.contentOffset.y = 2_000
        grid.layoutIfNeeded()
        let zoom = PhotoGridZoom()
        zoom.install(in: grid, layout: layout)
        defer { zoom.uninstall() }
        var chosenColumns: Int?
        zoom.onChooseColumns = { chosenColumns = $0 }
        let pinch = SimulatedPinch()
        let anchor = try XCTUnwrap(layout.anchor(at: pinch.viewportPoint))
        let photo = dataSource.itemIdentifier(for: anchor.indexPath)
        let startSide = layout.tileSide

        pinch.phase = .began
        zoom.pinchChanged(pinch)
        XCTAssertFalse(grid.panGestureRecognizer.isEnabled)
        pinch.phase = .changed
        pinch.scale = 1.3
        zoom.pinchChanged(pinch)
        XCTAssertEqual(try XCTUnwrap(zoom.presentedSide), startSide * 1.3, accuracy: 0.001)
        XCTAssertTrue(zoom.isPresentingOverlay)
        XCTAssertEqual(layout.columns, 4, "The collection view should only reflow at the end of the gesture")
        pinch.scale = 1.75
        zoom.pinchChanged(pinch)
        XCTAssertEqual(try XCTUnwrap(zoom.presentedSide), startSide * 1.75, accuracy: 0.001)
        XCTAssertNil(chosenColumns)
        pinch.phase = .ended
        zoom.pinchChanged(pinch)
        XCTAssertTrue(grid.panGestureRecognizer.isEnabled)
        XCTAssertEqual(chosenColumns, 2)
        try await waitUntil { !zoom.isZooming }
        XCTAssertEqual(layout.columns, 2)
        XCTAssertFalse(zoom.isPresentingOverlay)
        XCTAssertEqual(dataSource.itemIdentifier(for: anchor.indexPath), photo)
        XCTAssertNotNil(grid.cellForItem(at: anchor.indexPath))
    }

    func testReversingDuringSettleStartsAtThePresentedZoom() async throws {
        let (grid, layout, dataSource) = makeGrid(count: 600)
        let zoom = PhotoGridZoom()
        zoom.install(in: grid, layout: layout)
        defer { zoom.uninstall() }
        let pinch = SimulatedPinch()
        pinch.phase = .began
        zoom.pinchChanged(pinch)
        pinch.phase = .changed
        pinch.scale = 1.27
        zoom.pinchChanged(pinch)
        pinch.phase = .ended
        zoom.pinchChanged(pinch)
        let visibleSide = try XCTUnwrap(zoom.presentedSide)
        pinch.phase = .began
        pinch.scale = 1
        zoom.pinchChanged(pinch)
        XCTAssertEqual(zoom.presentedSide, visibleSide)
        pinch.phase = .changed
        pinch.scale = 0.79
        zoom.pinchChanged(pinch)
        XCTAssertEqual(try XCTUnwrap(zoom.presentedSide), visibleSide * 0.79, accuracy: 0.001)
        pinch.phase = .ended
        zoom.pinchChanged(pinch)
        try await waitUntil { !zoom.isZooming }
        XCTAssertEqual(layout.columns, 4)
        XCTAssertTrue(grid.panGestureRecognizer.isEnabled)
        XCTAssertFalse(zoom.isPresentingOverlay)
        withExtendedLifetime(dataSource) {}
    }

    func testPinchIgnoresHorizontalFingerDriftAtBothZoomDirections() throws {
        let (grid, layout, dataSource) = makeGrid(count: 600)
        grid.contentOffset.y = 2_000
        grid.layoutIfNeeded()
        let zoom = PhotoGridZoom()
        zoom.install(in: grid, layout: layout)
        defer { zoom.uninstall() }
        let pinch = SimulatedPinch()
        let start = pinch.viewportPoint
        pinch.phase = .began
        zoom.pinchChanged(pinch)
        pinch.phase = .changed

        for scale in [CGFloat(1.3), CGFloat(0.8)] {
            pinch.scale = scale
            pinch.viewportPoint = start
            zoom.pinchChanged(pinch)
            let overlay = try XCTUnwrap(grid.subviews.compactMap { $0 as? PhotoGridZoomOverlay }.first)
            let canvas = try XCTUnwrap(overlay.subviews.first)
            let tiles = canvas.subviews
            XCTAssertFalse(tiles.isEmpty)
            let before = tiles.map(\.frame)
            XCTAssertEqual(before.map(\.minX).min(), PhotoGridGeometry.margin)
            for x in [CGFloat(30), CGFloat(330)] {
                pinch.viewportPoint.x = x
                zoom.pinchChanged(pinch)
                XCTAssertEqual(tiles.map(\.frame), before)
                XCTAssertEqual(canvas.subviews, tiles)
            }
        }
        zoom.completeImmediately()
        XCTAssertEqual(grid.contentOffset.x, 0)
        XCTAssertEqual(dataSource.itemIdentifier(for: IndexPath(item: 0, section: 0)), 0)
    }

    func testHostedGallerySettlesAndKeepsLoadedThumbnails() async throws {
        let scene = try await TestWindowScene.foreground()
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let suite = "gallery-zoom-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let samples = try (10...17).map { number in
            let name = String(format: "%05d_000", number)
            return try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "heic")))
        }
        let photos = (0..<72).map { Photo(assetLocalIdentifier: nil, imageData: samples[$0 % samples.count]) }
        photos.forEach { container.mainContext.insert($0) }
        try container.mainContext.save()
        let host = UIHostingController(rootView: NavigationStack { GalleryView(isRevealed: false) }
            .defaultAppStorage(defaults).preferredColorScheme(.light).modelContainer(container))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: suite)
            photos.forEach { ImageLoader.shared.removeDiskCache(for: $0.id) }
        }
        try await waitUntil {
            (self.grid(in: host.view)?.visibleCells as? [PhotoCell])?.contains { $0.transitionImage != nil } == true
        }
        let grid = try XCTUnwrap(grid(in: host.view))
        XCTAssertFalse(grid.showsVerticalScrollIndicator)
        XCTAssertFalse(grid.showsHorizontalScrollIndicator)
        let layout = try XCTUnwrap(grid.collectionViewLayout as? SquareGridLayout)
        let path = IndexPath(item: 29, section: 0)
        grid.scrollToItem(at: path, at: .centeredVertically, animated: false)
        try await waitUntil { self.visibleThumbnailsAreLoaded(in: grid) }
        let cell = try XCTUnwrap(grid.cellForItem(at: path) as? PhotoCell)
        XCTAssertTrue(cell.accessibilityCustomActions?.isEmpty == false)
        let coordinator = try XCTUnwrap(grid.delegate as? PhotoGridView.Coordinator)
        let scale = layout.tileSide
        let expectedColumns = layout.columns - 1
        let desiredSide = layout.geometry(for: expectedColumns).side
        let pinch = SimulatedPinch()
        pinch.viewportPoint = CGPoint(x: cell.frame.midX - grid.bounds.minX, y: cell.frame.midY - grid.bounds.minY)
        capture("gallery-before-zoom", in: host.view)
        pinch.phase = .began
        coordinator.zoom.pinchChanged(pinch)
        pinch.phase = .changed
        pinch.scale = (scale + (desiredSide - scale) * 0.65) / scale
        coordinator.zoom.pinchChanged(pinch)
        XCTAssertTrue(coordinator.zoom.isPresentingOverlay)
        XCTAssertTrue(cell.contentView.isHidden)
        capture("gallery-during-zoom", in: host.view)
        pinch.phase = .ended
        coordinator.zoom.pinchChanged(pinch)
        XCTAssertEqual(defaults.integer(forKey: "gallery.density"), 0)
        try await waitUntil {
            layout.columns == expectedColumns && self.visibleThumbnailsAreLoaded(in: grid)
                && defaults.integer(forKey: "gallery.density") == expectedColumns
        }
        XCTAssertFalse(coordinator.zoom.isPresentingOverlay)
        XCTAssertEqual((grid.cellForItem(at: path) as? PhotoCell)?.contentView.isHidden, false)
        XCTAssertEqual(defaults.integer(forKey: "gallery.density"), expectedColumns)
        XCTAssertGreaterThan(layout.tileSide, scale)
        XCTAssertNotNil((grid.cellForItem(at: path) as? PhotoCell)?.transitionImage)
        capture("gallery-after-zoom", in: host.view)

        let enlarged = try XCTUnwrap(grid.cellForItem(at: path))
        pinch.viewportPoint = CGPoint(x: enlarged.frame.midX - grid.bounds.minX, y: enlarged.frame.midY - grid.bounds.minY)
        pinch.phase = .began
        pinch.scale = 1
        coordinator.zoom.pinchChanged(pinch)
        pinch.phase = .changed
        pinch.scale = (desiredSide + (scale - desiredSide) * 0.65) / desiredSide
        coordinator.zoom.pinchChanged(pinch)
        capture("gallery-during-zoom-out", in: host.view)
        pinch.phase = .ended
        coordinator.zoom.pinchChanged(pinch)
        coordinator.zoom.completeImmediately()
        coordinator.setActive(false, in: grid)
        coordinator.syncPreferredColumns(expectedColumns)
        XCTAssertEqual(layout.columns, expectedColumns + 1, "A pending save must not revert the grid when it is covered")
        try await waitUntil { defaults.integer(forKey: "gallery.density") == expectedColumns + 1 }
        coordinator.setActive(true, in: grid)
        try await waitUntil { self.visibleThumbnailsAreLoaded(in: grid) }
        XCTAssertFalse(coordinator.zoom.isPresentingOverlay)
    }

    private func grid(in view: UIView) -> UICollectionView? {
        if let grid = view as? UICollectionView, grid.accessibilityIdentifier == "gallery.grid" { return grid }
        return view.subviews.lazy.compactMap { self.grid(in: $0) }.first
    }

    private func visibleThumbnailsAreLoaded(in grid: UICollectionView) -> Bool {
        let cells = grid.visibleCells.compactMap { $0 as? PhotoCell }
        return !cells.isEmpty && cells.allSatisfy { $0.transitionImage != nil }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(predicate())
    }

    private func capture(_ name: String, in view: UIView) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class SimulatedPinch: UIPinchGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var viewportPoint = CGPoint(x: 155, y: 245)
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override var numberOfTouches: Int { 2 }

    override func location(in view: UIView?) -> CGPoint {
        let origin = view?.bounds.origin ?? .zero
        return CGPoint(x: viewportPoint.x + origin.x, y: viewportPoint.y + origin.y)
    }
}
