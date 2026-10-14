import Photos
import XCTest
@testable import JustShoot

final class PhotoDeletionPolicyTests: XCTestCase {
    func testLimitedAccessRejectsAnEntireBatchWhenAnyAssetIsInvisible() {
        XCTAssertEqual(PhotoDeletionPolicy.failure(authorization: .limited,
            requestedCount: 2, accessibleCount: 1), .inaccessibleAssets)
        XCTAssertEqual(PhotoDeletionPolicy.failure(authorization: .limited,
            requestedCount: 1, accessibleCount: 0), .inaccessibleAssets)
    }

    func testLimitedAccessCanDeleteACompletelyVisibleBatch() {
        XCTAssertNil(PhotoDeletionPolicy.failure(authorization: .limited,
            requestedCount: 2, accessibleCount: 2))
    }

    func testFullAccessCanRemoveIndexesForAssetsAlreadyDeletedElsewhere() {
        XCTAssertNil(PhotoDeletionPolicy.failure(authorization: .authorized,
            requestedCount: 2, accessibleCount: 0))
    }

    func testRevokedOrUndecidedAccessCannotBeTreatedAsSuccessfulDeletion() {
        for status in [PHAuthorizationStatus.denied, .restricted, .notDetermined] {
            XCTAssertEqual(PhotoDeletionPolicy.failure(authorization: status,
                requestedCount: 1, accessibleCount: 0), .notAuthorized)
        }
    }
}
