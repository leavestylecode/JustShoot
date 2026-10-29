import XCTest
import SwiftData
@testable import JustShoot

final class CaptureStorageLedgerTests: XCTestCase {
    @MainActor
    func testGalleryDeletionReconcilesWritesFromAnotherJournal() async throws {
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let id = UUID()
        try FileManager.default.createDirectory(at: journal.directory(for: id), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 600).write(to: journal.file("original.image", for: id))
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let pipeline = CapturePipeline(journal: journal)
        await pipeline.configure(container: container)
        XCTAssertEqual(journal.cachedStorageBytes, 600)
        XCTAssertTrue(pipeline.beginDeletion([id]))
        defer { pipeline.endDeletion([id]) }
        try CaptureJournal(root: journal.root).finish(id)
        await pipeline.completeDeletion([id])
        XCTAssertEqual(journal.cachedStorageBytes, 0, "Deleted files must not keep consuming the shutter budget")
        XCTAssertTrue(pipeline.recoveryIssues.isEmpty)
    }

    func testRepeatedAdmissionDoesNotRescanAndMutationsKeepUsageAccurate() throws {
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        XCTAssertTrue(try journal.hasRoom(for: 1))
        let scans = journal.storageScanCount
        let lut = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let recipe = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "storage", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil, photoDisplayTime: nil)
        var job = try journal.stage(recipe: recipe, imageData: Data(repeating: 1, count: 100), movieURL: nil, lut: lut, reserved: true)
        try journal.writeRenderedImage(Data(repeating: 2, count: 200), for: job.id)
        // The video encoder writes on its own queue; committing its manifest accounts for it.
        try Data(repeating: 3, count: 300).write(to: journal.file("rendered.mov", for: job.id))
        job.hasRenderedMovie = true
        try journal.update(job)
        for _ in 0..<20 { XCTAssertTrue(try journal.hasRoom(for: 1)) }
        XCTAssertEqual(journal.storageScanCount, scans)
        let cached = try XCTUnwrap(journal.cachedStorageBytes)
        XCTAssertEqual(cached, try journal.diskUsage())
        try journal.finish(job.id)
        XCTAssertEqual(journal.cachedStorageBytes, 0)
    }

    func testRecoveryIncludesUnknownRetainedFilesAndCopiesShareAccounting() throws {
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        _ = try journal.diskUsage()
        let folder = journal.root.appendingPathComponent("unknown")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 600).write(to: folder.appendingPathComponent("original"))
        let copy = journal
        _ = try copy.recoverInventory()
        XCTAssertEqual(journal.cachedStorageBytes, 600)
        XCTAssertFalse(try journal.hasRoom(for: CaptureJournal.maximumBytes - 599))
    }
}
