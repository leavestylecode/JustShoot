import XCTest
import SwiftData
import SwiftUI
import CoreImage
@testable import JustShoot

/// Parks the injected PhotoKit re-read so a real pipeline stays visibly in flight.
private actor ReviewFlowGate {
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]

    func wait(_ id: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    func resolve(_ id: String, with data: Data) {
        pending.removeValue(forKey: id)?.resume(returning: data)
    }
}

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
        // The pending preview owns the page: exactly its own zoomable page is mounted.
        // (The "must not open a different photo" rule itself is covered by the
        // RecentPhotoPresentation probe unit tests.)
        XCTAssertEqual(viewports(in: window).count, 1,
            "An unrelated saved photo must not replace the pending preview")
        try await snapshot(window, name: "recent-preview-all-photos")
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    func testPendingPreviewStaysZoomableAndReportsSlowSave() async throws {
        let container = try container()
        let lut = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let ciImage = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 64))
        let data = try XCTUnwrap(CIContext().jpegRepresentation(of: ciImage, colorSpace: FilmImagePipeline.colorSpace))
        let recipe = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "flow", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil,
            photoDisplayTime: nil, plan: .resolve(mode: .quality))
        let journalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let journal = CaptureJournal(root: journalRoot)
        _ = try journal.stage(recipe: recipe, imageData: data, movieURL: nil, lut: lut,
            deferredPhoto: DeferredPhotoState(width: 48, height: 64, assetIdentifier: recipe.id.uuidString))
        let gate = ReviewFlowGate()
        let pipeline = CapturePipeline(journal: journal,
            finalizeDeferredPhoto: { id, _ in try await gate.wait(id) },
            prepareDeferredEditingInput: { _ in nil },
            saveDeferredAdjustment: { _, _, _, _ in })
        await pipeline.configure(container: container)
        try await waitFor { pipeline.phases[recipe.id] == .preparing }

        let preview = CapturePreview(id: recipe.id, filterName: "flow",
            image: try XCTUnwrap(UIImage(data: data)))
        let window = try await host(NavigationStack {
            CapturePreviewReview(preview: preview, slowThreshold: 0.3, pipeline: pipeline, onClose: {})
        }.modelContainer(container).tint(.white).preferredColorScheme(.dark))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // The provisional preview must be interactive (zoom mounts) while the save is parked.
        try await waitFor { self.viewports(in: window).count > 0 }
        // A save parked past the threshold must surface the slow notice instead of silence.
        // SwiftUI Text does not reliably materialize as UILabel, so assert the side effect
        // the notice always emits alongside its text, keyed by this run's unique capture id.
        try await waitFor {
            let snapshot = try? await DiagnosticLogStore.shared.snapshot()
            let text = snapshot.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return text.contains("recent_photos_pending_slow") && text.contains(recipe.id.uuidString)
        }
        try await snapshot(window, name: "recent-preview-slow-save")

        await gate.resolve(recipe.id.uuidString, with: data)
        try await waitFor { pipeline.phases[recipe.id] == nil }
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

    private func waitFor(_ predicate: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !(await predicate()), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let settled = await predicate()
        XCTAssertTrue(settled, "Photo review did not settle")
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
