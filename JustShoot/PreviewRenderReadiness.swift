import os

/// A GPU completion is useful only for the mounted, active renderer that submitted it.
/// Pausing invalidates outstanding tickets, including when the camera generation is unchanged.
final class PreviewRenderCompletionGate: Sendable {
    struct Ticket: Equatable, Sendable {
        let generation: UInt64
        let lutKey: String
        fileprivate let epoch: UInt64
    }

    private struct State {
        var active = false
        var epoch: UInt64 = 0
        var ticket: Ticket?
        var delivered = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func setActive(_ active: Bool) {
        state.withLock {
            guard $0.active != active else { return }
            $0.active = active
            $0.epoch &+= 1
            $0.ticket = nil
            $0.delivered = false
        }
    }

    func ticket(generation: UInt64, lutKey: String) -> Ticket? {
        state.withLock {
            guard $0.active else { return nil }
            let ticket = Ticket(generation: generation, lutKey: lutKey, epoch: $0.epoch)
            if $0.ticket != ticket {
                $0.ticket = ticket
                $0.delivered = false
            }
            return ticket
        }
    }

    /// Claim the one readiness/error notification before hopping to MainActor.
    func complete(_ ticket: Ticket) -> Bool {
        state.withLock {
            guard $0.active, $0.ticket == ticket, !$0.delivered else { return false }
            $0.delivered = true
            return true
        }
    }

    /// A queued MainActor notification may have become stale after the GPU completed.
    func isCurrent(_ ticket: Ticket) -> Bool {
        state.withLock { $0.active && $0.ticket == ticket }
    }
}

/// GPU callbacks record their timing directly; ordinary frames need no MainActor Task.
final class PreviewGPUStatistics: Sendable {
    struct Snapshot: Equatable, Sendable {
        var count = 0
        var totalMS = 0.0
        var maximumMS = 0.0
    }
    private struct State {
        var generation: UInt64?
        var snapshot = Snapshot()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func reset(generation: UInt64) {
        state.withLock { $0.generation = generation; $0.snapshot = Snapshot() }
    }

    func record(generation: UInt64, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds > 0 else { return }
        state.withLock {
            guard $0.generation == generation else { return }
            $0.snapshot.count += 1
            $0.snapshot.totalMS += milliseconds
            $0.snapshot.maximumMS = max($0.snapshot.maximumMS, milliseconds)
        }
    }

    func take(generation: UInt64) -> Snapshot {
        state.withLock {
            guard $0.generation == generation else { return Snapshot() }
            let snapshot = $0.snapshot
            $0.snapshot = Snapshot()
            return snapshot
        }
    }
}
