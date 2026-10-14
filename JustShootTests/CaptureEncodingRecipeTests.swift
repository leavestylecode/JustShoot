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
}
