import XCTest
import CoreVideo
import MetalKit
@testable import JustShoot

@MainActor
final class PreviewMetalResourcesTests: XCTestCase {
    func testConcurrentEntriesReuseRendererResources() async throws {
        let snapshots = try await withThrowingTaskGroup(of: PreviewMetalResources.RendererResources.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await PreviewMetalResources.warmUpForRenderer()
                    return try await MainActor.run {
                        try XCTUnwrap(PreviewMetalResources.shared.rendererResources)
                    }
                }
            }
            var snapshots: [PreviewMetalResources.RendererResources] = []
            for try await snapshot in group { snapshots.append(snapshot) }
            return snapshots
        }
        let first = try XCTUnwrap(snapshots.first)
        for snapshot in snapshots {
            XCTAssertTrue(snapshot.device === first.device)
            XCTAssertTrue(snapshot.commandQueue === first.commandQueue)
            XCTAssertTrue(snapshot.computePipeline === first.computePipeline)
            XCTAssertTrue(snapshot.finishPipeline === first.finishPipeline)
            XCTAssertTrue(snapshot.textureCache === first.textureCache)
            XCTAssertTrue(snapshot.energyDownsampler === first.energyDownsampler)
        }
    }

    func testCameraExitFlushKeepsAnActiveFrameTextureValid() async throws {
        try await PreviewMetalResources.warmUpForRenderer()
        let resources = try XCTUnwrap(PreviewMetalResources.shared.rendererResources)
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        var cvTexture: CVMetalTexture?
        XCTAssertEqual(CVMetalTextureCacheCreateTextureFromImage(nil, resources.textureCache,
            buffer, nil, .bgra8Unorm, 16, 16, 0, &cvTexture), kCVReturnSuccess)
        let lease = try XCTUnwrap(cvTexture)
        let texture = try XCTUnwrap(CVMetalTextureGetTexture(lease))
        let coordinator = RealtimePreviewView.Coordinator()
        let view = MTKView(frame: .zero, device: resources.device)
        coordinator.setup(view: view)
        coordinator.flushFrameCache()
        XCTAssertTrue(CVMetalTextureGetTexture(lease) === texture)
        XCTAssertEqual(texture.width, CVPixelBufferGetWidth(buffer))
        XCTAssertEqual(texture.height, CVPixelBufferGetHeight(buffer))
    }

    func testCancelledRendererPreparationCannotReportReady() async {
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await PreviewMetalResources.warmUpForRenderer()
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
    }
}
