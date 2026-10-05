import XCTest
import os
@testable import JustShoot

final class BlockingImageWorkTests: XCTestCase {
    func testDecodingConcurrencyIsBoundedAcrossManyRequests() async {
        let worker = BlockingImageWork(maximumConcurrentOperations: 2)
        let counts = OSAllocatedUnfairLock(initialState: (active: 0, peak: 0))
        await withTaskGroup(of: Int?.self) { group in
            for index in 0..<24 {
                group.addTask {
                    await worker.run {
                        counts.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
                        // Simulate a blocking codec, on the dedicated queue, never the task pool.
                        Thread.sleep(forTimeInterval: 0.005)
                        counts.withLock { $0.active -= 1 }
                        return index
                    }
                }
            }
            var completed = 0
            for await result in group { XCTAssertNotNil(result); completed += 1 }
            XCTAssertEqual(completed, 24)
        }
        XCTAssertLessThanOrEqual(counts.withLock { $0.peak }, 2)
        XCTAssertEqual(counts.withLock { $0.active }, 0)
    }

    func testCancellingAWaitingDecodeDoesNotWaitForTheBlockedCodec() async {
        let worker = BlockingImageWork(maximumConcurrentOperations: 1)
        let started = expectation(description: "First decode started")
        let release = DispatchSemaphore(value: 0)
        let first = Task {
            await worker.run {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let didRun = OSAllocatedUnfairLock(initialState: false)
        let cancelled = Task { await worker.run { didRun.withLock { $0 = true }; return 2 } }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertNil(result)
        XCTAssertFalse(didRun.withLock { $0 })
        release.signal()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, 1)
    }

    func testBundledHEIFCoverDecodesWithoutBlockingOtherSwiftTasks() async {
        let done = expectation(description: "Bundled HEIF decoded")
        let task = Task {
            let image = await FilmCardImageCache.shared.loadImage(imageName: "00001_000.heic",
                cacheKey: "heif-regression", maxPixel: 160)
            XCTAssertNotNil(image)
            done.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [done], timeout: 10)
    }
}
