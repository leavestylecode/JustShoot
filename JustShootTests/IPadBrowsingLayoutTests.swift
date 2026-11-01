import SwiftUI
import SwiftData
import UIKit
import XCTest
@testable import JustShoot

@MainActor
final class IPadBrowsingLayoutTests: XCTestCase {
    func testBrowsingPagesResizeBetweenPortraitAndLandscapeWithoutLosingEditorDraft() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout coverage")
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let defaultsName = "ipad-browsing-layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let library = FilmCurveLibrary(defaults: defaults)
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let covers = try await FilmPresetCoverPreparation.prepareHome(displayScale: window.screen.scale)
        let home = HomePreparationSnapshot(customFilters: [], presetCovers: covers, customCover: nil)
        await FilmCardLibrary.shared.loadIfNeeded()
        let card = try XCTUnwrap(FilmCardLibrary.shared.catalog.cards.first)
        _ = await FilmCardLibrary.shared.image(for: card, maxPixel: 1024)
        let photo = try samplePhoto()
        container.mainContext.insert(photo)
        try container.mainContext.save()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            defaults.removePersistentDomain(forName: defaultsName)
            ImageLoader.shared.removeDiskCache(for: photo.id)
        }
        let pages: [(String, AnyView)] = [
            ("films", AnyView(FilmHomeView(preparedHome: home))),
            ("library", AnyView(NavigationStack { FilmCardLibraryView() })),
            ("film-detail", AnyView(NavigationStack { FilmCardDetailView(card: card) })),
            ("settings", AnyView(SettingsView())),
            ("curves", AnyView(NavigationStack { FilmCurveLibraryView() })),
            ("curve-editor", AnyView(NavigationStack { FilmCurveEditorView(curve: CustomFilmCurve(name: "Rotation Draft")) })),
            ("photo-viewer", AnyView(NavigationStack { PhotoDetailView(photo: photo, allPhotos: [photo]) }))
        ]
        for (name, page) in pages {
            let host = UIHostingController(rootView: page
                .modelContainer(container)
                .environmentObject(library)
                .environment(\.horizontalSizeClass, .regular)
                .dynamicTypeSize(.large)
                .preferredColorScheme(.dark))
            root.addChild(host)
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
            for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                         CGSize(width: 834, height: 1194)] {
                host.view.frame = CGRect(origin: .zero, size: size)
                host.view.setNeedsLayout()
                try await Task.sleep(for: .milliseconds(160))
                host.view.layoutIfNeeded()
                XCTAssertEqual(host.view.bounds.size, size)
                XCTAssertEqual(AppDelegate().application(UIApplication.shared, supportedInterfaceOrientationsFor: window), .all)
                if name == "curve-editor" {
                    let field = descendants(of: host.view, type: UITextField.self)
                        .first { $0.text == "Rotation Draft" }
                    XCTAssertEqual(try XCTUnwrap(field).text, "Rotation Draft")
                }
                let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
                let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "ipad-\(name)-\(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }

    func testGalleryKeepsSelectionAndFitsCellsWhenWindowWidthChanges() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout coverage")
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let photo = try samplePhoto()
        let state = GalleryState(selected: [photo.id])
        let host = UIHostingController(rootView: GalleryFixture(photo: photo, state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            ImageLoader.shared.removeDiskCache(for: photo.id)
        }
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            host.view.frame.size = size
            host.view.setNeedsLayout()
            try await Task.sleep(for: .milliseconds(160))
            host.view.layoutIfNeeded()
            let grid = try XCTUnwrap(descendants(of: host.view, type: UICollectionView.self)
                .first { $0.accessibilityIdentifier == "gallery.grid" })
            XCTAssertEqual(state.selected, [photo.id])
            XCTAssertEqual(grid.indexPathsForSelectedItems, [IndexPath(item: 0, section: 0)])
            for cell in grid.visibleCells {
                XCTAssertGreaterThanOrEqual(cell.frame.minX, 0)
                XCTAssertLessThanOrEqual(cell.frame.maxX, grid.bounds.width)
            }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "ipad-gallery-selection-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func descendants<T: UIView>(of view: UIView, type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: $0, type: type) }
    }

    private func samplePhoto() throws -> Photo {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            for (index, color) in [UIColor.systemBlue, .systemTeal, .systemOrange, .systemPink].enumerated() {
                color.setFill()
                context.fill(CGRect(x: index % 2 * 400, y: index / 2 * 300, width: 400, height: 300))
            }
        }
        return Photo(assetLocalIdentifier: nil, imageData: try XCTUnwrap(image.jpegData(compressionQuality: 0.8)))
    }
}

@MainActor
private final class GalleryState: ObservableObject {
    @Published var selected: Set<UUID>
    init(selected: Set<UUID>) { self.selected = selected }
}

private struct GalleryFixture: View {
    let photo: Photo
    @ObservedObject var state: GalleryState

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                PhotoGridView(photos: [photo],
                    columns: GalleryDensity.standard.columns(forWidth: min(geometry.size.width, PageLayout.browseWidth),
                        isRegular: true, accessibilitySize: false), cornerRadius: 8,
                    isSelecting: .constant(true), selectedPhotos: $state.selected, onOpen: { _ in })
                    .pageContentWidth(PageLayout.browseWidth)
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
