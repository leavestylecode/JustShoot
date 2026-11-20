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

    private func settingsShowingAllPresets(_ defaults: UserDefaults) -> FilmPageSettings {
        let settings = FilmPageSettings(defaults: defaults)
        settings.preferences.addedPresetIDs = Set(FilmPagePreferences.catalogPresets.map(\.id))
        return settings
    }

    func testFreshSettingsShowNineRecommendedFilmsAndBothTextLines() throws {
        try withDefaults { defaults in
            let settings = FilmPageSettings(defaults: defaults)
            let sources = FilmPreset.allCases.map(FilmSource.preset) + [custom()]
            XCTAssertEqual(settings.textVisibility, FilmTileTextVisibility())
            let visible = settings.preferences.ordered(sources).filter(settings.preferences.isVisible)
            XCTAssertEqual(visible, FilmPagePreferences.defaultPresets.map(FilmSource.preset) + [sources.last!])
            XCTAssertEqual(FilmPagePreferences.defaultPresets.count, 9)
            XCTAssertEqual(Set(FilmPagePreferences.defaultPresets).count, 9)
        }
    }

    func testPreferencesAndMixedFilmOrderSurviveRelaunch() throws {
        try withDefaults { defaults in
            let settings = settingsShowingAllPresets(defaults)
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
            let settings = settingsShowingAllPresets(defaults)
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
            let settings = settingsShowingAllPresets(defaults)
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
        XCTAssertEqual(preferences.orderedFilmIDs.first, "fujiRawASTIA")
        XCTAssertEqual(preferences.addedPresetIDs.count, 9)
        try withDefaults { defaults in
            defaults.set(Data("invalid".utf8), forKey: FilmPageSettings.storageKey)
            XCTAssertEqual(FilmPageSettings(defaults: defaults).preferences, FilmPagePreferences())
        }
    }

    func testResetOrderPersistsDefaultOrderAndKeepsAppearanceAndHiddenFilms() throws {
        try withDefaults { defaults in
            let settings = settingsShowingAllPresets(defaults)
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

    func testAddingAFilmIsImmediateIdempotentAndSurvivesRelaunch() throws {
        try withDefaults { defaults in
            let settings = FilmPageSettings(defaults: defaults)
            let source = FilmSource.preset(.kodakPortra800)
            XCTAssertFalse(settings.preferences.isVisible(source))
            settings.setVisible(.kodakPortra800, true)
            settings.setVisible(.kodakPortra800, true)
            XCTAssertTrue(settings.preferences.isVisible(source))
            XCTAssertEqual(settings.preferences.addedPresetIDs.count, 10)
            XCTAssertEqual(FilmPageSettings(defaults: defaults).preferences, settings.preferences)
            settings.setVisible(.kodakPortra800, false)
            XCTAssertFalse(FilmPageSettings(defaults: defaults).preferences.isVisible(source))
        }
    }

    func testEmptySelectionStaysEmptyAfterRelaunch() throws {
        try withDefaults { defaults in
            let settings = FilmPageSettings(defaults: defaults)
            settings.preferences.addedPresetIDs = []
            XCTAssertTrue(FilmPageSettings(defaults: defaults).preferences.addedPresetIDs.isEmpty)
        }
    }

    func testSlideSelectionMigratesToOneLookPerFamilyAndKeepsMixedOrder() throws {
        try withDefaults { defaults in
            let imported = custom()
            let payload = try JSONSerialization.data(withJSONObject: [
                "addedPresetIDs": ["fujiVelvia50", "fujiProvia100F", "fujiSlideProvia100F"],
                "orderedFilmIDs": ["fujiSlideProvia100F", imported.id, "fujiVelvia50", "fujiProvia100F"]
            ])
            defaults.set(payload, forKey: FilmPageSettings.storageKey)
            let settings = FilmPageSettings(defaults: defaults)
            let sources = FilmPreset.allCases.map(FilmSource.preset) + [imported]
            let expected: [FilmSource] = [.preset(.fujiProvia100F), imported, .preset(.fujiRawVelvia)]
            XCTAssertEqual(settings.preferences.orderedFilmIDs, expected.map(\.id))
            XCTAssertEqual(settings.preferences.addedPresetIDs, ["fujiRawVelvia", "fujiProvia100F"])
            XCTAssertEqual(settings.preferences.ordered(sources).filter(settings.preferences.isVisible), expected)
            XCTAssertEqual(settings.preferences.cameraSources(sources, current: .preset(.fujiVelvia50)), expected)
            XCTAssertEqual(FilmPageSettings(defaults: defaults).preferences, settings.preferences)
        }
    }

    func testOrderedButUnaddedVariantsStayUnaddedAfterMigration() throws {
        let payload = Data(#"{"addedPresetIDs":[],"orderedFilmIDs":["fujiVelvia50","fujiSlideProvia100F"]}"#.utf8)
        let preferences = try JSONDecoder().decode(FilmPagePreferences.self, from: payload)
        XCTAssertTrue(preferences.addedPresets.isEmpty)
        XCTAssertEqual(preferences.orderedFilmIDs, ["fujiRawVelvia", "fujiProvia100F"])
    }

    func testHiddenVariantsDoNotMoveTheVisibleFilmAheadOfAnImport() throws {
        let imported = custom()
        let payload = try JSONSerialization.data(withJSONObject: [
            "addedPresetIDs": ["fujiRawVelvia", "fujiSlideProvia100F"],
            "orderedFilmIDs": ["fujiVelvia50", "fujiProvia100F", imported.id, "fujiSlideProvia100F", "fujiRawVelvia"]
        ])
        let preferences = try JSONDecoder().decode(FilmPagePreferences.self, from: payload)
        XCTAssertEqual(preferences.orderedFilmIDs, [imported.id, "fujiProvia100F", "fujiRawVelvia"])
    }

    func testLegacySelectionAndOrderAreMigratedWithoutReseedingNineFilms() throws {
        try withDefaults { defaults in
            let payload = Data(#"{"hiddenPresetIDs":["fujiC200"],"orderedFilmIDs":["kodakPortra400","fujiRawASTIA"]}"#.utf8)
            defaults.set(payload, forKey: FilmPageSettings.storageKey)
            let settings = FilmPageSettings(defaults: defaults)
            XCTAssertEqual(settings.preferences.addedPresetIDs.count, 8)
            XCTAssertFalse(settings.preferences.isVisible(.preset(.fujiC200)))
            XCTAssertFalse(settings.preferences.isVisible(.preset(.kodakPortra800)))
            let ordered = settings.preferences.ordered(FilmPreset.allCases.map(FilmSource.preset))
            XCTAssertEqual(Array(ordered.prefix(2)), [.preset(.kodakPortra400), .preset(.fujiRawASTIA)])
            let data = try XCTUnwrap(defaults.data(forKey: FilmPageSettings.storageKey))
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(stored["addedPresetIDs"])
            XCTAssertNil(stored["hiddenPresetIDs"])
        }
    }

    func testLegacyEmptySelectionStaysEmptyAndPreservesImportedFilmOrder() throws {
        try withDefaults { defaults in
            let imported = custom()
            let legacyIDs = ["fujiRawVelvia", "fujiRawASTIA", "fujiRawClassicChrome", "fujiRawClassicNeg",
                "fujiRawACROS", "fujiC200", "fujiPro400H", "fujiProvia100F", "kodakPortra400"]
            let payload = try JSONSerialization.data(withJSONObject: [
                "hiddenPresetIDs": legacyIDs, "orderedFilmIDs": [imported.id, "fujiRawASTIA"]
            ])
            defaults.set(payload, forKey: FilmPageSettings.storageKey)
            let settings = FilmPageSettings(defaults: defaults)
            let sources = FilmPreset.allCases.map(FilmSource.preset) + [imported]
            XCTAssertTrue(settings.preferences.addedPresets.isEmpty)
            XCTAssertEqual(settings.preferences.ordered(sources).filter(settings.preferences.isVisible), [imported])
            XCTAssertEqual(FilmPageSettings(defaults: defaults).preferences, settings.preferences)
        }
    }

    func testLegacyDefaultOrderAndMembershipSurviveCatalogExpansion() throws {
        let payload = Data(#"{"hiddenPresetIDs":[],"orderedFilmIDs":[]}"#.utf8)
        let preferences = try JSONDecoder().decode(FilmPagePreferences.self, from: payload)
        let expected: [FilmPreset] = [.fujiRawVelvia, .fujiRawASTIA, .fujiRawClassicChrome, .fujiRawClassicNeg,
            .fujiRawACROS, .fujiC200, .fujiPro400H, .fujiProvia100F, .kodakPortra400]
        let visible = preferences.ordered(FilmPreset.allCases.map(FilmSource.preset)).filter(preferences.isVisible)
        XCTAssertEqual(visible, expected.map(FilmSource.preset))
        XCTAssertEqual(Set(preferences.addedPresets), Set(expected))
    }

    func testCameraUsesLibraryOrderAndIncludesAnUnaddedCurrentFilmOnce() {
        var preferences = FilmPagePreferences()
        let customFilm = custom()
        let current = FilmSource.preset(.kodakPortra800)
        let sources = FilmPreset.allCases.map(FilmSource.preset) + [customFilm]
        preferences.orderedFilmIDs = [customFilm.id, FilmPreset.fujiC200.rawValue]
        let visible = preferences.ordered(sources).filter(preferences.isVisible)
        XCTAssertEqual(preferences.cameraSources(sources, current: current), visible + [current])
        XCTAssertEqual(preferences.cameraSources(sources, current: customFilm), visible)
        XCTAssertFalse(preferences.addedPresetIDs.contains(FilmPreset.kodakPortra800.rawValue))
    }
}
