import XCTest
@testable import JustShoot

@MainActor
final class SettingsProfileStoreTests: XCTestCase {
    func testExistingLocalProfileUploadsWhenTheAccountHasNoProfile() async throws {
        let defaults = try makeDefaults()
        let legacy = SettingsProfile(nickname: "Local", motto: "Keep shooting", avatar: Data([1, 2]))
        defaults.set(legacy.nickname, forKey: "settings.profile.nickname")
        defaults.set(legacy.motto, forKey: "settings.profile.bio")
        defaults.set(legacy.avatar, forKey: "settings.profile.avatar")
        let cloud = Cloud()
        let store = SettingsProfileStore(defaults: defaults, cloud: cloud)

        XCTAssertEqual(store.profile, legacy)
        await store.refresh().value

        XCTAssertEqual(cloud.profiles["account-a"], legacy)
        XCTAssertEqual(SettingsProfileStore(defaults: defaults, cloud: cloud).profile, legacy)
    }

    func testCloudProfileWinsOverLegacyDataAndRefreshesTheLocalCache() async throws {
        let defaults = try makeDefaults()
        defaults.set("Legacy nickname", forKey: "settings.profile.nickname")
        let cloud = Cloud()
        let remote = SettingsProfile(nickname: "Synced", motto: "Hello", avatar: Data([3]))
        cloud.profiles["account-a"] = remote
        let store = SettingsProfileStore(defaults: defaults, cloud: cloud)

        await store.refresh().value
        XCTAssertEqual(store.profile, remote)

        cloud.profiles["account-a"] = SettingsProfile()
        await store.refresh().value
        XCTAssertEqual(store.profile, SettingsProfile())
        XCTAssertEqual(SettingsProfileStore(defaults: defaults, cloud: cloud).profile, SettingsProfile())
    }

    func testOfflineClearsSurviveRelaunchAndMergeWithNewRemoteFields() async throws {
        let defaults = try makeDefaults()
        let cloud = Cloud()
        let initial = SettingsProfile(nickname: "Original", motto: "Original motto", avatar: Data([1]))
        cloud.profiles["account-a"] = initial
        let store = SettingsProfileStore(defaults: defaults, cloud: cloud)
        await store.refresh().value

        cloud.offline = true
        let draft = SettingsProfile(nickname: initial.nickname)
        store.save(draft, editedFrom: initial, accountID: store.accountID)
        await store.refresh().value
        XCTAssertEqual(store.profile, draft)
        XCTAssertEqual(cloud.profiles["account-a"], initial)

        let reopened = SettingsProfileStore(defaults: defaults, cloud: cloud)
        XCTAssertEqual(reopened.profile, draft)
        cloud.offline = false
        cloud.profiles["account-a"]?.nickname = "Renamed remotely"
        await reopened.refresh().value

        let merged = SettingsProfile(nickname: "Renamed remotely")
        XCTAssertEqual(reopened.profile, merged)
        XCTAssertEqual(cloud.profiles["account-a"], merged)
    }

    func testProfileEditorKeepsRemoteFieldsThatTheDraftDidNotEdit() async throws {
        let cloud = Cloud()
        cloud.profiles["account-a"] = SettingsProfile(nickname: "Original")
        let store = SettingsProfileStore(defaults: try makeDefaults(), cloud: cloud)
        await store.refresh().value
        let original = store.profile

        cloud.profiles["account-a"]?.avatar = Data([4])
        await store.refresh().value
        store.save(SettingsProfile(nickname: "Edited"), editedFrom: original, accountID: store.accountID)
        await store.refresh().value

        XCTAssertEqual(cloud.profiles["account-a"], SettingsProfile(nickname: "Edited", avatar: Data([4])))
    }

    func testEditsMadeDuringARequestAreSyncedAfterItCompletes() async throws {
        let cloud = Cloud()
        let store = SettingsProfileStore(defaults: try makeDefaults(), cloud: cloud)
        await store.refresh().value
        let draft = SettingsProfile(nickname: "First edit")
        cloud.afterNextMerge = {
            let secondDraft = SettingsProfile(nickname: draft.nickname, motto: "Second edit")
            store.save(secondDraft, editedFrom: draft, accountID: store.accountID)
        }

        store.save(draft, editedFrom: store.profile, accountID: store.accountID)
        await store.refresh().value

        let merged = SettingsProfile(nickname: "First edit", motto: "Second edit")
        XCTAssertEqual(store.profile, merged)
        XCTAssertEqual(cloud.profiles["account-a"], merged)
    }

    func testRestoringALocalValueDuringARefreshStillOverridesTheRemoteEdit() async throws {
        let cloud = Cloud()
        let original = SettingsProfile(nickname: "Original")
        cloud.profiles["account-a"] = original
        let store = SettingsProfileStore(defaults: try makeDefaults(), cloud: cloud)
        await store.refresh().value

        cloud.profiles["account-a"]?.nickname = "Edited remotely"
        cloud.afterNextMerge = {
            let draft = SettingsProfile(nickname: "Temporary edit")
            store.save(draft, editedFrom: original, accountID: store.accountID)
            store.save(original, editedFrom: draft, accountID: store.accountID)
        }
        await store.refresh().value

        XCTAssertEqual(store.profile, original)
        XCTAssertEqual(cloud.profiles["account-a"], original)
    }

    func testSwitchingAccountsKeepsPendingEditsWithTheirOriginalAccount() async throws {
        let cloud = Cloud()
        cloud.profiles["account-a"] = SettingsProfile(nickname: "First account")
        cloud.profiles["account-b"] = SettingsProfile(nickname: "Second account")
        let store = SettingsProfileStore(defaults: try makeDefaults(), cloud: cloud)
        await store.refresh().value
        let original = store.profile
        let firstAccount = store.accountID

        cloud.offline = true
        store.save(SettingsProfile(nickname: "Pending edit"), editedFrom: original, accountID: firstAccount)
        await store.refresh().value

        cloud.offline = false
        cloud.currentAccountID = "account-b"
        store.accountDidChange()
        await store.refresh().value
        store.save(SettingsProfile(nickname: "Stale editor"), editedFrom: original, accountID: firstAccount)
        XCTAssertEqual(store.profile.nickname, "Second account")
        XCTAssertEqual(cloud.profiles["account-b"]?.nickname, "Second account")

        cloud.currentAccountID = nil
        await store.refresh().value
        XCTAssertEqual(store.profile, SettingsProfile())

        cloud.currentAccountID = firstAccount
        await store.refresh().value
        XCTAssertEqual(store.profile.nickname, "Pending edit")
        XCTAssertEqual(cloud.profiles["account-a"]?.nickname, "Pending edit")
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "SettingsProfileStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private final class Cloud: SettingsProfileCloudStorage {
        var currentAccountID: String? = "account-a"
        var profiles: [String: SettingsProfile] = [:]
        var offline = false
        var afterNextMerge: (() -> Void)?

        func accountID() async throws -> String? {
            currentAccountID
        }

        func synchronize(accountID: String, merge: (SettingsProfile?) -> SettingsProfile) async throws -> SettingsProfile {
            if offline { throw URLError(.notConnectedToInternet) }
            let profile = merge(profiles[accountID])
            if profile != (profiles[accountID] ?? SettingsProfile()) { profiles[accountID] = profile }
            let afterMerge = afterNextMerge
            afterNextMerge = nil
            afterMerge?()
            return profile
        }
    }
}
