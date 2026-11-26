import CloudKit
import Foundation

/// The camera selection belongs to the device. Everything in this catalog travels together.
struct FilmCurveCatalog: Codable, Equatable, Sendable {
    var customCurves: [CustomFilmCurve] = []
    var hiddenBuiltInIDs: Set<String> = []
    var order = CurvePreset.allCases.map(\.id)

    /// Replay the differences since the last successful exchange onto the latest server catalog.
    /// A deletion on either device wins over a stale edit to that curve.
    func merging(local: Self, since base: Self) -> Self {
        let original = Dictionary(base.customCurves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let edits = Dictionary(local.customCurves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = Dictionary(customCurves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in original.keys where edits[id] == nil { merged.removeValue(forKey: id) }
        for (id, edit) in edits {
            guard let previous = original[id] else {
                if let remote = merged[id], remote.updatedAt >= edit.updatedAt { continue }
                merged[id] = edit
                continue
            }
            guard edit != previous, let remote = merged[id] else { continue }
            merged[id] = remote.merging(edit: edit, since: previous)
        }

        let common = Set(base.order).intersection(local.order)
        let reordered = base.order.filter(common.contains) != local.order.filter(common.contains)
        let primary = reordered ? local.order : order
        let secondary = reordered ? order : local.order
        let anchors = Set(primary)
        var insertions: [String: [String]] = [:]
        var pending: [String] = []
        for id in secondary {
            if anchors.contains(id) {
                if !pending.isEmpty { insertions[id] = pending; pending = [] }
            } else {
                pending.append(id)
            }
        }
        let prioritized = primary.flatMap { (insertions[$0] ?? []) + [$0] } + pending
        let builtIns = CurvePreset.allCases.map(\.id)
        let customIDs = merged.keys.map { FilmCurveLibrary.customID($0) }.sorted()
        var remaining = Set(builtIns + customIDs)
        let ordered = (prioritized + builtIns + customIDs).filter { remaining.remove($0) != nil }
        let hidden = hiddenBuiltInIDs.union(local.hiddenBuiltInIDs.subtracting(base.hiddenBuiltInIDs))
            .subtracting(base.hiddenBuiltInIDs.subtracting(local.hiddenBuiltInIDs))
            .intersection(builtIns).subtracting([CurvePreset.none.id])
        return Self(customCurves: ordered.compactMap { FilmCurveLibrary.customUUID($0).flatMap { merged[$0] } },
                    hiddenBuiltInIDs: hidden, order: ordered)
    }
}

protocol FilmCurveCloudStorage: Sendable {
    func accountID() async throws -> String?
    func synchronize(accountID: String, base: FilmCurveCatalog, local: FilmCurveCatalog) async throws -> FilmCurveCatalog
}

extension CKContainer {
    func authenticatedRecordName() async throws -> String? {
        do {
            return try await userRecordID().recordName
        } catch let error as CKError where error.code == .notAuthenticated {
            if try await accountStatus() == .noAccount { return nil }
            throw error
        }
    }
}

actor CloudKitFilmCurveStorage: FilmCurveCloudStorage {
    private lazy var container = CKContainer.default()
    private var cached: (id: CKRecord.ID, tag: String, catalog: FilmCurveCatalog)?

    private let recordPrefix: String

    init(recordPrefix: String = "film-curves") {
        self.recordPrefix = recordPrefix
    }

    func accountID() async throws -> String? {
        try await container.authenticatedRecordName()
    }

    func synchronize(accountID: String, base: FilmCurveCatalog, local: FilmCurveCatalog) async throws -> FilmCurveCatalog {
        let database = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: "\(recordPrefix)-\(accountID)")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let record: CKRecord
            let remote: FilmCurveCatalog
            do {
                // Poll only metadata when the account's last known revision is already cached.
                if local == base, let cached, cached.id == id,
                   let header = try await database.records(for: [id], desiredKeys: [])[id]?.get(),
                   header.recordChangeTag == cached.tag {
                    return cached.catalog
                }
                let fetched = try await database.record(for: id)
                guard let asset = fetched["catalogV1"] as? CKAsset, let url = asset.fileURL else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                remote = try PropertyListDecoder().decode(FilmCurveCatalog.self, from: Data(contentsOf: url))
                record = fetched
                if let tag = record.recordChangeTag { cached = (id, tag, remote) }
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "FilmCurveLibrary", recordID: id)
                remote = FilmCurveCatalog()
                cached = nil
            }

            let merged = remote.merging(local: local, since: base)
            guard merged != remote else { return merged }
            guard try await self.accountID() == accountID else { throw CancellationError() }
            try Task.checkCancellation()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try PropertyListEncoder().encode(merged).write(to: url, options: .atomic)
            record["catalogV1"] = CKAsset(fileURL: url)
            do {
                let saved = try await database.save(record)
                if let tag = saved.recordChangeTag { cached = (id, tag, merged) }
                return merged
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                cached = nil
            }
        }
        throw CKError(.serverRecordChanged)
    }
}
