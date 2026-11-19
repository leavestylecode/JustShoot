import Foundation
import os

private enum PreviewTargetPreparation {
    static let queue = DispatchQueue(label: "com.justshoot.preview-targets", qos: .userInitiated)
}

/// GPU completion returns a reusable target before releasing its in-flight permit.
/// A single lock coordinates resize invalidation and late completions at the old size.
final class PreviewTargetPool<Value: Sendable>: Sendable {
    private struct Size: Equatable, Sendable {
        let width: Int
        let height: Int
    }
    private struct State: Sendable {
        var size: Size?
        var available: [Value] = []
        var revision: UInt64 = 0
        var isAllocating = false

        mutating func select(_ size: Size?) {
            guard self.size != size else { return }
            self.size = size
            revision &+= 1
            available.removeAll()
        }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maximumCount: Int
    private let preparationQueue: DispatchQueue

    init(maximumCount: Int = 3, preparationQueue: DispatchQueue? = nil) {
        self.maximumCount = max(0, maximumCount)
        self.preparationQueue = preparationQueue ?? PreviewTargetPreparation.queue
    }

    func invalidate() {
        state.withLock { $0.select(nil) }
    }

    var availableCount: Int { state.withLock { $0.available.count } }
    var isPreparing: Bool { state.withLock { $0.isAllocating } }

    func take(width: Int, height: Int) -> Value? {
        let size = Size(width: width, height: height)
        return state.withLock {
            $0.select(size)
            return $0.available.popLast()
        }
    }

    /// A miss starts one background allocation. Replenishing also requests the next
    /// target after a hit, so a single-use drawable can be ready for the next frame.
    /// Size and lifecycle revisions discard stale results.
    func request(width: Int, height: Int, replenish: Bool = false, allocate: @escaping @Sendable () -> Value?) -> Value? {
        guard width > 0, height > 0 else { return nil }
        let size = Size(width: width, height: height)
        let (value, revision): (Value?, UInt64?) = state.withLock {
            $0.select(size)
            let available = $0.available.popLast()
            guard available == nil || replenish, maximumCount > 0, !$0.isAllocating else { return (available, nil) }
            $0.isAllocating = true
            return (available, $0.revision)
        }
        if let revision {
            preparationQueue.async { [weak self] in
                guard let self else { return }
                let isCurrent = state.withLock { $0.revision == revision }
                let prepared = isCurrent ? autoreleasepool(invoking: allocate) : nil
                state.withLock {
                    $0.isAllocating = false
                    guard $0.revision == revision, let prepared,
                          $0.available.count < maximumCount else { return }
                    $0.available.append(prepared)
                }
            }
        }
        return value
    }

    func recycle(_ value: Value, width: Int, height: Int) {
        let size = Size(width: width, height: height)
        state.withLock {
            guard $0.size == size, $0.available.count < maximumCount else { return }
            $0.available.append(value)
        }
    }
}
