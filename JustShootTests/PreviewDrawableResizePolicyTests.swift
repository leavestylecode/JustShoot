import XCTest
@testable import JustShoot

final class PreviewDrawableResizePolicyTests: XCTestCase {
    func testFirstValidSizeIsCommittedWithoutWaitingForTheQuietInterval() {
        var policy = PreviewDrawableResizePolicy()
        XCTAssertNil(policy.request(.zero, at: 0, canRender: true))
        let initial = CGSize(width: 816, height: 1088)
        XCTAssertEqual(policy.request(initial, at: 0, canRender: true), initial)
        XCTAssertNil(policy.nextCommitTime)
    }

    func testThirtyFourAnimationSamplesKeepTheOriginalTargetsAndCommitOnlyTheFinalSize() {
        var policy = PreviewDrawableResizePolicy()
        let initial = CGSize(width: 816, height: 1088)
        _ = policy.request(initial, at: 0, canRender: true)
        var final = initial
        var changedAt = 0.0
        for sample in 1...34 {
            changedAt = Double(sample) * 0.006
            let height = CGFloat(1088 - sample * 3)
            final = CGSize(width: floor(height * 0.75), height: height)
            XCTAssertNil(policy.request(final, at: changedAt, canRender: true))
            XCTAssertEqual(policy.currentSize, initial)
        }
        XCTAssertNil(policy.settle(at: changedAt + 0.099, canRender: true))
        XCTAssertEqual(policy.settle(at: changedAt + 0.101, canRender: true), final)
        XCTAssertEqual(policy.currentSize, final)
        XCTAssertNil(policy.nextCommitTime)
    }

    func testRepeatedLayoutOfTheSamePendingSizeDoesNotPostponeItsCommit() {
        var policy = PreviewDrawableResizePolicy()
        _ = policy.request(CGSize(width: 816, height: 1088), at: 0, canRender: true)
        let final = CGSize(width: 744, height: 992)
        XCTAssertNil(policy.request(final, at: 0.02, canRender: true))
        XCTAssertNil(policy.request(final, at: 0.1, canRender: true))
        XCTAssertEqual(policy.settle(at: 0.121, canRender: true), final)
    }

    func testReturningToTheCurrentSizeCancelsAnUnnecessaryReallocation() {
        var policy = PreviewDrawableResizePolicy()
        let initial = CGSize(width: 816, height: 1088)
        _ = policy.request(initial, at: 0, canRender: true)
        _ = policy.request(CGSize(width: 744, height: 992), at: 0.01, canRender: true)
        XCTAssertNil(policy.request(initial, at: 0.05, canRender: true))
        XCTAssertNil(policy.nextCommitTime)
        XCTAssertNil(policy.settle(at: 1, canRender: true))
    }

    func testRotationAndARealAspectChangeApplyImmediatelyToPreserveTheFieldOfView() {
        var policy = PreviewDrawableResizePolicy()
        _ = policy.request(CGSize(width: 816, height: 1088), at: 0, canRender: true)
        let landscape = CGSize(width: 1088, height: 816)
        XCTAssertEqual(policy.request(landscape, at: 0.01, canRender: true), landscape)
        let wideWindow = CGSize(width: 1088, height: 600)
        XCTAssertEqual(policy.request(wideWindow, at: 0.02, canRender: true), wideWindow)
    }

    func testInactiveLayoutCannotResizeAndReactivationImmediatelyAppliesTheLatestSize() {
        var policy = PreviewDrawableResizePolicy()
        let initial = CGSize(width: 816, height: 1088)
        _ = policy.request(initial, at: 0, canRender: true)
        XCTAssertNil(policy.request(CGSize(width: 768, height: 1024), at: 0.01, canRender: false))
        let latest = CGSize(width: 744, height: 992)
        XCTAssertNil(policy.request(latest, at: 0.02, canRender: false))
        XCTAssertNil(policy.settle(at: 1, canRender: false))
        XCTAssertEqual(policy.currentSize, initial)
        XCTAssertEqual(policy.request(latest, at: 1.01, canRender: true, force: true), latest)
        XCTAssertNil(policy.nextCommitTime)
    }

    func testInvalidGeometryNeverReplacesTheLastDrawable() {
        var policy = PreviewDrawableResizePolicy()
        let initial = CGSize(width: 816, height: 1088)
        _ = policy.request(initial, at: 0, canRender: true)
        XCTAssertNil(policy.request(CGSize(width: CGFloat.infinity, height: 100), at: 1, canRender: true))
        XCTAssertNil(policy.request(CGSize(width: 100, height: -1), at: 1, canRender: true))
        XCTAssertEqual(policy.currentSize, initial)
    }
}
