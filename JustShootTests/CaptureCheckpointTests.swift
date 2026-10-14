import XCTest
@testable import JustShoot

final class CaptureCheckpointTests: XCTestCase {
    func testRecoveryDistinguishesReadableMovieFromInterruptedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("complete.mov")
        try await CapturePipelineTests.makeVideo(at: movie)
        let readable = try await LivePhotoProcessor.isReadableSource(at: movie)
        XCTAssertTrue(readable)
        let partial = root.appendingPathComponent("partial.mov")
        try Data([1, 2, 3]).write(to: partial)
        let incomplete = try await LivePhotoProcessor.isReadableSource(at: partial)
        XCTAssertFalse(incomplete)
    }
    private func fixture() throws -> (CaptureJournal, CaptureRecipe, CubeLUT) {
        let text = "LUT_3D_SIZE 2\n" + (0...1).flatMap { b in
            (0...1).flatMap { g in (0...1).map { r in "\(r) \(g) \(b)" } }
        }.joined(separator: "\n")
        let lut = try CubeLUT.parse(text)
        let recipe = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "test", displayLabel: nil,
            focalLength: 35, outputQuality: 0.8, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: 6_000, photoDisplayTime: nil)
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return (journal, recipe, lut)
    }

    func testStillIsDurableBeforeMovieAndForegroundRetryKeepsItPending() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let bytes = Data([1, 2, 3])
        _ = try journal.stage(recipe: recipe, imageData: bytes, movieURL: nil, lut: lut,
            reserved: true, awaitingCaptureCompletion: true)
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: recipe.id)), bytes)
        XCTAssertEqual(try journal.recover(excludingInFlight: [recipe.id]).first?.awaitingCaptureCompletion, true)
        let restoredLUT = try journal.lut(for: journal.job(for: recipe.id))
        XCTAssertEqual(restoredLUT.data, lut.data)
        XCTAssertEqual(restoredLUT.dimension, lut.dimension)
    }

    func testRestartWithoutMovieRecoversStillWithFrozenRecipe() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        _ = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut,
            reserved: true, awaitingCaptureCompletion: true,
            pendingMovieURL: journal.root.appendingPathComponent("missing.mov"))
        let restored = CaptureJournal(root: journal.root)
        let job = try XCTUnwrap(restored.recover().first)
        XCTAssertNil(job.awaitingCaptureCompletion)
        XCTAssertNil(job.pendingMovieURL)
        XCTAssertFalse(job.hasSourceMovie)
        XCTAssertEqual(job.recoveredIncompleteCapture, true)
        XCTAssertEqual(job.recipe.id, recipe.id)
        XCTAssertEqual(job.recipe.captureDate, recipe.captureDate)
        XCTAssertEqual(job.recipe.profile, recipe.profile)
        XCTAssertEqual(job.recipe.chromaticSceneCCT, recipe.chromaticSceneCCT)
    }

    func testLateMovieUpdatesCheckpointOnceWithoutReplacingStill() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let movie = journal.root.appendingPathComponent("native.mov")
        let still = Data([1, 2, 3])
        _ = try journal.stage(recipe: recipe, imageData: still, movieURL: nil, lut: lut,
            reserved: true, awaitingCaptureCompletion: true, pendingMovieURL: movie)
        try Data([4, 5, 6]).write(to: movie)
        let job = try journal.completeCapture(id: recipe.id, photoDisplayTime: 1.25, movieURL: movie)
        XCTAssertTrue(job.hasSourceMovie)
        XCTAssertNil(job.awaitingCaptureCompletion)
        XCTAssertNil(job.recoveredIncompleteCapture)
        XCTAssertEqual(job.recipe.photoDisplayTime, 1.25)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertEqual(try Data(contentsOf: journal.file("source.mov", for: recipe.id)), Data([4, 5, 6]))
        _ = try journal.completeCapture(id: recipe.id, photoDisplayTime: nil, movieURL: nil)
        XCTAssertEqual(try journal.job(for: recipe.id).recipe.photoDisplayTime, 1.25)
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: recipe.id)), still)
        XCTAssertEqual(try journal.jobs().count, 1)
    }

    func testRecoveryAdoptsMovieCommittedBeforeManifestUpdate() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        _ = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut,
            reserved: true, awaitingCaptureCompletion: true)
        try Data([4, 5]).write(to: journal.file("source.mov", for: recipe.id))
        XCTAssertTrue(try XCTUnwrap(journal.recover().first).hasSourceMovie)
    }

    func testFailedMovieCopyDoesNotConsumeStillOrCaptureCompletion() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let bytes = Data([1, 2])
        _ = try journal.stage(recipe: recipe, imageData: bytes, movieURL: nil, lut: lut,
            reserved: true, awaitingCaptureCompletion: true)
        XCTAssertThrowsError(try journal.completeCapture(id: recipe.id, photoDisplayTime: 1,
            movieURL: journal.root.appendingPathComponent("missing.mov")))
        XCTAssertEqual(try journal.job(for: recipe.id).awaitingCaptureCompletion, true)
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: recipe.id)), bytes)
        XCTAssertFalse(try XCTUnwrap(journal.recover().first).hasSourceMovie)
    }

    func testLegacyManifestWithoutCheckpointFieldsStillDecodes() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        _ = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut, reserved: true)
        let manifest = journal.file("manifest.json", for: recipe.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object.removeValue(forKey: "awaitingCaptureCompletion")
        object.removeValue(forKey: "pendingMovieURL")
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        XCTAssertEqual(try journal.recover().first?.id, recipe.id)
    }
}
