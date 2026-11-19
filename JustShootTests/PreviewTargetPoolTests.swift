import XCTest
import os
@testable import JustShoot

final class PreviewTargetPoolTests: XCTestCase {
    @MainActor
    func testColdDrawDoesNotWaitForAllocationAndRepeatedMissesShareOneRequest() async throws {
        let pool = PreviewTargetPool<Int>()
        let started = expectation(description: "Background allocation started")
        let released = OSAllocatedUnfairLock(initialState: false)
        defer { released.withLock { $0 = true } }
        XCTAssertNil(pool.request(width: 816, height: 1088) {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            for _ in 0..<600 {
                if released.withLock({ $0 }) { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return 42
        })
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<120 {
            XCTAssertNil(pool.request(width: 816, height: 1088) {
                XCTFail("A cold draw must not queue a second allocation")
                return 99
            })
        }
        released.withLock { $0 = true }
        try await Self.waitForPreparation(pool)
        XCTAssertEqual(pool.take(width: 816, height: 1088), 42)
    }

    func testResizeAwayAndBackDiscardsTheOldAllocationRevision() async throws {
        let pool = PreviewTargetPool<Int>()
        let started = expectation(description: "Old allocation started")
        let released = OSAllocatedUnfairLock(initialState: false)
        defer { released.withLock { $0 = true } }
        _ = pool.request(width: 816, height: 1088) {
            started.fulfill()
            for _ in 0..<600 {
                if released.withLock({ $0 }) { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return 1
        }
        await fulfillment(of: [started], timeout: 2)
        _ = pool.take(width: 744, height: 992)
        _ = pool.take(width: 816, height: 1088)
        released.withLock { $0 = true }
        try await Self.waitForPreparation(pool)
        XCTAssertEqual(pool.availableCount, 0)
        XCTAssertNil(pool.request(width: 816, height: 1088) { 2 })
        try await Self.waitForPreparation(pool)
        XCTAssertEqual(pool.take(width: 816, height: 1088), 2)
    }

    func testFailedAllocationCanRetryWithoutBlockingLaterDraws() async throws {
        let pool = PreviewTargetPool<Int>()
        XCTAssertNil(pool.request(width: 816, height: 1088) { nil })
        try await Self.waitForPreparation(pool)
        XCTAssertEqual(pool.availableCount, 0)
        XCTAssertNil(pool.request(width: 816, height: 1088) { 7 })
        try await Self.waitForPreparation(pool)
        XCTAssertEqual(pool.take(width: 816, height: 1088), 7)
    }

    func testConsumingADrawableReplenishesOneSlotAndPauseDiscardsTheOutstandingRequest() async throws {
        let pool = PreviewTargetPool<Int>(maximumCount: 1)
        XCTAssertNil(pool.request(width: 8, height: 4, replenish: true) { 1 })
        try await Self.waitForPreparation(pool)
        let started = expectation(description: "Next drawable requested")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        XCTAssertEqual(pool.request(width: 8, height: 4, replenish: true) {
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return 2
        }, 1)
        await fulfillment(of: [started], timeout: 2)
        pool.invalidate()
        XCTAssertNil(pool.request(width: 8, height: 4, replenish: true) {
            XCTFail("The previous request is still in flight")
            return 3
        })
        release.signal()
        try await Self.waitForPreparation(pool)
        XCTAssertNil(pool.take(width: 8, height: 4))
    }

    func testInvalidOrDisabledRequestsNeverAllocate() {
        let pool = PreviewTargetPool<Int>()
        let disabled = PreviewTargetPool<Int>(maximumCount: 0)
        let unexpected: @Sendable () -> Int? = { XCTFail("Invalid request allocated a target"); return 1 }
        XCTAssertNil(pool.request(width: 0, height: 1088, allocate: unexpected))
        XCTAssertNil(pool.request(width: 816, height: -1, allocate: unexpected))
        XCTAssertNil(disabled.request(width: 816, height: 1088, allocate: unexpected))
        XCTAssertFalse(pool.isPreparing)
        XCTAssertFalse(disabled.isPreparing)
    }

    private static func waitForPreparation(_ pool: PreviewTargetPool<Int>) async throws {
        for _ in 0..<400 {
            if !pool.isPreparing { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Target allocation did not finish")
    }

    func testCompletedTargetsAreAvailableForTheNextFrameWithoutAMainActorHop() async {
        let pool = PreviewTargetPool<Int>()
        XCTAssertNil(pool.take(width: 816, height: 1088))
        await Task.detached { pool.recycle(42, width: 816, height: 1088) }.value
        XCTAssertEqual(pool.take(width: 816, height: 1088), 42)
        XCTAssertEqual(pool.availableCount, 0)
    }

    func testLateCompletionsAtTheOldSizeCannotPolluteTheNewTargetPool() {
        let pool = PreviewTargetPool<Int>()
        _ = pool.take(width: 816, height: 1088)
        pool.recycle(1, width: 816, height: 1088)
        XCTAssertNil(pool.take(width: 744, height: 992))
        pool.recycle(2, width: 816, height: 1088)
        XCTAssertEqual(pool.availableCount, 0)
        pool.recycle(3, width: 744, height: 992)
        XCTAssertEqual(pool.take(width: 744, height: 992), 3)
        XCTAssertNil(pool.take(width: 744, height: 992))
    }

    func testThePoolRemainsBoundedUnderConcurrentGPUCompletions() async {
        let pool = PreviewTargetPool<Int>(maximumCount: 3)
        _ = pool.take(width: 816, height: 1088)
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<30 {
                group.addTask { pool.recycle(value, width: 816, height: 1088) }
            }
        }
        XCTAssertEqual(pool.availableCount, 3)
        let values = (0..<3).compactMap { _ in pool.take(width: 816, height: 1088) }
        XCTAssertEqual(Set(values).count, 3)
        XCTAssertNil(pool.take(width: 816, height: 1088))
    }

    func testAResizeBurstWithAStableCommittedSizeReusesTheSameTarget() {
        let pool = PreviewTargetPool<Int>()
        var sizing = PreviewDrawableResizePolicy()
        let initial = CGSize(width: 816, height: 1088)
        _ = sizing.request(initial, at: 0, canRender: true)
        _ = pool.take(width: 816, height: 1088)
        pool.recycle(7, width: 816, height: 1088)
        for sample in 1...34 {
            let height = CGFloat(1088 - sample * 3)
            _ = sizing.request(CGSize(width: floor(height * 0.75), height: height), at: Double(sample) * 0.006, canRender: true)
            XCTAssertEqual(pool.take(width: Int(sizing.currentSize.width), height: Int(sizing.currentSize.height)), 7)
            pool.recycle(7, width: 816, height: 1088)
        }
        let final = sizing.settle(at: 1, canRender: true)!
        XCTAssertNil(pool.take(width: Int(final.width), height: Int(final.height)))
        pool.recycle(8, width: Int(final.width), height: Int(final.height))
        XCTAssertEqual(pool.take(width: Int(final.width), height: Int(final.height)), 8)
    }
}
