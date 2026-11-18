import Foundation
import os

/// The 24 MP deferred final can arrive either from the native capture delegate (fast path) or
/// from a PhotoKit re-read (fallback and recovery). This registry parks one waiter per capture
/// and buffers early deliveries, so "bytes arrive while nobody waits yet" cannot be lost.
/// One-shot resolution per slot mirrors DeferredPhotoEditingRequest's finish discipline.
final class FinalStillWaiterRegistry: Sendable {
    enum WaitError: Error, Equatable {
        case timedOut
    }

    private enum Slot {
        case waiting(UUID, CheckedContinuation<Data, any Error>, Task<Void, Never>)
        case buffered(Data)
    }
    private let slots = OSAllocatedUnfairLock(initialState: [UUID: Slot]())

    /// Await delegate-delivered final bytes. Data delivered before this call returns immediately.
    /// A slot holds at most one waiter; a duplicate concurrent wait for the same capture fails fast.
    func wait(id: UUID, timeout: TimeInterval = 120) async throws -> Data {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                slots.withLock { slots in
                    // PhotoKit can win before this child registers its continuation.
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    switch slots[id] {
                    case .buffered(let data):
                        slots[id] = nil
                        continuation.resume(returning: data)
                    case .waiting:
                        // One preparation task per capture owns the slot; a second waiter is a caller bug.
                        continuation.resume(throwing: CancellationError())
                    case nil:
                        let timeoutTask = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                            self?.settle(id, .failure(WaitError.timedOut), waiterID: waiterID)
                        }
                        slots[id] = .waiting(waiterID, continuation, timeoutTask)
                    }
                }
            }
        } onCancel: {
            settle(id, .failure(CancellationError()), waiterID: waiterID)
        }
    }

    /// Hand delegate bytes to the waiter, or buffer them for the next `wait`.
    /// Returns whether a parked waiter was resumed.
    @discardableResult
    func deliver(id: UUID, _ data: Data) -> Bool {
        settle(id, .success(data))
    }

    /// Drop buffered bytes and fail a parked waiter for a capture that no longer needs them.
    func discard(id: UUID) {
        settle(id, .failure(CancellationError()))
    }

    /// Resolve the slot exactly once. Success with no waiter is buffered for the next `wait`;
    /// failures are never buffered.
    @discardableResult
    private func settle(_ id: UUID, _ outcome: Result<Data, any Error>, waiterID: UUID? = nil) -> Bool {
        let pending = slots.withLock { slots -> (CheckedContinuation<Data, any Error>, Task<Void, Never>)? in
            switch slots[id] {
            case .waiting(let owner, let continuation, let timeout):
                guard waiterID == nil || waiterID == owner else { return nil }
                slots[id] = nil
                return (continuation, timeout)
            case .buffered, nil:
                guard waiterID == nil else { return nil }
                switch outcome {
                case .success(let data): slots[id] = .buffered(data)
                case .failure: slots[id] = nil
                }
                return nil
            }
        }
        guard let (continuation, timeout) = pending else { return false }
        timeout.cancel()
        switch outcome {
        case .success(let data): continuation.resume(returning: data)
        case .failure(let error): continuation.resume(throwing: error)
        }
        return true
    }
}

/// Maps AVFoundation photo uniqueIDs to the durable capture awaiting its native final.
/// Registered when a deferred capture delivers its proxy; consumed when the processed
/// final arrives later, cleared on terminal delegate callbacks or a bounded lifetime.
@MainActor
final class DeferredFinalExpectations {
    struct Entry {
        let captureID: UUID
        let handler: (Data) -> Void
    }

    private var entries: [Int64: Entry] = [:]
    private var timeouts: [Int64: Task<Void, Never>] = [:]

    func register(_ id: Int64, entry: Entry, lifetime: TimeInterval = 180) {
        entries[id] = entry
        timeouts.removeValue(forKey: id)?.cancel()
        timeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(lifetime)) } catch { return }
            self?.clear(id)
        }
    }

    /// Consume the expectation exactly once; nil when absent or already consumed.
    func consume(_ id: Int64) -> Entry? {
        timeouts.removeValue(forKey: id)?.cancel()
        return entries.removeValue(forKey: id)
    }

    func clear(_ id: Int64) {
        timeouts.removeValue(forKey: id)?.cancel()
        entries[id] = nil
    }
}
