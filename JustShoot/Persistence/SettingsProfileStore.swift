import CloudKit
import Foundation
import Observation
import OSLog

struct SettingsProfile: Codable, Equatable {
    var nickname = ""
    var motto = ""
    var avatar = Data()
}

private struct SettingsProfileEdits: Codable, Equatable {
    var nickname: String?
    var motto: String?
    var avatar: Data?

    init() {}

    init(from original: SettingsProfile, to draft: SettingsProfile) {
        if draft.nickname != original.nickname { nickname = draft.nickname }
        if draft.motto != original.motto { motto = draft.motto }
        if draft.avatar != original.avatar { avatar = draft.avatar }
    }

    func applying(to profile: SettingsProfile) -> SettingsProfile {
        SettingsProfile(nickname: nickname ?? profile.nickname, motto: motto ?? profile.motto,
                        avatar: avatar ?? profile.avatar)
    }

    mutating func merge(_ newer: Self) {
        nickname = newer.nickname ?? nickname
        motto = newer.motto ?? motto
        avatar = newer.avatar ?? avatar
    }

    func remaining(afterSyncing synced: Self) -> Self {
        var remaining = self
        if nickname == synced.nickname { remaining.nickname = nil }
        if motto == synced.motto { remaining.motto = nil }
        if avatar == synced.avatar { remaining.avatar = nil }
        return remaining
    }
}

@MainActor
protocol SettingsProfileCloudStorage {
    func accountID() async throws -> String?
    func synchronize(accountID: String, merge: (SettingsProfile?) -> SettingsProfile) async throws -> SettingsProfile
}

@MainActor
@Observable
final class SettingsProfileStore {
    static let shared = SettingsProfileStore(defaults: .standard, cloud: CloudKitSettingsProfileStorage())

    private struct Replica: Codable, Equatable {
        var profile = SettingsProfile()
        var edits = SettingsProfileEdits()
        var hasSynchronized = false

        mutating func apply(_ newer: SettingsProfileEdits) {
            profile = newer.applying(to: profile)
            edits.merge(newer)
        }
    }

    private struct Cache: Codable, Equatable {
        var accountID: String?
        var device = Replica()
        var accounts: [String: Replica] = [:]

        var active: Replica {
            get { accountID.flatMap { accounts[$0] } ?? device }
            set {
                if let accountID { accounts[accountID] = newValue }
                else { device = newValue }
            }
        }

        mutating func selectAccount(_ id: String?) {
            guard accountID != id else { return }
            if let id {
                if accounts[id] == nil { accounts[id] = device }
                else { accounts[id]?.apply(device.edits) }
                device = Replica()
            }
            accountID = id
        }
    }

    private static let cacheKey = "settings.profile.cache.v1"
    private let defaults: UserDefaults
    private let cloud: any SettingsProfileCloudStorage
    @ObservationIgnored private var cache: Cache
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var signedOut = false

    private(set) var profile: SettingsProfile
    private(set) var accountID: String?

    init(defaults: UserDefaults, cloud: any SettingsProfileCloudStorage) {
        self.defaults = defaults
        self.cloud = cloud
        if let data = defaults.data(forKey: Self.cacheKey) {
            cache = (try? PropertyListDecoder().decode(Cache.self, from: data)) ?? Cache()
        } else {
            cache = Cache(device: Replica(profile: SettingsProfile(
                nickname: defaults.string(forKey: "settings.profile.nickname") ?? "",
                motto: defaults.string(forKey: "settings.profile.bio") ?? "",
                avatar: defaults.data(forKey: "settings.profile.avatar") ?? Data()
            )))
        }
        profile = cache.active.profile
        accountID = cache.accountID
    }

    func save(_ draft: SettingsProfile, editedFrom original: SettingsProfile, accountID openedAccount: String?) {
        guard openedAccount == nil || openedAccount == accountID else { return }
        let edits = SettingsProfileEdits(from: original, to: draft)
        guard edits != SettingsProfileEdits() else { return }
        var updated = cache
        updated.active.apply(edits)
        persist(updated)
        refresh()
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let syncTask { return syncTask }
        let task = Task(priority: .utility) { [weak self] () -> Void in
            await self?.synchronize()
        }
        syncTask = task
        return task
    }

    func accountDidChange() {
        syncTask?.cancel()
        syncTask = nil
        refresh()
    }

    func retryPendingChanges() {
        guard !signedOut else { return }
        let local = cache.active
        if local.edits != SettingsProfileEdits() || (!local.hasSynchronized && local.profile != SettingsProfile()) {
            refresh()
        }
    }

    private func synchronize() async {
        defer { if !Task.isCancelled { syncTask = nil } }
        do {
            try Task.checkCancellation()
            let id = try await cloud.accountID()
            try Task.checkCancellation()
            signedOut = id == nil
            var updated = cache
            updated.selectAccount(id)
            persist(updated)
            guard let id else { return }

            repeat {
                let snapshot = cache.active
                let synced = try await cloud.synchronize(accountID: id) { remote in
                    // Import a legacy local profile only if this account doesn't already have one.
                    let base = remote ?? (snapshot.hasSynchronized ? SettingsProfile() : snapshot.profile)
                    return snapshot.edits.applying(to: base)
                }
                try Task.checkCancellation()

                // Compare pending edits so explicitly restoring a value still counts as an edit.
                let edits = cache.active.edits.remaining(afterSyncing: snapshot.edits)
                updated = cache
                updated.active = Replica(profile: edits.applying(to: synced), edits: edits, hasSynchronized: true)
                persist(updated)
            } while cache.active.edits != SettingsProfileEdits()
        } catch is CancellationError {
        } catch {
            let error = error as NSError
            Log.ui.debug("profile_sync_deferred domain=\(error.domain, privacy: .public) code=\(error.code)")
        }
    }

    private func persist(_ updated: Cache) {
        guard updated != cache else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(updated) else { return }
        defaults.set(data, forKey: Self.cacheKey)
        cache = updated
        if profile != updated.active.profile { profile = updated.active.profile }
        if accountID != updated.accountID { accountID = updated.accountID }
    }
}

@MainActor
private final class CloudKitSettingsProfileStorage: SettingsProfileCloudStorage {
    private lazy var container = CKContainer.default()

    func accountID() async throws -> String? {
        try await container.authenticatedRecordName()
    }

    func synchronize(accountID: String, merge: (SettingsProfile?) -> SettingsProfile) async throws -> SettingsProfile {
        let database = container.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: "settings-profile-\(accountID)")
        let payloadKey = "profileData"

        for attempt in 0..<3 {
            try Task.checkCancellation()
            let record: CKRecord
            let remote: SettingsProfile?
            do {
                let fetched = try await database.record(for: recordID)
                guard let data = fetched.encryptedValues[payloadKey] as? Data else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                remote = try PropertyListDecoder().decode(SettingsProfile.self, from: data)
                record = fetched
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "SettingsProfile", recordID: recordID)
                remote = nil
            }

            let profile = merge(remote)
            guard profile != (remote ?? SettingsProfile()) else { return profile }
            guard try await self.accountID() == accountID else { throw CancellationError() }
            try Task.checkCancellation()
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            record.encryptedValues[payloadKey] = try encoder.encode(profile) as NSData
            do {
                // Saving the fetched record uses its change tag. Refetch and merge on conflict.
                _ = try await database.save(record)
                return profile
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                continue
            }
        }
        throw CKError(.serverRecordChanged)
    }
}
