import XCTest
import SwiftData
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
@testable import JustShoot

private actor DeferredImportGate {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func importProxy() async throws -> String {
        calls += 1
        if !released { await withCheckedContinuation { continuation = $0 } }
        throw PhotoLibraryError.saveFailed
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class CaptureAsyncFlowTests: XCTestCase {
    @MainActor
    func testShutterPreviewAppearsBeforeCheckpointAndClearsOnCancellation() async throws {
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let pipeline = CapturePipeline(journal: journal)
        await pipeline.configure(container: container)
        let lut = try cube()
        let id = UUID()
        let reserved = await pipeline.reserve(lutBytes: lut.data.count, id: id)
        XCTAssertEqual(reserved, id)
        pipeline.preparePreview(try frame(data: image()), recipe: recipe(id: id, lut: lut), lut: lut)
        let deadline = Date().addingTimeInterval(3)
        while pipeline.lastPreview == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(pipeline.lastPreview?.id, id, "The shutter preview must not wait for native photo delivery")
        XCTAssertFalse(pipeline.pendingJobIDs.contains(id))
        pipeline.cancelReservation(id)
        XCTAssertNil(pipeline.lastPreview)
        XCTAssertFalse(pipeline.isProcessing(id))

        let nextID = UUID()
        let next = await pipeline.reserve(lutBytes: lut.data.count, id: nextID)
        XCTAssertEqual(next, nextID)
        pipeline.preparePreview(try frame(data: image()), recipe: recipe(id: nextID, lut: lut), lut: lut)
        pipeline.cancelReservation(nextID)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(pipeline.lastPreview, "An in-flight preview must not reappear after cancellation")
    }

    @MainActor
    func testDurableCheckpointAndNextCaptureDoNotWaitForPhotosImport() async throws {
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let gate = DeferredImportGate()
        defer { Task { await gate.release() } }
        let pipeline = CapturePipeline(journal: journal, storeDeferredProxy: { _, _ in try await gate.importProxy() })
        await pipeline.configure(container: container)
        let lut = try cube()
        let id = UUID()
        let recipe = recipe(id: id, lut: lut)
        let reserved = await pipeline.reserve(lutBytes: lut.data.count, id: id)
        XCTAssertEqual(reserved, id)
        let bytes = try image()
        pipeline.preparePreview(try frame(data: bytes), recipe: recipe, lut: lut)
        let state = DeferredPhotoState(width: 48, height: 36)
        await pipeline.checkpointStill(CaptureStill(imageData: bytes, pendingLivePhotoMovieURL: nil, deferredPhoto: state),
            recipe: recipe, lut: lut)
        let callsAtCheckpoint = await gate.calls
        XCTAssertEqual(callsAtCheckpoint, 0, "Durability must release the shutter without waiting for Photos")
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: id)), bytes)
        pipeline.enqueue(CaptureResult(imageData: bytes, livePhotoMovieURL: nil, photoDisplayTime: .invalid,
            deferredPhoto: state), recipe: recipe, lut: lut)
        let deadline = Date().addingTimeInterval(3)
        while await gate.calls == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let callsDuringImport = await gate.calls
        XCTAssertEqual(callsDuringImport, 1)
        // Foreground/recovery can interleave with the suspended Photos transaction.
        await pipeline.retryPending()
        let callsAfterResume = await gate.calls
        XCTAssertEqual(callsAfterResume, 1, "Resume must not import the same proxy twice")
        XCTAssertEqual(try journal.job(for: id).awaitingCaptureCompletion, true)
        let next = await pipeline.reserve(lutBytes: lut.data.count)
        XCTAssertNotNil(next, "A slow Photos transaction must not block another capture reservation")
        if let next { pipeline.cancelReservation(next) }
        let previewDeadline = Date().addingTimeInterval(2)
        while pipeline.lastPreview == nil, Date() < previewDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let preview = try XCTUnwrap(pipeline.lastPreview)
        XCTAssertEqual(preview.id, id)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Photo>()).isEmpty,
            "A provisional preview must not be indexed as a saved photo")
        try await snapshot(preview: preview, pipeline: pipeline, container: container)
        await gate.release()
        let failureDeadline = Date().addingTimeInterval(3)
        while pipeline.lastError == nil, Date() < failureDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(pipeline.lastError)
        await pipeline.enterBackground()
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: id)), bytes)
        XCTAssertEqual(try journal.recover().first?.id, id)
        XCTAssertTrue(pipeline.pendingJobIDs.contains(id))
    }

    @MainActor
    private func snapshot(preview: CapturePreview, pipeline: CapturePipeline, container: ModelContainer) async throws {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: NavigationStack {
            CapturePreviewReview(preview: preview, pipeline: pipeline, onClose: {})
        }.modelContainer(container).preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "capture-preview-saving"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-preview-saving.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("capture_preview_snapshot path=\(url.path)")
    }

    func testQuickPreviewIsBoundedOrientedAndUsesTheCapturedLook() async throws {
        let lut = try cube(inverted: true)
        let image = await CapturePreviewRenderer.image(frame: try frame(data: image(width: 3_000, height: 2_250, orientation: 6)), lut: lut)
        let pixels = try XCTUnwrap(image?.cgImage)
        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), CapturePreviewRenderer.maximumPixel)
        XCTAssertEqual(Double(pixels.width) / Double(pixels.height), 0.75, accuracy: 0.01)
        var sample = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: pixels), toBitmap: &sample, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
        XCTAssertGreaterThan(Int(sample[1]), Int(sample[0]) + 60, "The frozen inverted look must be applied")
    }

    func testCancelledQuickPreviewDoesNotProduceAnImage() async throws {
        let bytes = try image()
        let lut = try cube()
        let capturedFrame = try frame(data: bytes)
        let task = Task { await CapturePreviewRenderer.image(frame: capturedFrame, lut: lut) }
        task.cancel()
        let image = await task.value
        XCTAssertNil(image)
    }

    func testQuickPreviewUsesRenderedGainInsteadOfLaterSceneTemperature() async throws {
        let lut = try cube()
        // Neutral midtones isolate the illuminant response from highlight desaturation.
        let bytes = try image(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
        let neutral = await CapturePreviewRenderer.image(frame: try frame(data: bytes), lut: lut)
        let profile = FilmRenderProfile(grain: .disabled, optics: .disabled,
            chromatic: FilmChromaticResponseParameters(nativeCCT: 6_500, strength: 1))
        let frozen = recipe(id: UUID(), lut: lut, profile: profile, sceneCCT: 6_500)
        let gain = profile.effectiveChromatic.responseGain(sceneCCT: 2_500)
        let warm = await CapturePreviewRenderer.image(frame: try frame(data: bytes, gain: gain), lut: lut, recipe: frozen)
        func blue(_ image: UIImage?) throws -> UInt8 {
            let pixels = try XCTUnwrap(image?.cgImage)
            var sample = [UInt8](repeating: 0, count: 4)
            CIContext().render(CIImage(cgImage: pixels), toBitmap: &sample, rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
            return sample[2]
        }
        XCTAssertLessThan(try Int(blue(warm)), try Int(blue(neutral)) - 10,
            "The badge must use the rendered frame's gain even after the scene reading changes")
    }

    func testQuickPreviewGrainIsFrozenAndDeterministic() async throws {
        let lut = try cube()
        let bytes = try image(width: 320, height: 240)
        let profile = FilmRenderProfile(grain: FilmPreset.fujiC200.renderProfile.grain,
            optics: .disabled, chromatic: .neutral)
        let frozen = recipe(id: UUID(), lut: lut, profile: profile)
        let first = await CapturePreviewRenderer.image(frame: try frame(data: bytes), lut: lut, recipe: frozen)
        let repeated = await CapturePreviewRenderer.image(frame: try frame(data: bytes), lut: lut, recipe: frozen)
        let plain = await CapturePreviewRenderer.image(frame: try frame(data: bytes), lut: lut)
        let firstBytes = try XCTUnwrap(first?.pngData())
        XCTAssertEqual(firstBytes, repeated?.pngData())
        XCTAssertNotEqual(firstBytes, plain?.pngData(), "The quick preview must include the captured film texture")
    }

    func testStillUsesTheRenderedGainAfterAWBChanges() async throws {
        let lut = try cube()
        let bytes = try image(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
        let profile = FilmRenderProfile(grain: .disabled, optics: .disabled,
            chromatic: FilmChromaticResponseParameters(nativeCCT: 6_500, strength: 1))
        let gain = profile.effectiveChromatic.responseGain(sceneCCT: 2_500)
        var frozen = recipe(id: UUID(), lut: lut, profile: profile, sceneCCT: 6_500)
        frozen.frozenChromaticGain = gain
        let recipe = frozen
        let preview = await CapturePreviewRenderer.image(frame: try frame(data: bytes, gain: gain), lut: lut, recipe: recipe)
        let output = await Task.detached {
            CapturePhotoRenderer.render(source: bytes, recipe: recipe, lut: lut, rawLUT: nil, grainSeed: 1)
        }.value
        let still = try XCTUnwrap(FilmImagePipeline.decodePhoto(try XCTUnwrap(output)))
        let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace])
        let expected = CaptureComparisonDiagnostics.statistics(CIImage(cgImage: try XCTUnwrap(preview?.cgImage)), context: context)
        let actual = CaptureComparisonDiagnostics.statistics(still, context: context)
        for channel in 0..<3 { XCTAssertEqual(actual.meanRGB[channel], expected.meanRGB[channel], accuracy: 0.015) }
    }

    private func frame(data: Data, gain: SIMD3<Float> = SIMD3(repeating: 1)) throws -> CameraPreviewFrame {
        let image = try XCTUnwrap(FilmImagePipeline.decodePhoto(data, applyOrientation: true))
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CIContext().render(image, to: pixels, bounds: image.extent, colorSpace: FilmImagePipeline.colorSpace)
        return CameraPreviewFrame(buffer: pixels, generation: 1, frameID: 1, capturedAt: 1,
            lutKey: "test", rotation: 0, crop: 1, outputSize: image.extent.size, grainSeed: 1, chromaticGain: gain)
    }

    private func cube(inverted: Bool = false) throws -> CubeLUT {
        let text = "LUT_3D_SIZE 2\n" + (0...1).flatMap { b in
            (0...1).flatMap { g in (0...1).map { r in
                inverted ? "\(1-r) \(1-g) \(1-b)" : "\(r) \(g) \(b)"
            } }
        }.joined(separator: "\n")
        return try CubeLUT.parse(text)
    }

    private func recipe(id: UUID, lut: CubeLUT, profile: FilmRenderProfile? = nil, sceneCCT: Float? = nil) -> CaptureRecipe {
        CaptureRecipe(id: id, captureDate: Date(), filterName: "test", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: profile ?? FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: sceneCCT, photoDisplayTime: nil,
            plan: .resolve(mode: .quality))
    }

    private func image(width: Int = 48, height: Int = 36, orientation: Int = 1,
                       color: CIColor = CIColor(red: 0.8, green: 0.1, blue: 0.2)) throws -> Data {
        let image = CIImage(color: color)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
