import Foundation
import os

/// Shared by copies of a journal. Only recovery/error reconciliation walks the whole tree;
/// ordinary writes replace the byte count of their small capture directory.
final class CaptureStorageLedger: Sendable {
    private struct State {
        var directories: [String: Int64]?
        var total: Int64 = 0
        var scans = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var bytes: Int64? { state.withLock { $0.directories == nil ? nil : $0.total } }
    var scanCount: Int { state.withLock { $0.scans } }

    func reconcile(_ directories: [String: Int64]) {
        state.withLock {
            $0.directories = directories
            $0.total = directories.values.reduce(0, +)
            $0.scans += 1
        }
    }

    func replace(directory: String, bytes: Int64) {
        state.withLock {
            guard $0.directories != nil else { return }
            let previous = $0.directories?[directory] ?? 0
            $0.total += bytes - previous
            if bytes == 0 { $0.directories?.removeValue(forKey: directory) }
            else { $0.directories?[directory] = bytes }
        }
    }

    func invalidate() { state.withLock { $0.directories = nil } }
}
