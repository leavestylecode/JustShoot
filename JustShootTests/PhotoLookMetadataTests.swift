import Photos
import SwiftData
import XCTest
@testable import JustShoot

final class PhotoLookMetadataTests: XCTestCase {
    private let asShot = PhotoFilmLook(filmID: FilmPreset.fujiC200.id, filmName: nil, curve: .preset(.matte))

    func testCropOnlyKeepsCapturedColorsAndCameraOriginalDiscardsThem() {
        var recipe = PhotoEditRecipe()
        recipe.crop.turns = 1
        func looks() -> (capture: PhotoFilmLook?, edit: PhotoFilmLook?) {
            PhotoLookAdjustment.edit(.init(recipe: recipe, hasCameraOriginal: true)).looks(asShot: asShot)
        }
        XCTAssertEqual(looks().capture, asShot)
        XCTAssertNil(looks().edit)
        recipe.useCameraOriginal = true
        XCTAssertNil(looks().capture)
        XCTAssertNil(looks().edit?.filmID)
        XCTAssertEqual(looks().edit?.curve, .preset(.none))
    }

    func testSheetShowsRetainedCaptureSettingsAlongsidePartialColorEdits() {
        let curveOnly = PhotoFilmLook(filmID: nil, filmName: nil, curve: .preset(.crossProcess), intensity: 1)
        let combined = curveOnly.displayed(over: asShot)
        XCTAssertEqual(combined.preset, .fujiC200)
        XCTAssertNil(combined.intensity)
        XCTAssertEqual(combined.curve, .preset(.crossProcess))

        let filmOnly = PhotoFilmLook(filmID: FilmPreset.kodakGold200.id, filmName: nil, curve: .preset(.none), intensity: 0.6)
        XCTAssertEqual(filmOnly.displayed(over: asShot).curve, asShot.curve)
        XCTAssertEqual(filmOnly.displayed(over: nil), filmOnly)
    }

    func testBakedLookAndEditedCustomLookSurviveRemovalFromCatalog() throws {
        let id = UUID()
        var curve = CustomFilmCurve(name: "My shadows")
        curve.applyTemplate(.crossProcess)
        let recipe = PhotoEditRecipe(filmID: id.uuidString, intensity: 0.62, curve: .custom(curve))
        let data = try PhotoEditSession.Adjustment(recipe: recipe, hasCameraOriginal: false, filmName: "Evening").encoded()
        XCTAssertNil(PhotoEditSession.Adjustment.decode(data, films: []))
        let looks = try XCTUnwrap(PhotoEditSession.lookAdjustment(data)).looks(asShot: asShot)
        XCTAssertEqual(looks.capture, asShot)
        XCTAssertEqual(looks.edit?.customID, id)
        XCTAssertEqual(looks.edit?.filmName, "Evening")
        XCTAssertEqual(looks.edit?.curve?.resolved.previewData, curve.filmCurve.previewData)
        XCTAssertEqual(looks.edit?.intensity, 0.62)
    }

    @MainActor
    func testV1PhotoAndCustomFilmMigrateAndNewCurveSurvivesIndexRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = ModelConfiguration(url: folder.appendingPathComponent("library.store"), cloudKitDatabase: .none)
        let id = UUID(), lutID = UUID()
        let bytes = Data([1, 2, 3])
        do {
            let store = try ModelContainer(for: Schema(versionedSchema: SchemaV1.self), configurations: [config])
            let photo = SchemaV1.Photo(id: id, timestamp: .now)
            photo.filmPresetName = "custom:\(lutID.uuidString)"
            photo.filmDisplayLabel = "Evening"
            photo.imageData = bytes
            store.mainContext.insert(photo)
            let lut = CustomLUT(displayName: "Evening", fileName: "evening.cube", iso: 100, dimension: 2)
            lut.id = lutID
            store.mainContext.insert(lut)
            try store.mainContext.save()
        }
        let store = try ModelContainer(for: Schema(versionedSchema: SchemaV2.self),
                                       migrationPlan: JustShootMigrationPlan.self, configurations: [config])
        let photo = try XCTUnwrap(store.mainContext.fetch(FetchDescriptor<Photo>()).first)
        XCTAssertEqual(photo.id, id)
        XCTAssertEqual(photo.imageData, bytes)
        XCTAssertEqual(photo.filmDisplayLabel, "Evening")
        XCTAssertNil(photo.captureCurveData)
        XCTAssertEqual(try store.mainContext.fetch(FetchDescriptor<CustomLUT>()).first?.id, lutID)
        let saver = await PhotoSaver.background(container: store)
        let curve = PhotoEditCurve.custom(CustomFilmCurve(name: "Captured"))
        for supplied in [curve, nil] {
            _ = try await saver.save(id: id, assetLocalIdentifier: "asset", imageData: nil,
                filmPresetName: FilmPreset.fujiC200.id, filmDisplayLabel: nil, captureCurve: supplied,
                latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil)
        }
        let reader = ModelContext(store)
        let rows = try reader.fetch(FetchDescriptor<Photo>())
        XCTAssertEqual(rows.count, 1)
        let saved = try XCTUnwrap(rows.first?.captureCurveData)
        XCTAssertEqual(try JSONDecoder().decode(PhotoEditCurve.self, from: saved), curve)
    }
}
