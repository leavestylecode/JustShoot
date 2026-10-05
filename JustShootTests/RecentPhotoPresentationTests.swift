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
        let presentation = try XCTUnwrap(RecentPhotoPresentation.load(in: context, filterName: "film"))
        XCTAssertEqual(presentation.startPhoto.id, id)
        XCTAssertEqual(presentation.photos.map(\.id), [id])
        XCTAssertEqual(try RecentPhotoPresentation.latest(in: context, filterName: "film")?.id, id)
    }

    func testNewCaptureReplacesOldSelectionWithoutChangingAnOpenSnapshot() async throws {
        let container = try makeContainer()
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        let old = UUID(), newest = UUID(), otherFilm = UUID()
        try await save(old, at: 100, using: saver)
        let first = try XCTUnwrap(RecentPhotoPresentation.load(in: container.mainContext, filterName: "film"))
        try await save(newest, at: 200, using: saver)
        try await save(otherFilm, at: 300, filter: "other", using: saver)
        let second = try XCTUnwrap(RecentPhotoPresentation.load(in: container.mainContext, filterName: "film"))
        XCTAssertEqual(first.startPhoto.id, old)
        XCTAssertEqual(first.photos.map(\.id), [old])
        XCTAssertEqual(second.startPhoto.id, newest)
        XCTAssertEqual(second.photos.map(\.id), [old, newest])
    }

    func testDeletedLastPhotoDoesNotProduceAnEmptySheet() async throws {
        let container = try makeContainer()
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        try await save(UUID(), at: 100, using: saver)
        let context = container.mainContext
        let latest = try XCTUnwrap(RecentPhotoPresentation.latest(in: context, filterName: "film"))
        context.delete(latest)
        try context.save()
        XCTAssertNil(try RecentPhotoPresentation.load(in: context, filterName: "film"))
        XCTAssertNil(try RecentPhotoPresentation.latest(in: context, filterName: "film"))
    }
}
