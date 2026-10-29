import XCTest
import SwiftData
import os
@testable import JustShoot

final class CaptureStorageLedgerTests: XCTestCase {
    func testSufficientImmediateCapacityDoesNotQueryReclaimableStorage() throws {
        let importantCalls = OSAllocatedUnfairLock(initialState: 0)
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            capacityReader: { _, kind in
                switch kind {
                case .immediate: return 2_000_000_000
                case .importantUsage:
                    importantCalls.withLock { $0 += 1 }
                    throw CocoaError(.fileReadUnknown)
                }
            })
        defer { try? FileManager.default.removeItem(at: journal.root) }
        for _ in 0..<3 { XCTAssertTrue(try journal.hasRoom(for: 128 * 1_024 * 1_024)) }
        XCTAssertEqual(importantCalls.withLock { $0 }, 0,
            "A normal shutter must not wait for a reclaimable-space estimate")
    }

    func testLowImmediateCapacityStillAcceptsSufficientReclaimableSpace() throws {
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            capacityReader: { _, kind in
                switch kind {
                case .immediate: return 1
                case .importantUsage: return 2_000_000_000
                }
            })
        defer { try? FileManager.default.removeItem(at: journal.root) }
        XCTAssertTrue(try journal.hasRoom(for: 128 * 1_024 * 1_024))
    }

    func testAdmissionRejectsInsufficientCapacityIncludingSafetyMargin() throws {
        let reserved: Int64 = 128 * 1_024 * 1_024
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            capacityReader: { _, _ in reserved * 2 - 1 })
        defer { try? FileManager.default.removeItem(at: journal.root) }
        XCTAssertFalse(try journal.hasRoom(for: reserved))
    }

    func testCapacityIsReadAgainForEachAdmission() throws {
        let capacity = OSAllocatedUnfairLock(initialState: Int64(2_000_000_000))
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            capacityReader: { _, _ in capacity.withLock { $0 } })
        defer { try? FileManager.default.removeItem(at: journal.root) }
        XCTAssertTrue(try journal.hasRoom(for: 128 * 1_024 * 1_024))
        capacity.withLock { $0 = 1 }
        XCTAssertFalse(try journal.hasRoom(for: 128 * 1_024 * 1_024),
            "A previous successful check cannot hide storage consumed by other apps")
    }

    @MainActor
    func testSlowCapacityProbeDoesNotBlockUIOrRecoveryWorker() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            capacityReader: { _, _ in
                started.withLock { $0 = true }
                XCTAssertFalse(Thread.isMainThread)
                guard release.wait(timeout: .now() + 5) == .success else { return 0 }
                return 2_000_000_000
            })
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let pipeline = CapturePipeline(journal: journal)
        await pipeline.configure(container: container)
        let begin = ProcessInfo.processInfo.systemUptime
        let reservation = Task { await pipeline.reserve(lutBytes: 128) }
        while !started.withLock({ $0 }), ProcessInfo.processInfo.systemUptime - begin < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(started.withLock { $0 })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 2,
            "MainActor must stay responsive while the system storage query is blocked")
        let recoveryBegin = ProcessInfo.processInfo.systemUptime
        await pipeline.retryPending()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - recoveryBegin, 1,
            "A capacity query must not occupy the journal actor")
        release.signal()
        let id = await reservation.value
        XCTAssertNotNil(id)
        if let id { pipeline.cancelReservation(id) }
    }

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
