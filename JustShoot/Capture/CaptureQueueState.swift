import Foundation

/// A capture occupies one slot from reservation until successful save or explicit deletion.
/// Durable and in-memory work use the same transitions, including recovery after a restart.
struct CaptureQueueState: Sendable {
    private enum Entry: Sendable {
        case reserved(Int64)
        case active
        case retained
        case recoveryIssue
    }

    private var entries: [UUID: Entry] = [:]
    private var recoveryRevision: UInt64 = 0

    var activeIDs: Set<UUID> {
        Set(entries.compactMap { id, entry in
            switch entry {
            case .reserved, .active: id
            case .retained, .recoveryIssue: nil
            }
        })
    }

    var pendingJobIDs: Set<UUID> {
        Set(entries.compactMap { id, entry in
            if case .reserved = entry { return nil }
            return id
        })
    }

    var pendingCount: Int { activeIDs.count }
    var retainedCount: Int {
        entries.values.reduce(0) { count, entry in
            if case .retained = entry { return count + 1 }
            return count
        }
    }
    var occupiedCount: Int { entries.count }
    var reservationCount: Int {
        entries.values.reduce(0) { count, entry in
            if case .reserved = entry { return count + 1 }
            return count
        }
    }

    func hasReservation(_ id: UUID) -> Bool {
        if case .reserved? = entries[id] { return true }
        return false
    }
    var reservedBytes: Int64 {
        entries.values.reduce(0) { total, entry in
            if case let .reserved(bytes) = entry { return total + bytes }
            return total
        }
    }

    mutating func reserve(_ id: UUID, bytes: Int64, maximumJobs: Int) -> Bool {
        guard entries[id] == nil, occupiedCount < maximumJobs else { return false }
        entries[id] = .reserved(bytes)
        return true
    }

    mutating func cancelReservation(_ id: UUID) {
        guard let entry = entries[id] else { return }
        if case .reserved = entry { entries[id] = nil }
        else if case .active = entry { entries[id] = .retained }
    }

    @discardableResult
    mutating func synchronize(pendingIDs: Set<UUID>, issueIDs: Set<UUID>, revision: UInt64 = 0) -> Bool {
        guard revision >= recoveryRevision else { return false }
        recoveryRevision = revision
        let durableIDs = pendingIDs.union(issueIDs)
        entries = entries.filter { id, entry in
            // An inventory can cross actors after a newer native checkpoint was admitted.
            // Only explicit completion/deletion releases active work.
            switch entry {
            case .reserved, .active: return true
            case .retained, .recoveryIssue: break
            }
            return durableIDs.contains(id)
        }
        for id in pendingIDs {
            if entries[id] == nil { entries[id] = .retained }
            else if case .recoveryIssue? = entries[id] { entries[id] = .retained }
        }
        for id in issueIDs.subtracting(pendingIDs) {
            switch entries[id] {
            case .reserved?, .active?: break
            default: entries[id] = .recoveryIssue
            }
        }
        return true
    }

    @discardableResult
    mutating func activate(_ ids: Set<UUID>) -> Set<UUID> {
        // Admission can arrive after a deletion completed across actors. Only reservations
        // or the current recovery inventory may register a slot; activation never recreates one.
        let admitted = Set(ids.filter { entries[$0] != nil })
        for id in admitted { entries[id] = .active }
        return admitted
    }

    mutating func finish(_ id: UUID, retained: Bool, revision: UInt64 = 0) {
        // A terminal result is newer than any inventory read before that result. Raising
        // the watermark prevents an old snapshot from resurrecting or hiding this slot.
        recoveryRevision = max(recoveryRevision, revision)
        guard retained else { entries[id] = nil; return }
        guard let entry = entries[id] else { return }
        if case .recoveryIssue = entry { return }
        entries[id] = .retained
    }

    mutating func remove(_ ids: Set<UUID>) {
        for id in ids { entries[id] = nil }
    }
}

enum CaptureDeletionSelection {
    static func captureIDs(rowIDs: Set<UUID>, assetIDs: Set<String>, jobs: [CaptureJob],
        libraryCaptureIDs: Set<UUID>) -> Set<UUID> {
        rowIDs.union(libraryCaptureIDs).union(jobs.compactMap { job in
            if rowIDs.contains(job.id) || job.assetIdentifier.map({ assetIDs.contains($0) }) == true
                || job.deferredPhoto?.assetIdentifier.map({ assetIDs.contains($0) }) == true { return job.id }
            return nil
        })
    }
}
