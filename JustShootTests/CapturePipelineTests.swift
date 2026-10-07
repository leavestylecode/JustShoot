import XCTest
import CoreLocation
import SwiftData
import CoreImage
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
@testable import JustShoot

final class CapturePipelineTests: XCTestCase {
    private var identityText: String {
        "LUT_3D_SIZE 2\n" + (0...1).flatMap { b in
            (0...1).flatMap { g in (0...1).map { r in "\(r) \(g) \(b)" } }
        }.joined(separator: "\n")
    }

    func testCubeHeadersAndCommentsDoNotBecomeSamples() throws {
        let text = "TITLE \"Film 100 200 300\"\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n" + identityText + " # final sample"
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.data.count, 8 * 4 * 4)
    }

    func testCubeRejectsNonFiniteAndMissingSamples() {
        XCTAssertThrowsError(try CubeLUT.parse(identityText.replacingOccurrences(of: "1 1 1", with: "nan 1 1")))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 9223372036854775807"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1"))
    }

    func testCubeRejectsUnsupportedDomainInsteadOfChangingColors() {
        XCTAssertThrowsError(try CubeLUT.parse("DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n" + identityText))
    }

    func testBinaryCubeRejectsInvalidPayload() {
        XCTAssertThrowsError(try CubeLUT.validated(data: Data(count: 3), dimension: 2))
        XCTAssertThrowsError(try CubeLUT.validated(data: Data(), dimension: Int.max))
    }

    func testLocationUsesMeasurementAgeAndAccuracy() {
        let now = Date()
        func location(age: TimeInterval, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31, longitude: 121), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 10, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(CaptureLocation.isUsable(location(age: 5), at: now))
        XCTAssertFalse(CaptureLocation.isUsable(location(age: 31), at: now))
        XCTAssertFalse(CaptureLocation.isUsable(location(age: 0, accuracy: -1), at: now))
        XCTAssertFalse(CaptureLocation.isUsable(location(age: -60), at: now))
    }

    func testJournalRetainsRecipeAndLiveResourcesUntilCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let movie = root.appendingPathComponent("input.mov")
        try Data([5, 6, 7]).write(to: movie)
        let journal = CaptureJournal(root: root.appendingPathComponent("queue"))
        let lut = try CubeLUT.parse(identityText)
        let recipe = recipe(lut: lut)
        var job = try journal.stage(recipe: recipe, imageData: Data([1, 2, 3]), movieURL: movie, lut: lut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertEqual(try Data(contentsOf: journal.file("source.mov", for: recipe.id)), Data([5, 6, 7]))
        XCTAssertEqual(try journal.jobs().first?.recipe.captureDate, recipe.captureDate)
        XCTAssertEqual(try journal.lut(for: job).data, lut.data)
        try journal.writeRenderedImage(Data([8, 9]), for: recipe.id)
        job.rendered = true
        try journal.update(job)
        let reopened = CaptureJournal(root: journal.root)
        XCTAssertTrue(try XCTUnwrap(reopened.jobs().first).rendered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.file("original.image", for: recipe.id).path))
        try journal.finish(recipe.id)
        XCTAssertTrue(try journal.jobs().isEmpty)
    }

    func testJournalAppliesBackpressureWithoutRemovingOlderJobs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CaptureJournal(root: root)
        let lut = try CubeLUT.parse(identityText)
        for _ in 0..<CaptureJournal.maximumJobs {
            _ = try journal.stage(recipe: recipe(lut: lut), imageData: Data([1]), movieURL: nil, lut: lut)
        }
        XCTAssertThrowsError(try journal.stage(recipe: recipe(lut: lut), imageData: Data([1]), movieURL: nil, lut: lut))
        XCTAssertEqual(try journal.jobs().count, CaptureJournal.maximumJobs)
    }

    func testJournalRecoversCommitInterruptedBeforeRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CaptureJournal(root: root)
        let lut = try CubeLUT.parse(identityText)
        let recipe = recipe(lut: lut)
        _ = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut)
        try FileManager.default.moveItem(at: journal.directory(for: recipe.id),
            to: root.appendingPathComponent("staging-\(recipe.id.uuidString)"))
        XCTAssertEqual(try journal.recover().map(\.id), [recipe.id])
    }

    func testDiscardedCaptureCannotBeRecoveredOrExported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CaptureJournal(root: root)
        let lut = try CubeLUT.parse(identityText)
        let recipe = recipe(lut: lut)
        _ = try journal.stage(recipe: recipe, imageData: Data([1]), movieURL: nil, lut: lut)
        try journal.markDiscarded(recipe.id)
        XCTAssertTrue(try journal.recover().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.file("original.image", for: recipe.id).path))
    }

    func testUnknownJournalVersionKeepsOriginalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CaptureJournal(root: root)
        let lut = try CubeLUT.parse(identityText)
        let recipe = recipe(lut: lut)
        var job = try journal.stage(recipe: recipe, imageData: Data([1, 2]), movieURL: nil, lut: lut)
        job.formatVersion = 99
        try journal.update(job)
        XCTAssertTrue(try journal.recover().isEmpty)
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: recipe.id)), Data([1, 2]))
    }

    @MainActor
    func testLiveTranscodeKeepsEveryFrameAndPairingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await Task.detached(priority: .utility) { try await Self.makeVideo(at: source) }.value
        let output = root.appendingPathComponent("rendered.mov")
        let lut = try CubeLUT.parse(identityText)
        let result = try await Task.detached(priority: .utility) {
            try await LivePhotoProcessor.process(sourceURL: source, lutCacheKey: "test", capturedLUT: lut,
                grain: .disabled, grainBaseSeed: 1, photoDisplayTime: CMTime(value: 3, timescale: 30), outputURL: output)
        }.value
        let verification = try await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: output)
            let metadata = try await asset.load(.metadata)
            let identifier = try XCTUnwrap(metadata.first { $0.identifier == .quickTimeMetadataContentIdentifier })
            let value = try await identifier.load(.stringValue)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let reader = try AVAssetReader(asset: asset)
            let track = try XCTUnwrap(tracks.first)
            let trackOutput = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(trackOutput)
            XCTAssertTrue(reader.startReading())
            var timestamps: [Double] = []
            while let sample = trackOutput.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sample) != nil {
                    timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
            }
            let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
            return (value, timestamps, reader.status == .completed, metadataTracks.count)
        }.value
        XCTAssertEqual(verification.0, result.contentIdentifier)
        XCTAssertEqual(verification.1.count, 6)
        for (index, time) in verification.1.enumerated() {
            XCTAssertEqual(time, Double(index) / 30, accuracy: 0.001)
        }
        XCTAssertTrue(verification.2)
        XCTAssertEqual(verification.3, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private static func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48
        ])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        for frame in 0..<6 {
            while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(frame * 20), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status, .completed)
    }

    @MainActor
    func testCancellingTranscodePreservesOriginalVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await Task.detached(priority: .utility) { try await Self.makeVideo(at: source) }.value
        let original = try Data(contentsOf: source)
        let lut = try CubeLUT.parse(identityText)
        let task = Task.detached(priority: .utility) {
            try await LivePhotoProcessor.process(sourceURL: source, lutCacheKey: "test", capturedLUT: lut,
                grain: .disabled, grainBaseSeed: 1, photoDisplayTime: .zero,
                outputURL: root.appendingPathComponent("cancelled.mov"))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled transcode must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor
    func testSingleEncodingPreservesPhotoMetadata() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let buffer = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil))
        let originalImage = try XCTUnwrap(image.cgImage)
        let properties: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:10:02 12:34:56",
                kCGImagePropertyExifPixelXDimension as String: originalImage.width,
                kCGImagePropertyExifPixelYDimension as String: originalImage.height
            ]
        ]
        CGImageDestinationAddImage(destination, originalImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let input = buffer as Data
        let lut = try CubeLUT.parse(identityText)
        let output = await Task.detached {
            FilmProcessor.shared.applyLUTPreservingMetadata(imageData: input, lutCacheKey: "test", capturedLUT: lut,
                location: CLLocation(latitude: 31, longitude: 121), focalLengthIn35mm: 50, contentIdentifier: "12345678-1234-1234-1234-123456789ABC")
        }.value
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(output) as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let exif = try XCTUnwrap(metadata[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:10:02 12:34:56")
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int, 50)
        let maker = metadata[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        XCTAssertEqual(maker?["17"] as? String, "12345678-1234-1234-1234-123456789ABC")
        let gps = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude as String] as? Double, 31)
        XCTAssertEqual(metadata[kCGImagePropertyOrientation as String] as? Int, 1)
        XCTAssertEqual(metadata[kCGImagePropertyPixelWidth as String] as? Int, originalImage.height)
        XCTAssertEqual(metadata[kCGImagePropertyPixelHeight as String] as? Int, originalImage.width)
        XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension as String] as? Int, originalImage.height)
        XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension as String] as? Int, originalImage.width)
    }

    @MainActor
    func testSaveIsIdempotentAndKeepsCaptureDate() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Photo.self, CustomLUT.self, configurations: configuration)
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        let id = UUID()
        let date = Date(timeIntervalSince1970: 123456)
        _ = try await saver.save(id: id, captureDate: date, assetLocalIdentifier: nil, imageData: Data([1]),
            filmPresetName: "film", filmDisplayLabel: nil, latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil)
        _ = try await saver.save(id: id, captureDate: date, assetLocalIdentifier: "asset", imageData: nil,
            filmPresetName: "film", filmDisplayLabel: nil, latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil)
        let context = ModelContext(container)
        let photos = try context.fetch(FetchDescriptor<Photo>())
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.id, id)
        XCTAssertEqual(photos.first?.timestamp, date)
        XCTAssertEqual(photos.first?.assetLocalIdentifier, "asset")
        XCTAssertNil(photos.first?.imageData)
    }

    @MainActor
    func testExistingAssetIndexIsUpdatedInsteadOfDuplicated() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Photo.self, CustomLUT.self, configurations: configuration)
        let context = ModelContext(container)
        let original = Photo(assetLocalIdentifier: "existing-asset", imageData: nil)
        context.insert(original)
        try context.save()
        let originalID = original.id
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        let savedID = try await saver.save(id: UUID(), captureDate: Date(timeIntervalSince1970: 123456),
            assetLocalIdentifier: "existing-asset", imageData: nil, filmPresetName: "recovered-film",
            filmDisplayLabel: nil, latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil)
        let photos = try ModelContext(container).fetch(FetchDescriptor<Photo>())
        XCTAssertEqual(savedID, originalID)
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.filmPresetName, "recovered-film")
    }

    func testOpticsKernelUsesSRGBDisplayValues() throws {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let input: [Float] = [0.9, 0.7, 0.3, 1]
        let data = input.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: srgb)
        var parameters = FilmOpticsParameters.disabled
        parameters.headroomAmount = 0.8
        parameters.headroomShoulder = 0.5
        let output = FilmOpticsRenderer.applyingHeadroom(to: image, parameters: parameters)
        let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        var pixels = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixels, rowBytes: 16, bounds: image.extent, format: .RGBAf, colorSpace: srgb)
        let luminance: Float = input[0] * 0.2126 + input[1] * 0.7152 + input[2] * 0.0722
        let t = min(1, max(0, (luminance - 0.5) / 0.5))
        let weight = t * t * (3 - 2 * t) * 0.8
        // headroom = 去饱和（向同亮度暖白）→ 亮度软压腾余量（shoulder 以上向 0.90 渐近），按 weight 渐入。
        // 与 FilmOpticsMath.h 的 justShootApplyHeadroom 逐项对应；任一侧混入 linearization 都会超出容差。
        let warmWhiteR = luminance * 1.000
        let desaturatedR = input[0] + (warmWhiteR - input[0]) * weight
        let ceiling: Float = 0.90
        let range = ceiling - parameters.headroomShoulder
        let compressed = parameters.headroomShoulder
            + range * (1 - exp(-(luminance - parameters.headroomShoulder) / range))
        let withHeadroomR = desaturatedR * (compressed / luminance)
        let expected = desaturatedR + (withHeadroomR - desaturatedR) * weight
        XCTAssertEqual(pixels[0], expected, accuracy: 0.003)
    }

    /// 光晕合成不得硬截断：大面积亮面（64×64 均匀 0.95，模糊后中心能量≈1）加晕后仍收在
    /// 1 以内、且高于底色，而不是被 clamp 成 1.0（回归旧 `clamp(base + halation + bloom, 0, 1)`
    /// 把不同亮度压成同一片白、事后无法恢复层次的问题）。
    func testOpticsCompositePreservesHighlightGradient() throws {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = 64, height = 64
        var bitmap = [Float](repeating: 0, count: width * height * 4)
        for pixel in bitmap.indices where pixel % 4 != 3 { bitmap[pixel] = 0.95 }
        let data = bitmap.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(
            bitmapData: data, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: srgb
        )
        var parameters = FilmOpticsParameters.disabled
        parameters.halationAmount = 0.42
        parameters.halationRadius = 4
        parameters.halationHue = 0.35
        parameters.bloomAmount = 0.30
        parameters.bloomRadius = 8
        let output = FilmOpticsRenderer.applyingLightDiffusion(to: image, parameters: parameters)
        let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(output, toBitmap: &pixels, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: srgb)
        // 取画面中心的像素（远离边界效应）。
        let center = ((height / 2) * width + width / 2) * 4
        // 能量≈1 → 饱和响应 0.632；0.95 + 光晕后 ≈1.18 被软肩收到 ≈0.979。
        XCTAssertLessThan(pixels[center], 0.999, "光晕合成把超限亮度硬截断成 1.0")
        XCTAssertGreaterThan(pixels[center], 0.95, "光晕加亮后应比底色更亮")
        XCTAssertLessThan(pixels[center + 2], pixels[center], "halation 应把红通道抬得比蓝通道高")
    }

    /// 内置 LUT 加载时应用趾部抬升：黑端（输入 0.05 的中性灰）从 ≈0.003 抬到 ≥0.03 的可见区，
    /// 而 0.16 以上的输出（如输入 0.30 ≈ 0.271）保持原样——影调风格不被改动。
    func testBundledLUTAppliesShadowToe() throws {
        let lut = try FilmProcessor.shared.loadCubeLUT(resourceName: "FujiProvia100F")
        let dim = lut.dimension
        func neutralLuma(_ x: Float) -> Float {
            let index = Int(round(x * Float(dim - 1)))
            return lut.data.withUnsafeBytes { raw -> Float in
                let base = (index * dim * dim + index * dim + index) * 4
                let r = raw.load(fromByteOffset: base * 4, as: Float.self)
                let g = raw.load(fromByteOffset: (base + 1) * 4, as: Float.self)
                let b = raw.load(fromByteOffset: (base + 2) * 4, as: Float.self)
                return 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        XCTAssertGreaterThan(neutralLuma(0.05), 0.03, "暗部仍被压进 sRGB 底部不可见区")
        XCTAssertEqual(neutralLuma(0.30), 0.2706, accuracy: 0.01, "趾部保护不应改动 0.16 以上的输出")
    }

    private func recipe(lut: CubeLUT) -> CaptureRecipe {
        CaptureRecipe(id: UUID(), captureDate: Date(timeIntervalSince1970: 123456), filterName: "test",
                      displayLabel: nil, focalLength: 35, outputQuality: 0.8,
                      profile: FilmRenderProfile(grain: .disabled, optics: .disabled), grainSeed: 1,
                      location: nil, lutDimension: lut.dimension, photoDisplayTime: 1.5)
    }
}
