import XCTest
import SwiftData
import SwiftUI
@testable import JustShoot

@MainActor
final class RecentPhotoReviewFlowTests: XCTestCase {
    func testExternalDeletionStaysAdjacentAndClosingLastPhotoReturnsToCamera() async throws {
        let container = try container()
        let photos = try makePhotos(in: container)
        let ids = photos.map(\.id)
        var selection = ids[2]
        var closed = false
        let view = NavigationStack {
            PhotoDetailView(photo: photos[2], allPhotos: photos,
                onSelectionChanged: { selection = $0 }, onClose: { closed = true })
        }.modelContainer(container).tint(.white).preferredColorScheme(.dark)
        let window = try await host(view)
        defer { cleanUp(window: window, ids: ids) }
        try await waitFor { self.viewports(in: window).count > 0 }
        try await snapshot(window, name: "recent-photos-all-films")
        container.mainContext.delete(photos[2])
        try container.mainContext.save()
        NotificationCenter.default.post(name: .photoLibraryDidReconcile, object: nil)
        try await waitFor { selection == ids[1] }
        XCTAssertFalse(closed)
        container.mainContext.delete(photos[1])
        try container.mainContext.save()
        NotificationCenter.default.post(name: .photoLibraryDidReconcile, object: nil)
        try await waitFor { selection == ids[0] }
        container.mainContext.delete(photos[0])
        try container.mainContext.save()
        NotificationCenter.default.post(name: .photoLibraryDidReconcile, object: nil)
        try await waitFor { closed }
    }

    func testPreviewAlreadyCommittedBeforePresentationOpensSavedPhotoAcrossFilms() async throws {
        let container = try container()
        let photos = try makePhotos(in: container)
        let ids = photos.map(\.id)
        let preview = CapturePreview(id: ids[1], filterName: "second-film",
            image: try XCTUnwrap(UIImage(data: try XCTUnwrap(photos[1].imageData))))
        let pipeline = CapturePipeline()
        var closed = false
        let view = NavigationStack {
            CapturePreviewReview(preview: preview, pipeline: pipeline, onClose: { closed = true })
        }.modelContainer(container).tint(.white).preferredColorScheme(.dark)
        let window = try await host(view)
        defer { cleanUp(window: window, ids: ids) }
        // No lastCompletion exists: the preview's committed identity must recover the detail.
        XCTAssertNil(pipeline.lastCompletion)
        try await waitFor { !self.viewports(in: window).isEmpty }
        XCTAssertFalse(closed)
        try await snapshot(window, name: "recent-preview-committed")
        for photo in photos { container.mainContext.delete(photo) }
        try container.mainContext.save()
        NotificationCenter.default.post(name: .photoLibraryDidReconcile, object: nil)
        try await waitFor { closed }
    }

    func testPendingPreviewKeepsAllPhotosAvailable() async throws {
        let container = try container()
        let photos = try makePhotos(in: container)
        let ids = photos.map(\.id)
        let preview = CapturePreview(id: UUID(), filterName: "another-film",
            image: try XCTUnwrap(UIImage(data: try XCTUnwrap(photos[1].imageData))))
        let window = try await host(NavigationStack {
            CapturePreviewReview(preview: preview, pipeline: CapturePipeline(), onClose: {})
        }.modelContainer(container).tint(.white).preferredColorScheme(.dark))
        defer { cleanUp(window: window, ids: ids) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(viewports(in: window).isEmpty, "An unrelated saved photo must not replace the pending preview")
        try await snapshot(window, name: "recent-preview-all-photos")
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func makePhotos(in container: ModelContainer) throws -> [Photo] {
        let colors: [UIColor] = [.systemOrange, .systemTeal, .systemIndigo]
        let photos = try colors.enumerated().map { index, color in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                UIColor.white.withAlphaComponent(0.6).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 100, y: 200, width: 400, height: 400))
            }
            let photo = Photo(assetLocalIdentifier: nil,
                imageData: try XCTUnwrap(image.jpegData(compressionQuality: 0.9)),
                filmPresetName: index == 0 ? nil : "film-\(index)")
            photo.timestamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60))
            container.mainContext.insert(photo)
            return photo
        }
        try container.mainContext.save()
        return photos
    }

    private func host<V: View>(_ view: V) async throws -> UIWindow {
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func cleanUp(window: UIWindow, ids: [UUID]) {
        window.isHidden = true
        window.rootViewController = nil
        for id in ids { ImageLoader.shared.removeDiskCache(for: id) }
    }

    private func viewports(in view: UIView) -> [ZoomingScrollView] {
        (view as? ZoomingScrollView).map { [$0] } ?? view.subviews.flatMap { viewports(in: $0) }
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "Photo review did not settle")
    }

    private func snapshot(_ window: UIWindow, name: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("photo_review_snapshot path=\(url.path)")
    }
}
