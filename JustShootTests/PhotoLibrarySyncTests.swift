import SwiftData
import XCTest
import os
@testable import JustShoot

@MainActor
final class PhotoLibrarySyncTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Photo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    func testConcurrentStartsRegisterOnceOffTheMainThread() async throws {
        let store = try container()
        let calls = OSAllocatedUnfairLock(initialState: [Bool]())
        let sync = PhotoLibrarySync { _ in
            calls.withLock { $0.append(Thread.isMainThread) }
            return true
        }

        async let first: Void = sync.start(container: store)
        async let second: Void = sync.start(container: store)
        _ = await (first, second)
        await sync.start(container: store)

        XCTAssertEqual(calls.withLock { $0 }, [false])
    }

    func testStartRetriesAfterPhotosAccessBecomesAvailable() async throws {
        let store = try container()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let sync = PhotoLibrarySync { _ in
            calls.withLock {
                $0 += 1
                return $0 > 1
            }
        }

        await sync.start(container: store)
        await sync.start(container: store)
        await sync.start(container: store)

        XCTAssertEqual(calls.withLock { $0 }, 2)
    }
}
