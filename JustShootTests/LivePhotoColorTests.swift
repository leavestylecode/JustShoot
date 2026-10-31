import XCTest
import AVFoundation
import CoreVideo
import CoreMedia
@testable import JustShoot

final class LivePhotoColorTests: XCTestCase {
    @MainActor
    func testProcessedLivePhotoCarriesSRGBColorTags() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Live capture requires iOS 18 sRGB video writing") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        let output = root.appendingPathComponent("graded.mov")
        let tags = try await Task.detached {
            try await CapturePipelineTests.makeVideo(at: source)
            let text = "LUT_3D_SIZE 2\n" + (0...1).flatMap { blue in
                (0...1).flatMap { green in (0...1).map { red in "\(red) \(green) \(blue)" } }
            }.joined(separator: "\n")
            _ = try await LivePhotoProcessor.process(sourceURL: source, lutCacheKey: "identity",
                capturedLUT: CubeLUT.parse(text), grain: .disabled, grainBaseSeed: 1,
                photoDisplayTime: CMTime(value: 3, timescale: 30), outputURL: output)
            return try await Self.colorTags(at: output)
        }.value
        assertSRGB(tags)
    }

    @MainActor
    func testH264WriterPreservesDeclaredSRGBTransferFunction() async throws {
        try await verifyWriter(codec: .h264)
    }

    @MainActor
    func testHEVCWriterPreservesDeclaredSRGBTransferFunction() async throws {
        try await verifyWriter(codec: .hevc)
    }

    @MainActor
    private func verifyWriter(codec: AVVideoCodecType) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let tags = try await Task.detached {
            try await Self.makeTaggedVideo(at: url, codec: codec)
            return try await Self.colorTags(at: url)
        }.value
        assertSRGB(tags)
    }

    private func assertSRGB(_ tags: (String?, String?, String?), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tags.0, kCVImageBufferColorPrimaries_ITU_R_709_2 as String, file: file, line: line)
        XCTAssertEqual(tags.1, kCVImageBufferTransferFunction_sRGB as String, file: file, line: line)
        XCTAssertEqual(tags.2, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, file: file, line: line)
    }

    private static func colorTags(at url: URL) async throws -> (String?, String?, String?) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(descriptions.first)
        return (
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        )
    }

    /// Exercise both encoders with the same buffer tags and writer properties as production.
    private static func makeTaggedVideo(at url: URL, codec: AVVideoCodecType) async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("sRGB video writing requires iOS 18") }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: 64,
            AVVideoHeightKey: 48, AVVideoColorPropertiesKey: FilmVideoColorSpace.writerProperties]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw XCTSkip("\(codec.rawValue) encoding with sRGB tags is unavailable on this destination")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for row in 0..<48 {
            for column in 0..<64 {
                let offset = row * stride + column * 4
                bytes[offset] = 128
                bytes[offset + 1] = 128
                bytes[offset + 2] = 128
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        FilmVideoColorSpace.tag(pixel)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData else { throw FixtureError.encoderNotReady }
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw FixtureError.appendFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private enum FixtureError: Error {
        case encoderNotReady
        case appendFailed
    }
}
