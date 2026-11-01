import XCTest
@testable import JustShoot

@MainActor
final class FilmPageSettingsTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let name = "film-page-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }

    private func custom(_ id: UUID = UUID(), name: String = "Custom") -> FilmSource {
        .custom(id: id, displayName: name, iso: 200, fileName: "\(id).jslut")
    }

    func testFreshSettingsShowAllFilmsAndBothTextLines() throws {
        try withDefaults { defaults in
            let settings = FilmPageSettings(defaults: defaults)
            let sources = FilmPreset.allCases.map(FilmSource.preset) + [custom()]
            XCTAssertEqual(settings.textVisibility, FilmTileTextVisibility())
            XCTAssertEqual(settings.preferences.ordered(sources), sources)
            XCTAssertTrue(sources.allSatisfy(settings.preferences.isVisible))
        }
    }

    func testPreferencesAndMixedFilmOrderSurviveRelaunch() throws {
        try withDefaults { defaults in
            let settings = FilmPageSettings(defaults: defaults)
            let sources: [FilmSource] = [.preset(.fujiRawVelvia), .preset(.fujiRawASTIA), custom()]
            settings.preferences.showsTitle = false
            settings.preferences.showsSubtitle = false
            settings.setVisible(.fujiRawASTIA, false)
            settings.move(from: [2], to: 0, in: sources)

            let restored = FilmPageSettings(defaults: defaults)
            XCTAssertEqual(restored.preferences, settings.preferences)
            XCTAssertEqual(restored.textVisibility, FilmTileTextVisibility(showsTitle: false, showsSubtitle: false))
            XCTAssertEqual(restored.preferences.ordered(sources).map(\.id), [sources[2].id, sources[0].id, sources[1].id])
            XCTAssertEqual(restored.preferences.ordered(sources).filter(restored.preferences.isVisible), [sources[2], sources[0]])
        }
    }

    func testHidingAndRestoringOfficialFilmsPreservesOrderAndIndividualChoices() throws {
        try withDefaults { defaults in
            let settings = FilmPageSettings(defaults: defaults)
            let sources: [FilmSource] = [.preset(.fujiRawVelvia), custom(), .preset(.fujiRawASTIA)]
            settings.move(from: [2], to: 0, in: sources)
            settings.setVisible(.fujiRawVelvia, false)
            XCTAssertEqual(settings.preferences.ordered(sources).filter(settings.preferences.isVisible), [sources[2], sources[1]])
            settings.setVisible(.fujiRawASTIA, false)
            XCTAssertEqual(settings.preferences.ordered(sources).filter(settings.preferences.isVisible), [sources[1]])
            settings.setVisible(.fujiRawASTIA, true)
            XCTAssertEqual(settings.preferences.ordered(sources).filter(settings.preferences.isVisible), [sources[2], sources[1]])
            settings.setVisible(.fujiRawVelvia, true)
            XCTAssertEqual(settings.preferences.ordered(sources), [sources[2], sources[0], sources[1]])
        }
    }

    func testStaleAndDuplicateIDsDoNotLoseNewFilmsOrTheirIdentity() {
        let existing = custom(), added = custom()
        var preferences = FilmPagePreferences()
        preferences.orderedFilmIDs = [existing.id, "removed-film", existing.id, FilmPreset.fujiRawASTIA.id]
        let sources: [FilmSource] = [.preset(.fujiRawVelvia), .preset(.fujiRawASTIA), existing, added]
        XCTAssertEqual(preferences.ordered(sources), [existing, sources[1], sources[0], added])
        let renamed = custom(UUID(uuidString: existing.id)!, name: "Renamed")
        XCTAssertEqual(preferences.ordered([sources[0], renamed]).first?.displayName, "Renamed")
    }

    func testMovingMultipleFilmsDownAndDeletingCustomFilmPreservesRemainingOrder() throws {
        try withDefaults { defaults in
            let settings = FilmPageSettings(defaults: defaults)
            let id = UUID()
            let sources: [FilmSource] = [.preset(.fujiRawVelvia), custom(id), .preset(.fujiRawASTIA), custom()]
            settings.move(from: [0, 1], to: 4, in: sources)
            XCTAssertEqual(settings.preferences.ordered(sources), [sources[2], sources[3], sources[0], sources[1]])
            settings.removeCustomFilm(id: id)
            let remaining = sources.filter { $0.id != id.uuidString }
            let restored = FilmPageSettings(defaults: defaults)
            XCTAssertEqual(restored.preferences.ordered(remaining), [sources[2], sources[3], sources[0]])
            XCTAssertFalse(restored.preferences.orderedFilmIDs.contains(id.uuidString))
        }
    }

    func testOlderPayloadUsesDefaultsForNewFieldsAndInvalidDataDoesNotCrash() throws {
        let oldData = Data(#"{"showsTitle":false,"orderedFilmIDs":["fujiRawASTIA"]}"#.utf8)
        let preferences = try JSONDecoder().decode(FilmPagePreferences.self, from: oldData)
        XCTAssertFalse(preferences.showsTitle)
        XCTAssertTrue(preferences.showsSubtitle)
        XCTAssertEqual(preferences.orderedFilmIDs, ["fujiRawASTIA"])
        try withDefaults { defaults in
            defaults.set(Data("invalid".utf8), forKey: FilmPageSettings.storageKey)
            XCTAssertEqual(FilmPageSettings(defaults: defaults).preferences, FilmPagePreferences())
        }
    }

    func testResetOrderPersistsDefaultOrderAndKeepsAppearanceAndHiddenFilms() throws {
        try withDefaults { defaults in
            let settings = FilmPageSettings(defaults: defaults)
            let sources: [FilmSource] = [.preset(.fujiRawVelvia), .preset(.fujiRawASTIA), custom(), custom()]
            settings.preferences.showsTitle = false
            settings.preferences.showsSubtitle = false
            settings.setVisible(.fujiRawASTIA, false)
            settings.move(from: [2, 3], to: 0, in: sources)
            XCTAssertNotEqual(settings.preferences.ordered(sources), sources)

            settings.resetOrder()

            let restored = FilmPageSettings(defaults: defaults)
            XCTAssertEqual(restored.preferences.ordered(sources), sources)
            XCTAssertEqual(restored.textVisibility, FilmTileTextVisibility(showsTitle: false, showsSubtitle: false))
            XCTAssertEqual(restored.preferences.ordered(sources).filter(restored.preferences.isVisible),
                [sources[0], sources[2], sources[3]])
        }
    }

    func testRemovedOfficialFilmsSwitchDoesNotOverrideIndividualVisibility() throws {
        try withDefaults { defaults in
            let oldData = Data(#"{"showsOfficialFilms":false,"hiddenPresetIDs":["fujiRawASTIA"],"orderedFilmIDs":["fujiRawASTIA","fujiRawVelvia"]}"#.utf8)
            defaults.set(oldData, forKey: FilmPageSettings.storageKey)
            let settings = FilmPageSettings(defaults: defaults)
            let sources: [FilmSource] = [.preset(.fujiRawVelvia), .preset(.fujiRawASTIA)]
            XCTAssertEqual(settings.preferences.ordered(sources), [sources[1], sources[0]])
            XCTAssertEqual(settings.preferences.ordered(sources).filter(settings.preferences.isVisible), [sources[0]])
        }
    }
}
