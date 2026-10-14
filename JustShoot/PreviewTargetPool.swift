import os

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
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maximumCount: Int

    init(maximumCount: Int = 3) { self.maximumCount = max(0, maximumCount) }

    var availableCount: Int { state.withLock { $0.available.count } }

    func take(width: Int, height: Int) -> Value? {
        let size = Size(width: width, height: height)
        return state.withLock {
            if $0.size != size {
                $0.size = size
                $0.available.removeAll()
            }
            return $0.available.popLast()
        }
    }

    func recycle(_ value: Value, width: Int, height: Int) {
        let size = Size(width: width, height: height)
        state.withLock {
            guard $0.size == size, $0.available.count < maximumCount else { return }
            $0.available.append(value)
        }
    }
}
