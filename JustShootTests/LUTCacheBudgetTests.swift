import XCTest
@testable import JustShoot

final class LUTCacheBudgetTests: XCTestCase {
    func testByteBudgetEvictsLeastRecentlyUsedTablesOfDifferentSizes() {
        var cache = ByteBudgetLRU<String, Data>(maximumBytes: 10)
        cache.insert(Data(repeating: 1, count: 6), forKey: "active", cost: 6)
        cache.insert(Data(repeating: 2, count: 4), forKey: "older", cost: 4)
        let activeSnapshot = cache.value(forKey: "active")
        cache.insert(Data(repeating: 3, count: 4), forKey: "new", cost: 4)

        XCTAssertNil(cache.value(forKey: "older"))
        XCTAssertEqual(cache.value(forKey: "active"), activeSnapshot)
        XCTAssertEqual(cache.retainedBytes, 10)
        XCTAssertEqual(cache.count, 2)
    }

    func testReplacementRemovalAndClearReleaseTheirByteCosts() {
        var cache = ByteBudgetLRU<String, Data>(maximumBytes: 10)
        cache.insert(Data(count: 7), forKey: "film", cost: 7)
        cache.insert(Data(count: 3), forKey: "film", cost: 3)
        cache.insert(Data(count: 5), forKey: "film#curve", cost: 5)
        XCTAssertEqual(cache.retainedBytes, 8)
        XCTAssertEqual(cache.removeValue(forKey: "film")?.count, 3)
        XCTAssertEqual(cache.retainedBytes, 5)
        cache.removeAll { _ in true }
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertEqual(cache.count, 0)
    }

    func testOversizedValueRemainsUsableWithoutEvictingOtherCachedValues() {
        var cache = ByteBudgetLRU<String, Data>(maximumBytes: 4)
        cache.insert(Data([1, 2]), forKey: "small", cost: 2)
        let captured = Data(repeating: 7, count: 8)
        XCTAssertFalse(cache.insert(captured, forKey: "large", cost: captured.count))
        XCTAssertNil(cache.value(forKey: "large"))
        XCTAssertEqual(cache.value(forKey: "small"), Data([1, 2]))
        XCTAssertEqual(captured, Data(repeating: 7, count: 8))
        XCTAssertEqual(cache.retainedBytes, 2)
    }

    func testLightweightRecipesRespectTheirIndependentEntryLimit() {
        var cache = ByteBudgetLRU<String, String>(maximumBytes: 0, maximumEntries: 2)
        cache.insert("recipe-a", forKey: "a", cost: 0)
        cache.insert("recipe-b", forKey: "b", cost: 0)
        _ = cache.value(forKey: "a")
        cache.insert("recipe-c", forKey: "c", cost: 0)
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.value(forKey: "a"), "recipe-a")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.retainedBytes, 0)
    }

    func testBudgetArithmeticDoesNotOverflowForLargeCosts() {
        var cache = ByteBudgetLRU<String, String>(maximumBytes: Int.max)
        cache.insert("large", forKey: "large", cost: Int.max)
        cache.insert("small", forKey: "small", cost: 1)
        XCTAssertNil(cache.value(forKey: "large"))
        XCTAssertEqual(cache.retainedBytes, 1)
    }
}
