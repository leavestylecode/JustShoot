import XCTest
import SwiftData
import AVFoundation
import CoreImage
import Photos
@testable import JustShoot

@MainActor
final class CaptureLivePhotoRoundTripTests: XCTestCase {
    func testProcessedLivePhotoSavesOnePairedAssetAndLoadsForPlayback() async throws {
        guard LivePhotoEncoderConfiguration.isSupported else { throw XCTSkip("Live Photo capture requires iOS 18") }
        guard PhotoLibrary.isAuthorized else { throw XCTSkip("Photos access is required for the round trip") }
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let pipeline = CapturePipeline(journal: journal)
        await pipeline.configure(container: container)
        let lut = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let captureID = UUID()
        let date = Date()
        let displayTime = CMTime(value: 3, timescale: 30)
        let recipe = CaptureRecipe(id: captureID, captureDate: date, filterName: "live-round-trip", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmSource.preset(.fujiC200).captureRenderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil,
            photoDisplayTime: displayTime.seconds, plan: .resolve(mode: .livePhoto))
        let sourceMovie = FileManager.default.temporaryDirectory.appendingPathComponent("\(captureID).mov")
        defer { try? FileManager.default.removeItem(at: sourceMovie) }
        try await CapturePipelineTests.makeVideo(at: sourceMovie)
        let image = CIImage(color: CIColor(red: 0.7, green: 0.3, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let bytes = try XCTUnwrap(CIContext().jpegRepresentation(of: image, colorSpace: FilmImagePipeline.colorSpace))
        let reserved = await pipeline.reserve(lutBytes: lut.data.count, id: captureID)
        XCTAssertEqual(reserved, captureID)
        await pipeline.checkpointStill(CaptureStill(imageData: bytes, pendingLivePhotoMovieURL: sourceMovie), recipe: recipe, lut: lut)
        pipeline.enqueue(CaptureResult(imageData: bytes, livePhotoMovieURL: sourceMovie,
            photoDisplayTime: displayTime, requestedLive: true), recipe: recipe, lut: lut)
        let deadline = Date().addingTimeInterval(30)
        while pipeline.lastCompletion?.captureID != captureID && Date() < deadline {
            if pipeline.lastError != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(pipeline.lastCompletion?.captureID, captureID, pipeline.lastError ?? "Live Photo did not finish saving")
        let rows = try container.mainContext.fetch(FetchDescriptor<Photo>())
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.isLivePhoto)
        let assetID = try XCTUnwrap(row.assetLocalIdentifier)
        defer { Task { try? await PhotoLibrary.delete(localIdentifiers: [assetID]) } }
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
        XCTAssertTrue(asset.mediaSubtypes.contains(.photoLive))
        let resources = PHAssetResource.assetResources(for: asset)
        XCTAssertEqual(resources.filter { $0.type == .photo }.count, 1)
        XCTAssertEqual(resources.filter { $0.type == .pairedVideo }.count, 1)
        let live = await AssetImageLoader.shared.livePhoto(id: assetID, targetSize: CGSize(width: 320, height: 240))
        XCTAssertNotNil(live, "The saved pair must load through the detail view's playback path")
        XCTAssertEqual(PhotoLibrary.findCapture(id: captureID, creationDate: date), assetID)
        XCTAssertTrue(try journal.jobs().isEmpty)
        await pipeline.retryPending()
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Photo>()), 1)
    }
}
