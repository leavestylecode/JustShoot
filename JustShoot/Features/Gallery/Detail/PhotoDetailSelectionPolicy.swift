import Foundation

enum PhotoDetailSelectionPolicy {
    /// Keep the current identity, or the nearest surviving neighbour in the original order.
    /// The stored IDs remain safe to inspect after SwiftData invalidates deleted models.
    static func selection(current: UUID?, previousIDs: [UUID], remainingIDs: [UUID]) -> UUID? {
        let remaining = Set(remainingIDs)
        if let current, remaining.contains(current) { return current }
        if let current, let index = previousIDs.firstIndex(of: current) {
            if let next = previousIDs.dropFirst(index + 1).first(where: remaining.contains) { return next }
            if let previous = previousIDs.prefix(index).reversed().first(where: remaining.contains) { return previous }
        }
        return remainingIDs.first
    }
}
