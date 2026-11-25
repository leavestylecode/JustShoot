import XCTest
@testable import JustShoot

final class PhotoLibraryCompatibilityTests: XCTestCase {
    func testCameraNumberWidensWithoutReusingEarlierNames() {
        XCTAssertEqual(CaptureFilename.stem(number: 1), "OOO_0001")
        XCTAssertEqual(CaptureFilename.stem(number: 9999), "OOO_9999")
        XCTAssertEqual(CaptureFilename.stem(number: 10000), "OOO_10000")
        XCTAssertNil(PhotoLibrary.captureIdentifier(in: ["OOO_0001.HEIC"]))
    }

    func testSharingPreservesTheOriginalStemAndDisambiguatesDuplicateNames() throws {
        let dir = try ShareExportDirectory.application.create()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID(), date = Date()
        let stem = PhotoShareExporter.shareStem(filename: "OOO_0042.HEIC", captureDate: date, photoID: id)
        let first = try PhotoShareExporter.writeJPEG(Data([1]), stem: stem, into: dir)
        let second = try PhotoShareExporter.writeJPEG(Data([2]), stem: stem, into: dir)
        XCTAssertEqual(first.lastPathComponent, "OOO_0042.JPG")
        XCTAssertEqual(second.lastPathComponent, "OOO_0042 (2).JPG")
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
        let fallback = PhotoShareExporter.shareStem(filename: nil, captureDate: date, photoID: id)
        XCTAssertEqual(PhotoShareExporter.shareStem(filename: "../escape.heic", captureDate: date, photoID: id), fallback)
    }

    func testCaptureRecoveryRecognizesBothFilenamePrefixes() {
        let id = UUID()

        XCTAssertEqual(PhotoLibrary.captureIdentifier(in: ["JustShoot_\(id.uuidString).jpg"]), id)
        XCTAssertEqual(PhotoLibrary.captureIdentifier(in: ["OOO_\(id.uuidString).heic"]), id)
    }

    func testCaptureRecoveryContinuesAfterMalformedResourceName() {
        let id = UUID()
        let filenames = ["OOO_incomplete.heic", "IMG_0001.jpg", "JustShoot_\(id.uuidString).heic"]

        XCTAssertEqual(PhotoLibrary.captureIdentifier(in: filenames), id)
    }

    func testCaptureRecoveryRejectsUnrecognizedOrInvalidResourceNames() {
        let filenames = ["IMG_\(UUID().uuidString).jpg", "JustShoot_invalid.heic", "OOO_.jpg"]

        XCTAssertNil(PhotoLibrary.captureIdentifier(in: filenames))
    }
}
