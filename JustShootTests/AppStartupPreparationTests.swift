import XCTest
import SwiftData
import os
@testable import JustShoot

private actor StartupTestGate {
    private var released = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor
final class AppStartupPreparationTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func filter(_ name: String) -> HomeCustomFilter {
        let id = UUID()
        return HomeCustomFilter(id: id, displayName: name, iso: 200, fileName: "\(id.uuidString).cube")
    }

    func testReadyWaitsForCustomFilterMetadataAndRepeatedCallsShareOneAttempt() async throws {
        let store = try container()
        let customFilter = filter("Prepared")
        let gate = StartupTestGate()
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let model = AppStartupPreparation(openStorage: { opens.withLock { $0 += 1 }; return store },
            loadCustomFilters: { _ in await gate.wait(); return [customFilter] })
        let first = Task { await model.prepare() }
        await gate.waitUntilStarted()
        let second = Task { await model.prepare() }
        XCTAssertNil(model.ready)
        XCTAssertTrue(model.isPreparing)
        await gate.release()
        await first.value
        await second.value
        XCTAssertEqual(opens.withLock { $0 }, 1)
        XCTAssertTrue(model.ready?.container === store)
        XCTAssertEqual(model.ready?.customFilters.map(\.id), [customFilter.id])
        XCTAssertFalse(model.isPreparing)
        XCTAssertFalse(model.hasFailed)
    }

    func testCancelledAttemptCannotReplaceANewerReadySnapshot() async throws {
        let store = try container()
        let old = filter("Old")
        let latest = filter("Latest")
        let gate = StartupTestGate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let model = AppStartupPreparation(openStorage: { store }, loadCustomFilters: { _ in
            let attempt = calls.withLock { $0 += 1; return $0 }
            if attempt == 1 { await gate.wait(); return [old] }
            return [latest]
        })
        let first = Task { await model.prepare() }
        await gate.waitUntilStarted()
        model.cancel()
        await model.prepare()
        XCTAssertEqual(model.ready?.customFilters.map(\.id), [latest.id])
        await gate.release()
        await first.value
        XCTAssertEqual(model.ready?.customFilters.map(\.id), [latest.id])
        XCTAssertFalse(model.hasFailed)
    }

    func testMetadataFailureRetriesWithoutReopeningTheSuccessfulStore() async throws {
        let store = try container()
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let model = AppStartupPreparation(openStorage: { opens.withLock { $0 += 1 }; return store },
            loadCustomFilters: { _ in
                let attempt = calls.withLock { $0 += 1; return $0 }
                if attempt == 1 { throw CocoaError(.fileReadCorruptFile) }
                return []
            })
        await model.prepare()
        XCTAssertTrue(model.hasFailed)
        XCTAssertNil(model.ready)
        await model.retry()
        XCTAssertFalse(model.hasFailed)
        XCTAssertNotNil(model.ready)
        XCTAssertEqual(opens.withLock { $0 }, 1)
    }

    func testAnUninterruptibleStoreOpenIsReusedAfterCancellation() async throws {
        let store = try container()
        let started = StartupTestGate()
        let releaseOpen = DispatchSemaphore(value: 0)
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let model = AppStartupPreparation(openStorage: {
            opens.withLock { $0 += 1 }
            Task { await started.release() }
            _ = releaseOpen.wait(timeout: .now() + 2)
            return store
        }, loadCustomFilters: { _ in [] })
        let first = Task { await model.prepare() }
        await started.wait()
        model.cancel()
        let second = Task { await model.prepare() }
        await Task.yield()
        releaseOpen.signal()
        await first.value
        await second.value
        XCTAssertEqual(opens.withLock { $0 }, 1)
        XCTAssertTrue(model.ready?.container === store)
    }

    func testDeadlineFailsIndependentlyOfAnUnresponsiveMetadataWaiter() async throws {
        let store = try container()
        let gate = StartupTestGate()
        let model = AppStartupPreparation(timeout: .milliseconds(40), openStorage: { store },
            loadCustomFilters: { _ in await gate.wait(); return [] })
        let attempt = Task { await model.prepare() }
        await gate.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.hasFailed)
        XCTAssertFalse(model.isPreparing)
        XCTAssertNil(model.ready)
        await gate.release()
        await attempt.value
        XCTAssertNil(model.ready)
        XCTAssertTrue(model.hasFailed)
    }

    func testBackgroundTimeDoesNotTriggerTheForegroundDeadlineAndResumeRestartsIt() async throws {
        let store = try container()
        let gate = StartupTestGate()
        let model = AppStartupPreparation(timeout: .milliseconds(80), openStorage: { store },
            loadCustomFilters: { _ in await gate.wait(); return [] })
        let attempt = Task { await model.prepare() }
        await gate.waitUntilStarted()
        model.setActive(false)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(model.isPreparing)
        XCTAssertFalse(model.hasFailed)
        model.setActive(true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(model.hasFailed)
        await gate.release()
        await attempt.value
        XCTAssertNotNil(model.ready)
        XCTAssertFalse(model.hasFailed)
    }

    func testDefaultPreparationReturnsExistingFiltersInNewestFirstOrder() async throws {
        let store = try container()
        let older = CustomLUT(displayName: "Older", fileName: "older.cube", iso: 100, dimension: 2)
        older.createdAt = Date(timeIntervalSince1970: 10)
        let newer = CustomLUT(displayName: "Newer", fileName: "newer.cube", iso: 400, dimension: 2)
        newer.createdAt = Date(timeIntervalSince1970: 20)
        store.mainContext.insert(older)
        store.mainContext.insert(newer)
        try store.mainContext.save()

        let model = AppStartupPreparation(openStorage: { store })
        await model.prepare()

        let filters = try XCTUnwrap(model.ready?.customFilters)
        XCTAssertEqual(filters.map(\.id), [newer.id, older.id])
        XCTAssertEqual(filters.map(\.fileName), ["newer.cube", "older.cube"])
    }

    func testPreparedCustomFilterCanBeDeletedBeforeTheLiveQueryArrives() throws {
        let store = try container()
        let context = store.mainContext
        let model = CustomLUT(displayName: "Prepared", fileName: "\(UUID().uuidString).cube", iso: 200, dimension: 2)
        context.insert(model)
        try context.save()
        let id = model.id
        let file = model.fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test LUT".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(try CustomLUTPersistence.deletePreparedCustomFilter(id: id, queried: [], in: context))
        XCTAssertTrue(try context.fetch(FetchDescriptor<CustomLUT>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnAlreadyMissingPreparedFilterDoesNotDeleteAnUnindexedFile() throws {
        let store = try container()
        let missing = CustomLUT(displayName: "Already removed", fileName: "\(UUID().uuidString).cube", iso: 200, dimension: 2)
        let file = missing.fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("kept until normal orphan maintenance".utf8)
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(try CustomLUTPersistence.deletePreparedCustomFilter(id: missing.id, queried: [], in: store.mainContext))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
