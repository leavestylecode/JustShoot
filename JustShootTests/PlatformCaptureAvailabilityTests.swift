import XCTest
@testable import JustShoot

final class PlatformCaptureAvailabilityTests: XCTestCase {
    func testLiveAvailabilityMatchesItsEncoderAndWriterRequirements() {
        if #available(iOS 18.0, *) {
            XCTAssertTrue(LivePhotoEncoderConfiguration.isSupported)
            XCTAssertNotNil(LivePhotoEncoderConfiguration.specification)
        } else {
            XCTAssertFalse(LivePhotoEncoderConfiguration.isSupported)
            XCTAssertNil(LivePhotoEncoderConfiguration.specification)
        }
    }

    func testOlderSystemsRejectLiveTranscodeWithoutDeletingTheCheckpoint() async throws {
        guard !LivePhotoEncoderConfiguration.isSupported else { return }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = source.appendingPathExtension("mov")
        let bytes = Data("checkpoint".utf8)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        do {
            _ = try await LivePhotoProcessor.process(sourceURL: source, lutCacheKey: "unused", grain: .disabled,
                grainBaseSeed: 0, photoDisplayTime: .zero, outputURL: output)
            XCTFail("Unsupported Live processing must fail before touching the source")
        } catch LivePhotoProcessor.ProcessError.unsupportedSystem { }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
