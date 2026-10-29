@preconcurrency import Photos
import os

/// PhotoKit editing requests use UInt IDs, unlike PHImageManager's Int32 IDs.
/// Cancellation, timeout and late callbacks all finish this continuation once.
struct DeferredEditingInput: @unchecked Sendable {
    let value: PHContentEditingInput
}

final class DeferredPhotoEditingRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<DeferredEditingInput?, Never>?
        var requestID: PHContentEditingInputRequestID?
        var timeout: Task<Void, Never>?
        var finished = false
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    static func input(for asset: PHAsset) async throws -> PHContentEditingInput {
        let request = Self()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let installed = request.state.withLock {
                    guard !$0.finished else { return false }
                    $0.continuation = continuation
                    return true
                }
                guard installed else { continuation.resume(returning: nil); return }
                let options = PHContentEditingInputRequestOptions()
                options.isNetworkAccessAllowed = true
                options.canHandleAdjustmentData = { _ in false }
                let id = asset.requestContentEditingInput(with: options) { input, _ in
                    request.finish(input.map(DeferredEditingInput.init))
                }
                let cancel = request.state.withLock {
                    $0.requestID = id
                    return $0.cancelled
                }
                if cancel { asset.cancelContentEditingInputRequest(id) }
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    request.cancel(asset: asset)
                }
                let finished = request.state.withLock {
                    guard !$0.finished else { return true }
                    $0.timeout = timeout
                    return false
                }
                if finished { timeout.cancel() }
            }
        } onCancel: { request.cancel(asset: asset) }
        try Task.checkCancellation()
        guard let result else { throw PhotoLibraryError.saveFailed }
        return result.value
    }

    private func finish(_ input: DeferredEditingInput?) {
        let result = state.withLock { state -> (CheckedContinuation<DeferredEditingInput?, Never>?, Task<Void, Never>?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            let result = (state.continuation, state.timeout)
            state.continuation = nil
            state.timeout = nil
            return result
        }
        result.1?.cancel()
        result.0?.resume(returning: input)
    }

    private func cancel(asset: PHAsset) {
        let result = state.withLock { state -> (CheckedContinuation<DeferredEditingInput?, Never>?, PHContentEditingInputRequestID?, Task<Void, Never>?) in
            guard !state.finished else { return (nil, nil, nil) }
            state.finished = true
            state.cancelled = true
            let continuation = state.continuation
            let timeout = state.timeout
            state.continuation = nil
            state.timeout = nil
            return (continuation, state.requestID, timeout)
        }
        result.2?.cancel()
        if let id = result.1 { asset.cancelContentEditingInputRequest(id) }
        result.0?.resume(returning: nil)
    }
}
