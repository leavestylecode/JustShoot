import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import JustShoot

final class DeferredPhotoStateTests: XCTestCase {
    func testFinalImageValidationRejectsProxyPixelsAndAcceptsRotatedFinal() throws {
        let expected = DeferredPhotoState(width: 48, height: 36)
        XCTAssertFalse(expected.acceptsFinalImage(try image(width: 24, height: 18)))
        XCTAssertTrue(expected.acceptsFinalImage(try image(width: 48, height: 36)))
        XCTAssertTrue(expected.acceptsFinalImage(try image(width: 36, height: 48)))
        XCTAssertFalse(expected.acceptsFinalImage(Data([1, 2, 3])))
    }

    func testRestartKeepsProxyAndRecipeUntilPhotoKitFinalizesTheOriginal() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let proxy = try image(width: 24, height: 18)
        let state = DeferredPhotoState(width: 48, height: 36)
        _ = try journal.stage(recipe: recipe, imageData: proxy, movieURL: nil, lut: lut, reserved: true,
            awaitingCaptureCompletion: true, deferredPhoto: state)
        let restored = CaptureJournal(root: journal.root)
        var job = try XCTUnwrap(restored.recover().first)
        XCTAssertEqual(job.deferredPhoto, state)
        XCTAssertEqual(job.recipe.id, recipe.id)
        XCTAssertNil(job.awaitingCaptureCompletion)
        XCTAssertThrowsError(try restored.finalizeDeferredPhoto(proxy, for: recipe.id))
        job.deferredPhoto?.assetIdentifier = "photos-source"
        try restored.update(job)
        XCTAssertThrowsError(try restored.finalizeDeferredPhoto(proxy, for: recipe.id))
        XCTAssertEqual(try Data(contentsOf: restored.file("original.image", for: recipe.id)), proxy)
        let final = try image(width: 48, height: 36)
        let completed = try restored.finalizeDeferredPhoto(final, for: recipe.id)
        XCTAssertEqual(completed.deferredPhoto?.finalized, true)
        XCTAssertEqual(completed.deferredPhoto?.assetIdentifier, "photos-source")
        XCTAssertNil(completed.assetIdentifier, "An unfiltered source must not be marked as the saved film photo")
        XCTAssertEqual(try Data(contentsOf: restored.file("original.image", for: recipe.id)), final)
        XCTAssertEqual(try restored.recover().first?.deferredPhoto, completed.deferredPhoto)
    }

    func testProxyReceiptSurvivesRestartBeforeManifestAndRejectsCorruptData() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        _ = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut,
            deferredPhoto: DeferredPhotoState(width: 48, height: 36))
        XCTAssertNil(try journal.proxyPlaceholder(for: recipe.id))
        try journal.recordProxyPlaceholder("photos-source", for: recipe.id)
        let restored = CaptureJournal(root: journal.root)
        XCTAssertEqual(try restored.proxyPlaceholder(for: recipe.id), "photos-source")
        XCTAssertNil(try restored.job(for: recipe.id).deferredPhoto?.assetIdentifier)
        try Data([0]).write(to: restored.file("proxy-asset.json", for: recipe.id))
        XCTAssertThrowsError(try restored.proxyPlaceholder(for: recipe.id))
        try restored.recordProxyPlaceholder(nil, for: recipe.id)
        XCTAssertNil(try restored.proxyPlaceholder(for: recipe.id))
    }

    func testProxyCannotEnterTheLiveMoviePipeline() throws {
        let (journal, recipe, lut) = try fixture()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        XCTAssertThrowsError(try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil,
            lut: lut, reserved: true, pendingMovieURL: journal.root.appendingPathComponent("live.mov"),
            deferredPhoto: DeferredPhotoState(width: 48, height: 36)))
    }

    private func fixture() throws -> (CaptureJournal, CaptureRecipe, CubeLUT) {
        let text = "LUT_3D_SIZE 2\n" + (0...1).flatMap { b in
            (0...1).flatMap { g in (0...1).map { r in "\(r) \(g) \(b)" } }
        }.joined(separator: "\n")
        let lut = try CubeLUT.parse(text)
        let recipe = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "test", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil, photoDisplayTime: nil,
            plan: .resolve(mode: .quality))
        return (CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), recipe, lut)
    }

    private func image(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
