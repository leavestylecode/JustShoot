import XCTest
@testable import JustShoot

final class PhotoLibraryCompatibilityTests: XCTestCase {
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
