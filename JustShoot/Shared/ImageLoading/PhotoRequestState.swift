import Photos
import UIKit
import os

/// PhotoKit may deliver before returning its request ID, or after cancellation.
typealias PhotoImageRequestState = PhotoRequestState<UIImage>

final class PhotoRequestState<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value?, Never>?
        var requestID = PHInvalidImageRequestID
        var finished = false
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isFinished: Bool { state.withLock { $0.finished } }

    func install(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        let installed = state.withLock {
            guard !$0.finished else { return false }
            $0.continuation = continuation
            return true
        }
        if !installed { continuation.resume(returning: nil) }
        return installed
    }

    /// Returns true when the caller must cancel this ID immediately.
    func register(_ requestID: PHImageRequestID) -> Bool {
        state.withLock {
            guard !$0.finished else { return $0.cancelled }
            $0.requestID = requestID
            return false
        }
    }

    @discardableResult
    func finish(_ value: Value?) -> Bool {
        let result = state.withLock { state -> (Bool, CheckedContinuation<Value?, Never>?) in
            guard !state.finished else { return (false, nil) }
            state.finished = true
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        result.1?.resume(returning: value)
        return result.0
    }

    func cancel() -> (didFinish: Bool, requestID: PHImageRequestID) {
        let result = state.withLock { state -> (Bool, PHImageRequestID, CheckedContinuation<Value?, Never>?) in
            guard !state.finished else { return (false, PHInvalidImageRequestID, nil) }
            state.finished = true
            state.cancelled = true
            let continuation = state.continuation
            state.continuation = nil
            return (true, state.requestID, continuation)
        }
        result.2?.resume(returning: nil)
        return (result.0, result.1)
    }
}
