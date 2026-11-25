import XCTest
@testable import JustShoot

@MainActor
final class FilmCurveLibraryTests: XCTestCase {
    private struct StoredPayload: Codable {
        var version = 2
        var customCurves: [CustomFilmCurve] = []
        var hiddenBuiltInIDs: [String] = []
        var selectedCurveID: String?
        var orderedCurveIDs: [String]?
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "film-curves-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func store(_ payload: StoredPayload, in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(payload), forKey: "filmCurveLibrary.v1")
    }

    private func load(_ defaults: UserDefaults) throws -> StoredPayload {
        try JSONDecoder().decode(StoredPayload.self, from: XCTUnwrap(defaults.data(forKey: "filmCurveLibrary.v1")))
    }

    func testOnlyThePreviouslySelectedRetiredOrRedefinedCurveMigrates() throws {
        for id in ["airyPastel", "softFaded", "warmRetro", "softShoulder"] {
            try withDefaults { defaults in
                defaults.set(id, forKey: "curvePreset")
                let library = FilmCurveLibrary(defaults: defaults)
                let curve = try XCTUnwrap(library.customCurves.first)
                XCTAssertEqual(library.customCurves.count, 1)
                XCTAssertTrue(curve.isVisible)
                XCTAssertEqual(library.selectedCurveID, curve.filmCurve.id)
                let restored = FilmCurveLibrary(defaults: defaults)
                XCTAssertEqual(restored.customCurves.count, 1)
                XCTAssertEqual(restored.selectedCurveID, library.selectedCurveID)
                XCTAssertEqual(restored.customCurves.first?.id, curve.id)
            }
        }
        try withDefaults { defaults in
            try store(StoredPayload(hiddenBuiltInIDs: ["airyPastel", "softFaded", "warmRetro"]), in: defaults)
            defaults.set("highContrast", forKey: "curvePreset")
            let library = FilmCurveLibrary(defaults: defaults)
            XCTAssertTrue(library.customCurves.isEmpty)
            XCTAssertEqual(library.selectedCurveID, "highContrast")
            XCTAssertTrue(library.hiddenBuiltInIDs.isEmpty)
        }
    }

    func testMigrationAtomicallyRecordsItsSelectionAndIgnoresAStaleLegacyMirror() throws {
        try withDefaults { defaults in
            defaults.set("warmRetro", forKey: "curvePreset")
            let first = FilmCurveLibrary(defaults: defaults)
            let payload = try load(defaults)
            XCTAssertEqual(payload.version, 2)
            XCTAssertEqual(payload.selectedCurveID, first.selectedCurveID)
            XCTAssertEqual(payload.customCurves.first?.id, first.customCurves.first?.id)
            // Simulate interruption before the compatibility mirror was written.
            defaults.set("warmRetro", forKey: "curvePreset")
            let second = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(second.customCurves, first.customCurves)
            XCTAssertEqual(second.selectedCurveID, first.selectedCurveID)
            XCTAssertEqual(defaults.string(forKey: "curvePreset"), first.selectedCurveID)
        }
    }

    func testFreshInstallAndNewSoftContrastNeverReceiveLegacyMigrationOnReload() throws {
        try withDefaults { defaults in
            let first = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(first.selectedCurveID, CurvePreset.none.rawValue)
            XCTAssertTrue(first.selectedCurve.isNeutral)
            XCTAssertEqual(try load(defaults).selectedCurveID, "none")
            XCTAssertTrue(first.select(.builtIn(.filmSoft)))
            let second = FilmCurveLibrary(defaults: defaults)
            XCTAssertTrue(second.customCurves.isEmpty)
            XCTAssertEqual(second.selectedCurveID, "softShoulder")
        }
    }

    func testMigrationPreservesThePreviousSoftCurveAndWarmRGBEndpoints() throws {
        let soft = try XCTUnwrap(LegacyCurveMigration.customCurve(for: "softShoulder"))
        XCTAssertEqual(soft.masterPoints, CurveMath.points([
            (0, 0), (0.08, 0.045), (0.25, 0.20), (0.50, 0.52), (0.75, 0.82), (0.92, 0.965), (1, 1)
        ]))
        XCTAssertEqual(soft.filmCurve.sampleGray(0.25).red, 0.20, accuracy: 0.001)
        let warm = try XCTUnwrap(LegacyCurveMigration.customCurve(for: "warmRetro"))
        XCTAssertEqual(warm.masterPoints, CurveMath.identityPoints)
        let black = warm.filmCurve.sampleGray(0)
        let white = warm.filmCurve.sampleGray(1)
        XCTAssertEqual(black.red, 0.015, accuracy: 0.000001)
        XCTAssertEqual(black.green, 0.025, accuracy: 0.000001)
        XCTAssertEqual(black.blue, 0.055, accuracy: 0.000001)
        XCTAssertEqual(white.red, 1, accuracy: 0.000001)
        XCTAssertEqual(white.green, 0.985, accuracy: 0.000001)
        XCTAssertEqual(white.blue, 0.93, accuracy: 0.000001)
        XCTAssertNil(LegacyCurveMigration.customCurve(for: "none"))
        XCTAssertNil(LegacyCurveMigration.customCurve(for: "unknown"))
    }

    func testLegacyHiddenSelectionsFallBackWithoutRevivingHiddenCurves() throws {
        for selection in ["softShoulder", "warmRetro", "crossProcess"] {
            try withDefaults { defaults in
                try store(StoredPayload(hiddenBuiltInIDs: ["none", selection, "airyPastel"]), in: defaults)
                defaults.set(selection, forKey: "curvePreset")
                let library = FilmCurveLibrary(defaults: defaults)
                XCTAssertEqual(library.selectedCurveID, "none")
                XCTAssertTrue(library.customCurves.isEmpty)
                XCTAssertTrue(library.isBuiltInVisible(.none))
                XCTAssertFalse(library.hiddenBuiltInIDs.contains("airyPastel"))
            }
        }
    }

    func testUnknownOrMalformedPayloadCannotBeOverwrittenByAnyMutation() throws {
        let future = Data("{\"version\":99,\"futureData\":\"preserve me\"}".utf8)
        let malformed = Data("not JSON".utf8)
        for original in [future, malformed] {
            try withDefaults { defaults in
                defaults.set(original, forKey: "filmCurveLibrary.v1")
                defaults.set("warmRetro", forKey: "curvePreset")
                let library = FilmCurveLibrary(defaults: defaults)
                let custom = CustomFilmCurve(name: "New")
                XCTAssertNotNil(library.storageError)
                XCTAssertFalse(library.canEdit)
                XCTAssertFalse(library.add(custom))
                XCTAssertFalse(library.update(custom))
                XCTAssertFalse(library.delete(id: custom.id))
                XCTAssertFalse(library.select(.builtIn(.punch)))
                XCTAssertFalse(library.setBuiltIn(.punch, isVisible: false))
                XCTAssertFalse(library.setCustomVisibility(id: custom.id, isVisible: false))
                XCTAssertFalse(library.setOrder(Array(library.entries.map(\.id).reversed())))
                XCTAssertEqual(defaults.data(forKey: "filmCurveLibrary.v1"), original)
                XCTAssertEqual(defaults.string(forKey: "curvePreset"), "warmRetro")
            }
        }
    }

    func testExistingCustomIdentityDatesVisibilityAndChannelPointsSurviveCatalogMigration() throws {
        try withDefaults { defaults in
            var existing = CustomFilmCurve(name: "Mine")
            existing.createdAt = Date(timeIntervalSinceReferenceDate: 100)
            existing.updatedAt = Date(timeIntervalSinceReferenceDate: 200)
            existing.isVisible = false
            existing.bluePoints = CurveMath.points([(0, 0.05), (0.5, 0.65), (1, 0.9)])
            try store(StoredPayload(version: 1, customCurves: [existing], hiddenBuiltInIDs: ["matteShadow"]), in: defaults)
            defaults.set("airyPastel", forKey: "curvePreset")
            let library = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(library.customCurves.first { $0.id == existing.id }, existing)
            XCTAssertEqual(library.customCurves.count, 2)
            XCTAssertFalse(library.isBuiltInVisible(.matte))
            XCTAssertNil(library.curve(id: existing.filmCurve.id))
        }
    }

    func testSavingAStaleEditorDraftDoesNotRestoreHiddenVisibility() throws {
        try withDefaults { defaults in
            let library = FilmCurveLibrary(defaults: defaults)
            let initial = CustomFilmCurve(name: "Initial")
            XCTAssertTrue(library.add(initial))
            XCTAssertTrue(library.select(initial.filmCurve))
            var draft = initial
            XCTAssertTrue(library.setCustomVisibility(id: initial.id, isVisible: false))
            draft.name = "Edited"
            XCTAssertTrue(library.update(draft))
            let saved = try XCTUnwrap(library.customCurves.first)
            XCTAssertFalse(saved.isVisible)
            XCTAssertEqual(saved.name, "Edited")
            XCTAssertEqual(saved.createdAt, initial.createdAt)
            XCTAssertEqual(library.selectedCurveID, "none")
            XCTAssertNil(library.curve(id: initial.filmCurve.id))
        }
    }

    func testDuplicateSaveCannotInsertASecondCurveWithTheSameUUID() throws {
        try withDefaults { defaults in
            let library = FilmCurveLibrary(defaults: defaults)
            let curve = CustomFilmCurve(name: "Saved once")
            XCTAssertTrue(library.add(curve))
            var duplicate = curve
            duplicate.name = "Should not replace it"
            XCTAssertFalse(library.add(duplicate))
            XCTAssertEqual(library.customCurves.count, 1)
            XCTAssertEqual(library.customCurves.first?.name, "Saved once")
            XCTAssertEqual(FilmCurveLibrary(defaults: defaults).customCurves.count, 1)
        }
    }

    func testHidingOrDeletingASelectionPersistsNeutralAlongWithTheCatalog() throws {
        try withDefaults { defaults in
            let library = FilmCurveLibrary(defaults: defaults)
            XCTAssertTrue(library.select(.builtIn(.punch)))
            XCTAssertTrue(library.setBuiltIn(.punch, isVisible: false))
            XCTAssertEqual(try load(defaults).selectedCurveID, "none")
            let curve = CustomFilmCurve(name: "Delete me")
            XCTAssertTrue(library.add(curve))
            XCTAssertTrue(library.select(curve.filmCurve))
            XCTAssertTrue(library.delete(id: curve.id))
            let restored = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(restored.selectedCurveID, "none")
            XCTAssertTrue(restored.customCurves.isEmpty)
            XCTAssertFalse(restored.isBuiltInVisible(.punch))
        }
    }

    func testBuiltInAndCustomOrderPersistsWithHiddenCurvesAndSelection() throws {
        try withDefaults { defaults in
            let custom = CustomFilmCurve(name: "Custom")
            let customID = custom.filmCurve.id
            let builtInIDs = CurvePreset.allCases.map(\.id)
            try store(StoredPayload(customCurves: [custom], hiddenBuiltInIDs: [CurvePreset.matte.id]), in: defaults)
            let library = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(library.entries.map(\.id), builtInIDs + [customID])
            XCTAssertTrue(library.select(custom.filmCurve))

            let order = [CurvePreset.crossProcess.id, customID] + builtInIDs.dropLast()
            XCTAssertTrue(library.setOrder(order))
            XCTAssertEqual(library.visibleCurves.map(\.id), order.filter { $0 != CurvePreset.matte.id })

            let restored = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(restored.entries.map(\.id), order)
            XCTAssertEqual(restored.selectedCurveID, customID)
            XCTAssertEqual(try load(defaults).orderedCurveIDs, order)
            XCTAssertTrue(restored.setBuiltIn(.matte, isVisible: true))
            XCTAssertEqual(restored.visibleCurves.map(\.id), order)
        }
    }

    func testUpgradeInsertsFadedSAfterFadedOnceAndPreservesIndependentPreferences() throws {
        try withDefaults { defaults in
            let custom = CustomFilmCurve(name: "Saved")
            let faded = CurvePreset.matte.id
            let fadedS = CurvePreset.fadedS.id
            let others = [CurvePreset.none.id, CurvePreset.crossProcess.id, CurvePreset.filmSoft.id, CurvePreset.punch.id]
            let saved = [custom.filmCurve.id, faded] + others
            try store(StoredPayload(customCurves: [custom], selectedCurveID: faded, orderedCurveIDs: saved), in: defaults)

            let library = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(library.visibleCurves.map(\.id), [custom.filmCurve.id, faded, fadedS] + others)
            XCTAssertEqual(library.selectedCurveID, faded)
            XCTAssertTrue(library.select(.builtIn(.fadedS)))
            XCTAssertTrue(library.setBuiltIn(.matte, isVisible: false))
            let reordered = [fadedS] + saved
            XCTAssertTrue(library.setOrder(reordered))

            let restored = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(restored.entries.map(\.id), reordered)
            XCTAssertEqual(restored.visibleCurves.map(\.id), reordered.filter { $0 != faded })
            XCTAssertEqual(restored.selectedCurveID, fadedS)
        }
    }

    func testAddingAndDeletingKeepOrderAndRejectAStaleReorder() throws {
        try withDefaults { defaults in
            let library = FilmCurveLibrary(defaults: defaults)
            let builtInOrder = Array(library.entries.map(\.id).reversed())
            XCTAssertTrue(library.setOrder(builtInOrder))
            let custom = CustomFilmCurve(name: "New")
            let customID = custom.filmCurve.id
            XCTAssertTrue(library.add(custom))
            let orderWithCustom = builtInOrder + [customID]
            XCTAssertEqual(library.entries.map(\.id), orderWithCustom)

            XCTAssertTrue(library.delete(id: custom.id))
            XCTAssertFalse(library.setOrder(Array(orderWithCustom.reversed())))
            XCTAssertFalse(library.setOrder(Array(repeating: CurvePreset.none.id, count: builtInOrder.count)))
            XCTAssertEqual(FilmCurveLibrary(defaults: defaults).entries.map(\.id), builtInOrder)
        }
    }

    func testStoredOrderDropsUnknownAndDuplicateIDsAndAppendsMissingCurves() throws {
        try withDefaults { defaults in
            let custom = CustomFilmCurve(name: "Saved")
            let first = CurvePreset.punch.id
            try store(StoredPayload(customCurves: [custom], orderedCurveIDs: [first, "missing", first]), in: defaults)
            let library = FilmCurveLibrary(defaults: defaults)
            let expected = [first] + CurvePreset.allCases.map(\.id).filter { $0 != first } + [custom.filmCurve.id]
            XCTAssertEqual(library.entries.map(\.id), expected)
            XCTAssertEqual(try load(defaults).orderedCurveIDs, expected)
        }
    }

    func testOldMatteMigratesWithAndWithoutAnAtomicSelectionAndDoesNotDuplicateOnReload() throws {
        for hasAtomicSelection in [false, true] {
            try withDefaults { defaults in
                let existing = CustomFilmCurve(name: "Already saved")
                try store(StoredPayload(customCurves: [existing],
                    selectedCurveID: hasAtomicSelection ? "matteShadow" : nil), in: defaults)
                defaults.set(hasAtomicSelection ? "none" : "matteShadow", forKey: "curvePreset")
                let library = FilmCurveLibrary(defaults: defaults)
                XCTAssertEqual(library.customCurves.count, 2)
                let migrated = try XCTUnwrap(library.customCurves.first { $0.id != existing.id })
                XCTAssertEqual(library.selectedCurveID, migrated.filmCurve.id)
                XCTAssertEqual(migrated.masterPoints, CurveMath.points([
                    (0, 0.06), (0.16, 0.18), (0.35, 0.36), (0.62, 0.66), (0.84, 0.88), (1, 0.985)
                ]))
                XCTAssertEqual(migrated.filmCurve.sampleGray(0).red, 0.06, accuracy: 0.000001)
                XCTAssertEqual(migrated.filmCurve.sampleGray(1).red, 0.985, accuracy: 0.000001)
                let restored = FilmCurveLibrary(defaults: defaults)
                XCTAssertEqual(restored.customCurves, library.customCurves)
                XCTAssertEqual(restored.selectedCurveID, library.selectedCurveID)
                XCTAssertEqual(try load(defaults).selectedCurveID, library.selectedCurveID)
            }
        }
    }

    func testNewMatteSelectionIsNotMistakenForThePreviousMatteDefinition() throws {
        try withDefaults { defaults in
            let library = FilmCurveLibrary(defaults: defaults)
            XCTAssertEqual(CurvePreset.matte.rawValue, "matteSCurve")
            XCTAssertTrue(library.select(.builtIn(.matte)))
            defaults.set("matteShadow", forKey: "curvePreset")
            let restored = FilmCurveLibrary(defaults: defaults)
            XCTAssertTrue(restored.customCurves.isEmpty)
            XCTAssertEqual(restored.selectedCurveID, "matteSCurve")
        }
    }

    func testOldMatteHiddenPreferenceMapsToTheCurrentMatteWithoutRevivingTheHiddenSelection() throws {
        for hasAtomicSelection in [false, true] {
            try withDefaults { defaults in
                try store(StoredPayload(hiddenBuiltInIDs: ["none", "matteShadow"],
                    selectedCurveID: hasAtomicSelection ? "matteShadow" : nil), in: defaults)
                defaults.set("matteShadow", forKey: "curvePreset")
                let library = FilmCurveLibrary(defaults: defaults)
                XCTAssertEqual(library.selectedCurveID, "none")
                XCTAssertTrue(library.customCurves.isEmpty)
                XCTAssertFalse(library.isBuiltInVisible(.matte))
                XCTAssertTrue(library.isBuiltInVisible(.none))
                XCTAssertEqual(library.hiddenBuiltInIDs, ["matteSCurve"])
                XCTAssertEqual(try load(defaults).hiddenBuiltInIDs, ["matteSCurve"])
                let restored = FilmCurveLibrary(defaults: defaults)
                XCTAssertEqual(restored.selectedCurveID, "none")
                XCTAssertTrue(restored.customCurves.isEmpty)
                XCTAssertFalse(restored.isBuiltInVisible(.matte))
            }
        }
    }
}
