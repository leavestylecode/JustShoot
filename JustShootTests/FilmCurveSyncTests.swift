import XCTest
@testable import JustShoot

@MainActor
final class FilmCurveSyncTests: XCTestCase {
    private var suites = [String]()

    private func defaults() throws -> UserDefaults {
        let name = "curve-sync-\(UUID())"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    override func tearDown() async throws {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    func testVisibleReorderingKeepsHiddenSlotsAndResetPreservesDefinitions() throws {
        let prefs = try defaults()
        let library = FilmCurveLibrary(defaults: prefs)
        var first = CustomFilmCurve(name: "First")
        first.createdAt = .distantPast
        first.applyTemplate(.crossProcess)
        let second = CustomFilmCurve(name: "Second")
        XCTAssertTrue(library.add(second))
        XCTAssertTrue(library.add(first))
        XCTAssertTrue(library.select(first.filmCurve))
        XCTAssertTrue(library.setCustomVisibility(id: second.id, isVisible: false))
        XCTAssertTrue(library.setBuiltIn(.matte, isVisible: false))
        let prior = library.entries.map(\.id)
        let hiddenIDs = [CurvePreset.matte.id, second.filmCurve.id]
        XCTAssertEqual(library.hiddenEntries.map(\.id), hiddenIDs)
        let reversed = Array(library.visibleEntries.map(\.id).reversed())
        XCTAssertFalse(library.setVisibleOrder(prior))
        XCTAssertTrue(library.setVisibleOrder(reversed))
        XCTAssertEqual(library.visibleCurves.map(\.id), reversed)
        XCTAssertEqual(library.hiddenEntries.map(\.id), hiddenIDs)
        for id in [second.filmCurve.id, CurvePreset.matte.id] {
            XCTAssertEqual(prior.firstIndex(of: id), library.entries.firstIndex { $0.id == id })
        }
        XCTAssertTrue(library.resetList())
        let reloaded = FilmCurveLibrary(defaults: prefs)
        XCTAssertTrue(reloaded.hiddenEntries.isEmpty)
        XCTAssertEqual(reloaded.visibleCurves.map(\.id), CurvePreset.allCases.map(\.id) + [first, second].map { $0.filmCurve.id })
        XCTAssertEqual(reloaded.customCurves.first?.redPoints, first.redPoints)
        XCTAssertEqual(reloaded.selectedCurveID, first.filmCurve.id)
    }

    func testTwoDevicesMergeLegacyCurvesOrderVisibilityAndOfflineDeletionAcrossRestart() async throws {
        let cloud = MemoryCurveCloud()
        let a = FilmCurveLibrary(defaults: try defaults(), cloud: cloud)
        let prefs = try defaults()
        var b = FilmCurveLibrary(defaults: prefs, cloud: cloud)
        let x = CustomFilmCurve(name: "X")
        let y = CustomFilmCurve(name: "Y")
        XCTAssertTrue(a.add(x))
        XCTAssertTrue(b.add(y))
        XCTAssertTrue(a.setOrder([x.filmCurve.id] + CurvePreset.allCases.map(\.id)))
        XCTAssertTrue(a.select(x.filmCurve))
        await a.refreshCloud()?.value
        await b.refreshCloud()?.value
        await a.refreshCloud()?.value
        XCTAssertEqual(a.entries, b.entries)
        XCTAssertEqual(a.entries.first?.id, x.filmCurve.id)
        XCTAssertEqual(a.customCurves.count, 2)
        XCTAssertEqual(b.selectedCurveID, CurvePreset.none.id)

        await cloud.setOnline(false)
        XCTAssertTrue(b.delete(id: x.id))
        XCTAssertTrue(b.setBuiltIn(.matte, isVisible: false))
        await b.refreshCloud()?.value
        var edited = x
        edited.name = "An old draft"
        XCTAssertTrue(a.update(edited))
        await a.refreshCloud()?.value
        await cloud.setOnline(true)
        await a.refreshCloud()?.value
        b = FilmCurveLibrary(defaults: prefs, cloud: cloud)
        await b.refreshCloud()?.value
        await a.refreshCloud()?.value
        XCTAssertEqual(a.entries, b.entries)
        XCTAssertEqual(a.customCurves.map(\.id), [y.id])
        XCTAssertFalse(a.isBuiltInVisible(.matte))
        XCTAssertEqual(a.selectedCurveID, CurvePreset.none.id)
        XCTAssertTrue(b.resetList())
        await b.refreshCloud()?.value
        await a.refreshCloud()?.value
        XCTAssertTrue(a.isBuiltInVisible(.matte))
    }

    func testChangeWhileUploadingRebasesVisibilityAndEditedChannels() async throws {
        let cloud = MemoryCurveCloud()
        let a = FilmCurveLibrary(defaults: try defaults(), cloud: cloud)
        let b = FilmCurveLibrary(defaults: try defaults(), cloud: cloud)
        let x = CustomFilmCurve(name: "Before")
        XCTAssertTrue(a.add(x))
        await a.refreshCloud()?.value
        await b.refreshCloud()?.value
        var edited = x
        edited.applyTemplate(.crossProcess)
        XCTAssertTrue(b.update(edited))
        await b.refreshCloud()?.value

        await cloud.pauseNextExchange()
        edited = x
        edited.name = "Renamed"
        XCTAssertTrue(a.update(edited))
        let upload = a.refreshCloud()
        await cloud.waitForPause()
        XCTAssertTrue(a.setCustomVisibility(id: x.id, isVisible: false))
        await cloud.resumeExchange()
        await upload?.value
        await b.refreshCloud()?.value
        XCTAssertEqual(a.entries, b.entries)
        let result = try XCTUnwrap(b.customCurves.first)
        XCTAssertEqual(result.name, "Renamed")
        XCTAssertFalse(result.isVisible)
        XCTAssertNotEqual(result.redPoints, x.redPoints)
    }

    func testSavingAnOpenDraftPreservesChannelsChangedElsewhere() throws {
        let library = FilmCurveLibrary(defaults: try defaults())
        let original = CustomFilmCurve(name: "Original")
        XCTAssertTrue(library.add(original))
        var remote = original
        remote.applyTemplate(.crossProcess)
        XCTAssertTrue(library.update(remote))
        var draft = original
        draft.name = "Renamed here"
        XCTAssertTrue(library.update(draft, editedFrom: original))
        let saved = try XCTUnwrap(library.customCurves.first)
        XCTAssertEqual(saved.name, draft.name)
        XCTAssertEqual(saved.redPoints, remote.redPoints)
        XCTAssertEqual(saved.bluePoints, remote.bluePoints)
    }

    func testAccountSwitchKeepsPrivateAndSignedOutLibrariesSeparate() async throws {
        let cloud = MemoryCurveCloud()
        let library = FilmCurveLibrary(defaults: try defaults(), cloud: cloud)
        let a = CustomFilmCurve(name: "A")
        let b = CustomFilmCurve(name: "B")
        XCTAssertTrue(library.add(a))
        await library.refreshCloud()?.value
        await cloud.setAccount("B")
        library.cloudAccountChanged()
        await library.refreshCloud()?.value
        XCTAssertTrue(library.customCurves.isEmpty)
        XCTAssertTrue(library.add(b))
        await library.refreshCloud()?.value
        await cloud.setAccount(nil)
        library.cloudAccountChanged()
        await library.refreshCloud()?.value
        XCTAssertTrue(library.customCurves.isEmpty)
        let offline = CustomFilmCurve(name: "Signed out")
        XCTAssertTrue(library.add(offline))
        await library.refreshCloud()?.value
        await cloud.setAccount("A")
        library.cloudAccountChanged()
        await library.refreshCloud()?.value
        XCTAssertEqual(Set(library.customCurves.map(\.id)), [a.id, offline.id])
        await cloud.setAccount("B")
        library.cloudAccountChanged()
        await library.refreshCloud()?.value
        XCTAssertEqual(library.customCurves.map(\.id), [b.id])
    }
}

private actor MemoryCurveCloud: FilmCurveCloudStorage {
    private var account: String? = "A"
    private var online = true
    private var catalogs: [String: FilmCurveCatalog] = [:]
    private var shouldPause = false
    private var exchange: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func setAccount(_ id: String?) { account = id }
    func setOnline(_ online: Bool) { self.online = online }
    func accountID() async throws -> String? {
        guard online else { throw URLError(.notConnectedToInternet) }
        return account
    }
    func pauseNextExchange() { shouldPause = true }
    func waitForPause() async {
        if exchange == nil { await withCheckedContinuation { observer = $0 } }
    }
    func resumeExchange() {
        exchange?.resume()
        exchange = nil
    }

    func synchronize(accountID: String, base: FilmCurveCatalog, local: FilmCurveCatalog) async throws -> FilmCurveCatalog {
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation {
                exchange = $0
                observer?.resume()
                observer = nil
            }
        }
        let merged = (catalogs[accountID] ?? FilmCurveCatalog()).merging(local: local, since: base)
        catalogs[accountID] = merged
        return merged
    }
}
