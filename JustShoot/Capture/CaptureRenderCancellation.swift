import Foundation
import os

/// Shares cancellation with a synchronous renderer running in a detached task.
/// An encoder already executing finishes its current call before observing cancellation.
final class CaptureRenderCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() { state.withLock { $0 = true } }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}
