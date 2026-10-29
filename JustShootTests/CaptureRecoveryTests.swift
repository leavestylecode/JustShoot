import XCTest
import SwiftData
@testable import JustShoot

@MainActor
final class CaptureRecoveryTests: XCTestCase {
    private func fixture() throws -> (CaptureJournal, CaptureRecipe, CubeLUT) {
        let lut = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let recipe = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "test", displayLabel: nil,
            focalLength: 28, outputQuality: 0.8, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil, photoDisplayTime: nil)
        return (journal, recipe, lut)
    }

    func testUnknownVersionIsVisibleAndItsOriginalCanBeExportedWithoutChangingIt() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let original = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/ZKkAAAAASUVORK5CYII=")!
        var job = try journal.stage(recipe: recipe, imageData: original, movieURL: nil, lut: lut)
        job.formatVersion = 99
        try journal.update(job)
        let inventory = try journal.recoverInventory()
        XCTAssertTrue(inventory.jobs.isEmpty)
        let issue = try XCTUnwrap(inventory.issues.first)
        XCTAssertEqual(issue.reason, .unsupportedVersion)
        XCTAssertTrue(issue.hasOriginal)
        let export = try journal.exportOriginal(for: issue)
        defer { ShareExportDirectory.application.remove(files: [export]) }
        XCTAssertEqual(try Data(contentsOf: export), original)
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: recipe.id)), original)
        XCTAssertGreaterThan(try journal.diskUsage(), 0)
    }

    func testIncompleteStagingAndMissingProcessedFilesRemainInTheRecoveryInventory() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        var job = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut)
        job.rendered = true
        try journal.update(job)
        let stagingID = UUID()
        let staging = journal.root.appendingPathComponent("staging-\(stagingID.uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([2]).write(to: staging.appendingPathComponent("original.image"))
        let inventory = try journal.recoverInventory()
        XCTAssertTrue(inventory.jobs.isEmpty)
        XCTAssertEqual(Set(inventory.issues.map(\.reason)), [.missingResources, .missingManifest])
        XCTAssertEqual(Set(inventory.issues.map(\.captureID)), [recipe.id, stagingID])
        XCTAssertTrue(inventory.issues.allSatisfy(\.hasOriginal))
    }

    func testARepairedPhotoCannotBeDeletedByAStaleRecoveryAction() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let job = try journal.stage(recipe: recipe, imageData: Data([1, 2]), movieURL: nil, lut: lut)
        try Data("broken".utf8).write(to: journal.file("manifest.json", for: recipe.id))
        let issue = try XCTUnwrap(journal.inventory().issues.first)
        XCTAssertEqual(issue.reason, .unreadableManifest)
        try journal.update(job)
        XCTAssertThrowsError(try journal.discardRecoveryFiles(for: issue))
        XCTAssertEqual(try journal.jobs().map(\.id), [recipe.id])
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: recipe.id)), Data([1, 2]))
    }

    func testDeletingAFallbackCommitsTheIndexAndImmediatelyReleasesItsQueueSlot() async throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        _ = try journal.stage(recipe: recipe, imageData: Data([1, 2]), movieURL: nil, lut: lut)
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let saver = await PhotoSaver.background(container: container)
        _ = try await saver.save(id: recipe.id, captureDate: recipe.captureDate, assetLocalIdentifier: nil,
            imageData: Data([1, 2]), filmPresetName: "test", filmDisplayLabel: nil,
            latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil)
        var queue = CaptureQueueState()
        XCTAssertTrue(queue.reserve(recipe.id, bytes: 128, maximumJobs: 1))
        queue.activate([recipe.id])
        queue.finish(recipe.id, retained: true)
        XCTAssertFalse(queue.reserve(UUID(), bytes: 128, maximumJobs: 1))
        let removed = try await saver.delete(ids: [recipe.id], journal: journal)
        queue.remove(removed)
        XCTAssertEqual(removed, [recipe.id])
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Photo>()).isEmpty)
        XCTAssertTrue(try journal.inventory().jobs.isEmpty)
        XCTAssertEqual(queue.retainedCount, 0)
        XCTAssertTrue(queue.reserve(UUID(), bytes: 128, maximumJobs: 1))
    }

    func testExplicitDiscardRemovesOnlyTheChosenRecoveryDirectory() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        var job = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut)
        job.formatVersion = 99
        try journal.update(job)
        let unrelatedID = UUID()
        let unrelated = journal.directory(for: unrelatedID)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data([2]).write(to: unrelated.appendingPathComponent("original.image"))
        let issue = try XCTUnwrap(journal.inventory().issues.first { $0.captureID == recipe.id })
        try journal.discardRecoveryFiles(for: issue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.directory(for: recipe.id).path))
        XCTAssertEqual(try Data(contentsOf: unrelated.appendingPathComponent("original.image")), Data([2]))
    }

    func testAProcessingFailureWithAllFilesPresentCanStillBeExportedAndExplicitlyDiscarded() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let original = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/ZKkAAAAASUVORK5CYII=")!
        let job = try journal.stage(recipe: recipe, imageData: original, movieURL: nil, lut: lut)
        try Data([1]).write(to: journal.file("lut.bin", for: recipe.id))
        XCTAssertThrowsError(try journal.lut(for: job))
        try journal.markNeedsAttention(recipe.id)
        let inventory = try journal.recoverInventory()
        XCTAssertEqual(inventory.jobs.map(\.id), [recipe.id])
        let issue = try XCTUnwrap(inventory.issues.first)
        XCTAssertEqual(issue.reason, .processingFailed)
        let export = try journal.exportOriginal(for: issue)
        defer { ShareExportDirectory.application.remove(files: [export]) }
        XCTAssertEqual(try Data(contentsOf: export), original)
        try journal.discardRecoveryFiles(for: issue)
        XCTAssertTrue(try journal.inventory().jobs.isEmpty)
        XCTAssertTrue(try journal.inventory().issues.isEmpty)
    }

    func testAnExistingAssetRowAliasProtectsAndDeletesTheCaptureBeforeItsAssetIdentifierIsCheckpointed() async throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let job = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut)
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let saver = await PhotoSaver.background(container: container)
        let alias = UUID()
        _ = try await saver.save(id: alias, assetLocalIdentifier: "asset-a", imageData: nil,
            filmPresetName: "test", filmDisplayLabel: nil, latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil)
        let savedID = try await saver.save(id: recipe.id, assetLocalIdentifier: "asset-a", imageData: nil,
            filmPresetName: "test", filmDisplayLabel: nil, latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil)
        XCTAssertEqual(savedID, alias)
        XCTAssertNil(job.assetIdentifier)
        let ids = CaptureDeletionSelection.captureIDs(rowIDs: [alias], assetIDs: ["asset-a"], jobs: [job],
            libraryCaptureIDs: [recipe.id])
        XCTAssertEqual(ids, [alias, recipe.id])
        let gate = CaptureDeletionGate()
        XCTAssertFalse(gate.begin(ids, active: [recipe.id]))
        XCTAssertTrue(gate.begin(ids, active: []))
        defer { gate.end(ids) }
        let removed = try await saver.delete(ids: Array(ids), journal: journal)
        XCTAssertEqual(removed, ids)
        XCTAssertTrue(try journal.jobs().isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Photo>()).isEmpty)
    }

    func testDeferredSourceAssetProtectsTheCaptureBeforeItsFilmAdjustmentCommits() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let state = DeferredPhotoState(width: 5712, height: 4284, assetIdentifier: "photos-proxy")
        let job = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut,
            deferredPhoto: state)
        let alias = UUID()
        let ids = CaptureDeletionSelection.captureIDs(rowIDs: [alias], assetIDs: ["photos-proxy"],
            jobs: [job], libraryCaptureIDs: [])
        XCTAssertEqual(ids, [alias, recipe.id])
        XCTAssertFalse(CaptureDeletionGate().begin(ids, active: [recipe.id]))
    }
}
