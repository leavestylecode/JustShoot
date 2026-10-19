import UIKit

/// Shares one bounded decode while allowing each disappearing view to stop waiting.
/// When the last consumer leaves, queued image work is cancelled as well.
actor SharedImageRequests {
    private struct Request {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
    }

    private let worker: BlockingImageWork
    private var requests: [String: Request] = [:]

    init(worker: BlockingImageWork = .shared) {
        self.worker = worker
    }

    func image(for key: String, decode: @escaping @Sendable () -> UIImage?) async -> UIImage? {
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if requests[key] != nil {
                    requests[key]?.waiters[waiter] = continuation
                    return
                }
                let token = UUID()
                let task = Task {
                    let image = await worker.run(decode)
                    finish(key: key, token: token, image: image)
                }
                requests[key] = Request(token: token, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    private func finish(key: String, token: UUID, image: UIImage?) {
        guard let request = requests[key], request.token == token else { return }
        requests[key] = nil
        for continuation in request.waiters.values {
            continuation.resume(returning: image)
        }
    }

    private func cancel(key: String, waiter: UUID) {
        guard var request = requests[key], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        if request.waiters.isEmpty {
            requests[key] = nil
            request.task.cancel()
        } else {
            requests[key] = request
        }
        continuation.resume(returning: nil)
    }
}
