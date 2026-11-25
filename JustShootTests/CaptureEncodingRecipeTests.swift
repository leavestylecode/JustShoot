import XCTest
@testable import JustShoot

final class CaptureEncodingRecipeTests: XCTestCase {
    private func recipe(quality: Double?) -> CaptureRecipe {
        CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "film", displayLabel: nil,
            focalLength: 35, outputQuality: quality, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: 2, chromaticSceneCCT: nil, photoDisplayTime: nil)
    }

    func testAutomaticEncodingSurvivesAnEarlyCheckpointAndProcessRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CaptureJournal(root: root)
        let lut = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let original = recipe(quality: nil)
        _ = try journal.stage(recipe: original, imageData: Data([1, 2]), movieURL: nil,
            lut: lut, awaitingCaptureCompletion: true)
        let recovered = try XCTUnwrap(journal.recover().first)
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.recipe.fileNumber, 1)
        XCTAssertEqual(recovered.recipe.withPhotoDisplayTime(0.5).fileNumber, 1)
        try journal.finish(original.id)
        let reopened = CaptureJournal(root: root)
        let next = try reopened.stage(recipe: recipe(quality: nil), imageData: Data([3]), movieURL: nil, lut: lut)
        XCTAssertEqual(next.recipe.fileNumber, 2)
        XCTAssertNil(recovered.recipe.outputQuality)
        XCTAssertNil(recovered.recipe.withPhotoDisplayTime(0.5).outputQuality)
    }

    func testLegacyFrozenQualityStillDecodesAndSurvivesLateMovieTiming() throws {
        for quality in [0.6, 0.8, 0.9, 1.0] {
            let original = recipe(quality: quality)
            let restored = try JSONDecoder().decode(CaptureRecipe.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(restored.outputQuality, quality)
            XCTAssertEqual(restored.withPhotoDisplayTime(0.5).outputQuality, quality)
        }
    }

    func testLUTIntensityPreservesLegacyDefaultsAndSurvivesLateMovieTiming() throws {
        let legacy = recipe(quality: nil)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let restoredLegacy = try decoder.decode(CaptureRecipe.self, from: encoder.encode(legacy))
        XCTAssertNil(restoredLegacy.lutIntensity)
        XCTAssertEqual(restoredLegacy.resolvedLUTIntensity, 1)

        var captured = legacy
        captured.lutIntensity = CameraCapturePolicy.defaultLUTIntensity
        let restored = try decoder.decode(CaptureRecipe.self, from: encoder.encode(captured))
        XCTAssertEqual(restored.resolvedLUTIntensity, 0.88)
        XCTAssertEqual(restored.withPhotoDisplayTime(0.5).resolvedLUTIntensity, 0.88)
    }

    func testWhiteBalanceReferenceSurvivesRestartAndLateMovieTiming() throws {
        var frozen = recipe(quality: nil)
        frozen.colorAdjustment = ResolvedCameraColorAdjustment.resolve(temperature: .temperature(5_000),
            tint: .value(8), reading: CameraWhiteBalanceReading(temperature: 3_200, tint: -3))
        frozen.frozenChromaticGain = SIMD3(1.1, 1, 0.85)
        let restored = try JSONDecoder().decode(CaptureRecipe.self, from: JSONEncoder().encode(frozen))
        XCTAssertEqual(restored.colorAdjustment, frozen.colorAdjustment)
        XCTAssertEqual(restored.withPhotoDisplayTime(0.5).colorAdjustment, frozen.colorAdjustment)
        XCTAssertEqual(restored.frozenChromaticGain, frozen.frozenChromaticGain)
        XCTAssertEqual(restored.withPhotoDisplayTime(0.5).frozenChromaticGain, frozen.frozenChromaticGain)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(frozen)) as? [String: Any])
        legacy.removeValue(forKey: "colorAdjustment")
        legacy.removeValue(forKey: "frozenChromaticGain")
        XCTAssertNil(try JSONDecoder().decode(CaptureRecipe.self,
            from: JSONSerialization.data(withJSONObject: legacy)).colorAdjustment)
    }

    func testEstimatedFocalLengthPolicySurvivesRecoveryAndLateMovieTiming() throws {
        var frozen = recipe(quality: nil)
        frozen.preservesSourceFocalLength = true
        let restored = try JSONDecoder().decode(CaptureRecipe.self, from: JSONEncoder().encode(frozen))
        XCTAssertNil(restored.metadataFocalLength)
        XCTAssertNil(restored.withPhotoDisplayTime(0.5).metadataFocalLength)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(frozen)) as? [String: Any])
        legacy.removeValue(forKey: "preservesSourceFocalLength")
        let old = try JSONDecoder().decode(CaptureRecipe.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.metadataFocalLength, 35)
    }

    func testPortraitGrainResponseSurvivesCheckpointRecoveryAndLateTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CaptureJournal(root: root)
        let lut = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        for preset in [FilmPreset.kodakPortra400, .fujiPro400H] {
            let original = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: preset.lutResourceName,
                displayLabel: nil, focalLength: 35, outputQuality: nil, profile: preset.renderProfile,
                grainSeed: 123, location: nil, lutDimension: 2, chromaticSceneCCT: 6_000, photoDisplayTime: nil)
            _ = try journal.stage(recipe: original, imageData: Data([1, 2]), movieURL: nil,
                lut: lut, awaitingCaptureCompletion: true)
            let recovered = try XCTUnwrap(journal.recover().first { $0.id == original.id })
            XCTAssertEqual(recovered.recipe.profile.grain.response, .balanced)
            XCTAssertEqual(recovered.recipe.withPhotoDisplayTime(0.75).profile, original.profile)
            XCTAssertEqual(recovered.recipe.grainSeed, original.grainSeed)
        }
    }
}
