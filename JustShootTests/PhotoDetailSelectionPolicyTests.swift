import XCTest
@testable import JustShoot

final class PhotoDetailSelectionPolicyTests: XCTestCase {
    func testDeletingCurrentPhotoKeepsNearestSurvivingNeighbour() {
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertEqual(PhotoDetailSelectionPolicy.selection(current: ids[2], previousIDs: ids,
            remainingIDs: [ids[0], ids[1], ids[4]]), ids[4])
        XCTAssertEqual(PhotoDetailSelectionPolicy.selection(current: ids[4], previousIDs: ids,
            remainingIDs: [ids[0], ids[2]]), ids[2])
    }

    func testDeletingAnotherPhotoPreservesSelectionChangedDuringConfirmation() {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(PhotoDetailSelectionPolicy.selection(current: ids[3], previousIDs: ids,
            remainingIDs: [ids[0], ids[2], ids[3]]), ids[3])
    }

    func testReorderPreservesSelectedIdentity() {
        let ids = (0..<3).map { _ in UUID() }
        XCTAssertEqual(PhotoDetailSelectionPolicy.selection(current: ids[1], previousIDs: ids,
            remainingIDs: ids.reversed()), ids[1])
    }

    func testRemovingLastPhotoClosesInsteadOfSelectingMissingPhoto() {
        let id = UUID()
        XCTAssertNil(PhotoDetailSelectionPolicy.selection(current: id, previousIDs: [id], remainingIDs: []))
    }

    func testUnknownSelectionRecoversToAnAvailablePhoto() {
        let id = UUID()
        XCTAssertEqual(PhotoDetailSelectionPolicy.selection(current: nil, previousIDs: [], remainingIDs: [id]), id)
        XCTAssertEqual(PhotoDetailSelectionPolicy.selection(current: UUID(), previousIDs: [], remainingIDs: [id]), id)
    }
}
