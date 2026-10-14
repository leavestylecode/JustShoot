import Foundation

/// A cache owns only its retained values. Callers may keep using values after eviction.
/// Synchronization belongs to the owner (an actor, a lock, or MainActor).
struct ByteBudgetLRU<Key: Hashable, Value> {
    let maximumBytes: Int
    let maximumEntries: Int?
    private var values: [Key: Value] = [:]
    private var costs: [Key: Int] = [:]
    private var accessOrder: [Key] = []
    private(set) var retainedBytes = 0

    var count: Int { values.count }

    init(maximumBytes: Int, maximumEntries: Int? = nil) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = maximumEntries.map { max(0, $0) }
    }

    mutating func value(forKey key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        return value
    }

    /// Oversized values remain usable by the caller but are never retained by the cache.
    @discardableResult
    mutating func insert(_ value: Value, forKey key: Key, cost: Int) -> Bool {
        removeValue(forKey: key)
        guard cost >= 0, cost <= maximumBytes, maximumEntries != 0 else { return false }
        while retainedBytes > maximumBytes - cost
            || maximumEntries.map({ count >= $0 }) == true {
            guard let oldest = accessOrder.first else { break }
            removeValue(forKey: oldest)
        }
        values[key] = value
        costs[key] = cost
        accessOrder.append(key)
        retainedBytes += cost
        return true
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let removed = values.removeValue(forKey: key) else { return nil }
        retainedBytes -= costs.removeValue(forKey: key) ?? 0
        accessOrder.removeAll { $0 == key }
        return removed
    }

    mutating func removeAll(where predicate: (Key) -> Bool) {
        for key in accessOrder.filter(predicate) { removeValue(forKey: key) }
    }
}

extension ByteBudgetLRU: Sendable where Key: Sendable, Value: Sendable {}
