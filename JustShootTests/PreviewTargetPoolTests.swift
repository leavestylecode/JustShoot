import XCTest
@testable import JustShoot

final class PreviewTargetPoolTests: XCTestCase {
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
