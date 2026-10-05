import XCTest
import Photos
import UIKit
@testable import JustShoot

final class PhotoImageRequestStateTests: XCTestCase {
    @MainActor
    func testSuccessfulImageIsDeliveredAndLateCancellationCannotReplaceIt() async {
        let state = PhotoImageRequestState()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let result = await withCheckedContinuation { continuation in
            XCTAssertTrue(state.install(continuation))
            XCTAssertFalse(state.register(42))
            XCTAssertTrue(state.finish(image))
            XCTAssertFalse(state.cancel().didFinish)
            XCTAssertFalse(state.finish(nil))
        }
        XCTAssertTrue(result === image)
    }

    func testCancellationBeforeContinuationInstallationDoesNotHang() async {
        let state = PhotoImageRequestState()
        XCTAssertTrue(state.cancel().didFinish)
        let result = await withCheckedContinuation { continuation in
            XCTAssertFalse(state.install(continuation))
        }
        XCTAssertNil(result)
        XCTAssertTrue(state.register(42))
    }

    func testCancellationBeforeRequestIDCancelsTheLateIDAndIgnoresCallback() async {
        let state = PhotoImageRequestState()
        let result = await withCheckedContinuation { continuation in
            XCTAssertTrue(state.install(continuation))
            let cancellation = state.cancel()
            XCTAssertTrue(cancellation.didFinish)
            XCTAssertEqual(cancellation.requestID, PHInvalidImageRequestID)
            XCTAssertTrue(state.register(42))
            XCTAssertFalse(state.finish(nil))
        }
        XCTAssertNil(result)
    }

    func testSynchronousCompletionBeforeRequestIDOnlyResumesOnce() async {
        let state = PhotoImageRequestState()
        let result = await withCheckedContinuation { continuation in
            XCTAssertTrue(state.install(continuation))
            XCTAssertTrue(state.finish(nil))
            XCTAssertFalse(state.register(42))
            XCTAssertFalse(state.finish(nil))
            XCTAssertFalse(state.cancel().didFinish)
        }
        XCTAssertNil(result)
    }

    func testCancellationOfRegisteredRequestReturnsItsIDExactlyOnce() async {
        let state = PhotoImageRequestState()
        let result = await withCheckedContinuation { continuation in
            XCTAssertTrue(state.install(continuation))
            XCTAssertFalse(state.register(42))
            XCTAssertEqual(state.cancel().requestID, 42)
            XCTAssertFalse(state.cancel().didFinish)
            XCTAssertFalse(state.finish(nil))
        }
        XCTAssertNil(result)
    }
}
