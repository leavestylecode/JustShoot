import XCTest
import SwiftData
@testable import JustShoot

@MainActor
final class RecentPhotoPresentationTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func save(_ id: UUID, at timestamp: TimeInterval, filter: String = "film", using saver: PhotoSaver) async throws {
        _ = try await saver.save(id: id, captureDate: Date(timeIntervalSince1970: timestamp),
            assetLocalIdentifier: "asset-\(id)", imageData: nil, filmPresetName: filter,
            filmDisplayLabel: nil, latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil)
    }

    func testFirstCommittedCaptureOpensEvenWhenPreviousQueryWasEmpty() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let staleQuery = try context.fetch(FetchDescriptor<Photo>())
        XCTAssertTrue(staleQuery.isEmpty)
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        let id = UUID()
        try await save(id, at: 100, using: saver)
        // No dependency on the old @Query snapshot or its next UI notification.
        let presentation = try XCTUnwrap(RecentPhotoPresentation.load(in: context))
        XCTAssertEqual(presentation.startPhoto.id, id)
        XCTAssertEqual(presentation.photos.map(\.id), [id])
        XCTAssertEqual(try RecentPhotoPresentation.latest(in: context)?.id, id)
    }

    func testNewCaptureReplacesOldSelectionWithoutChangingAnOpenSnapshot() async throws {
        let container = try makeContainer()
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        let old = UUID(), newest = UUID(), otherFilm = UUID()
        try await save(old, at: 100, using: saver)
        let first = try XCTUnwrap(RecentPhotoPresentation.load(in: container.mainContext))
        try await save(newest, at: 200, using: saver)
        try await save(otherFilm, at: 300, filter: "other", using: saver)
        let second = try XCTUnwrap(RecentPhotoPresentation.load(in: container.mainContext))
        XCTAssertEqual(first.startPhoto.id, old)
        XCTAssertEqual(first.photos.map(\.id), [old])
        XCTAssertEqual(second.startPhoto.id, otherFilm)
        XCTAssertEqual(second.photos.map(\.id), [old, newest, otherFilm])
    }

    func testCameraObservationFetchesOnlyTheNewestPhotoAcrossAllFilms() async throws {
        let container = try makeContainer()
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        let newest = UUID()
        try await save(UUID(), at: 100, using: saver)
        try await save(UUID(), at: 200, using: saver)
        try await save(newest, at: 300, filter: "other", using: saver)
        let descriptor = RecentPhotoPresentation.latestDescriptor()
        XCTAssertEqual(descriptor.fetchLimit, 1)
        let observed = try container.mainContext.fetch(descriptor)
        XCTAssertEqual(observed.map(\.id), [newest])
        let presentation = try XCTUnwrap(RecentPhotoPresentation.load(in: container.mainContext))
        XCTAssertEqual(presentation.photos.count, 3)
    }

    func testDeletedLastPhotoDoesNotProduceAnEmptySheet() async throws {
        let container = try makeContainer()
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        try await save(UUID(), at: 100, using: saver)
        let context = container.mainContext
        let latest = try XCTUnwrap(RecentPhotoPresentation.latest(in: context))
        context.delete(latest)
        try context.save()
        XCTAssertNil(try RecentPhotoPresentation.load(in: context))
        XCTAssertNil(try RecentPhotoPresentation.latest(in: context))
    }

    func testPendingPreviewOpensItsCommittedPhotoEvenWhenANewerCaptureAlreadyExists() async throws {
        let container = try makeContainer()
        let saver = await PhotoSaver.background(container: container)
        let completed = UUID()
        try await save(completed, at: 100, using: saver)
        try await save(UUID(), at: 200, filter: "other", using: saver)
        let presentation = try XCTUnwrap(RecentPhotoPresentation.load(in: container.mainContext,
            startingAt: completed))
        XCTAssertEqual(presentation.startPhoto.id, completed)
        XCTAssertEqual(presentation.photos.count, 2)
        XCTAssertNil(try RecentPhotoPresentation.load(in: container.mainContext, startingAt: UUID()),
            "A missing capture must not silently open a different photo")
    }

    func testUnlabelledLegacyPhotoRemainsVisibleAlongsideEveryFilm() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let legacy = Photo(assetLocalIdentifier: nil, imageData: nil)
        legacy.timestamp = Date(timeIntervalSince1970: 100)
        let film = Photo(assetLocalIdentifier: "film", imageData: nil, filmPresetName: "portra")
        film.timestamp = Date(timeIntervalSince1970: 200)
        let custom = Photo(assetLocalIdentifier: "custom", imageData: nil, filmPresetName: "custom-lut")
        custom.timestamp = Date(timeIntervalSince1970: 300)
        for photo in [custom, legacy, film] { context.insert(photo) }
        try context.save()
        let presentation = try XCTUnwrap(RecentPhotoPresentation.load(in: context))
        XCTAssertEqual(presentation.photos.map(\.id), [legacy.id, film.id, custom.id])
        XCTAssertEqual(presentation.startPhoto.id, custom.id)
        context.delete(custom)
        try context.save()
        XCTAssertEqual(try RecentPhotoPresentation.latest(in: context)?.id, film.id)
        XCTAssertEqual(try RecentPhotoPresentation.load(in: context)?.startPhoto.id, film.id)
    }
}
