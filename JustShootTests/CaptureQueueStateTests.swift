import XCTest
@testable import JustShoot

final class CaptureQueueStateTests: XCTestCase {
    func testAReservationAndItsDurableCheckpointOccupyOnlyOneSlot() {
        let id = UUID()
        var queue = CaptureQueueState()
        XCTAssertTrue(queue.reserve(id, bytes: 128, maximumJobs: 1))
        XCTAssertEqual(queue.reservedBytes, 128)
        queue.activate([id])
        XCTAssertEqual(queue.occupiedCount, 1)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.reservedBytes, 0)
        queue.finish(id, retained: true)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.retainedCount, 1)
        queue.finish(id, retained: false)
        XCTAssertEqual(queue.occupiedCount, 0)
    }

    func testRecoveryPreservesUnjournaledReservationsAndDoesNotReactivateRetainedJobs() {
        let reserved = UUID(), retained = UUID(), stale = UUID()
        var queue = CaptureQueueState()
        XCTAssertTrue(queue.reserve(reserved, bytes: 128, maximumJobs: 16))
        queue.synchronize(pendingIDs: [retained, stale], issueIDs: [])
        queue.activate([retained, stale])
        queue.finish(retained, retained: true)
        queue.finish(stale, retained: true)
        queue.synchronize(pendingIDs: [retained], issueIDs: [])
        XCTAssertEqual(queue.activeIDs, [reserved])
        XCTAssertEqual(queue.pendingJobIDs, [retained])
        XCTAssertEqual(queue.retainedCount, 1)
        XCTAssertEqual(queue.occupiedCount, 2)
    }

    func testAnOlderInventoryCannotReleaseANewerActiveCheckpoint() {
        let id = UUID()
        var queue = CaptureQueueState()
        XCTAssertTrue(queue.reserve(id, bytes: 128, maximumJobs: 1))
        queue.activate([id])
        queue.synchronize(pendingIDs: [], issueIDs: [])
        XCTAssertEqual(queue.activeIDs, [id])
        XCTAssertEqual(queue.occupiedCount, 1)
        queue.finish(id, retained: false)
        XCTAssertEqual(queue.occupiedCount, 0)
    }

    func testRecoveryIssuesConsumeCapacityAndAStagingDuplicateDoesNotConsumeAnExtraSlot() {
        let recoverable = UUID(), damaged = UUID()
        var queue = CaptureQueueState()
        queue.synchronize(pendingIDs: [recoverable], issueIDs: [recoverable, damaged])
        XCTAssertEqual(queue.occupiedCount, 2)
        XCTAssertEqual(queue.retainedCount, 1)
        XCTAssertFalse(queue.reserve(UUID(), bytes: 1, maximumJobs: 2))
        queue.remove([damaged])
        XCTAssertTrue(queue.reserve(UUID(), bytes: 1, maximumJobs: 2))
    }

    func testCancellingANativeDeliveryDoesNotDiscardAnAlreadyDurableCheckpoint() {
        let id = UUID()
        var queue = CaptureQueueState()
        XCTAssertTrue(queue.reserve(id, bytes: 128, maximumJobs: 1))
        queue.activate([id])
        queue.cancelReservation(id)
        XCTAssertEqual(queue.pendingJobIDs, [id])
        XCTAssertEqual(queue.retainedCount, 1)
    }

    func testLateAdmissionCannotRecreateADeletedCaptureSlot() {
        let id = UUID()
        var queue = CaptureQueueState()
        queue.synchronize(pendingIDs: [id], issueIDs: [])
        queue.remove([id])
        XCTAssertTrue(queue.activate([id]).isEmpty)
        XCTAssertEqual(queue.occupiedCount, 0)
        XCTAssertTrue(queue.reserve(UUID(), bytes: 128, maximumJobs: 1))
    }

    func testInventoryReadBeforeCompletionCannotResurrectASuccessfullySavedCapture() {
        let id = UUID(), recovered = UUID()
        var queue = CaptureQueueState()
        XCTAssertTrue(queue.reserve(id, bytes: 128, maximumJobs: 1))
        queue.activate([id])
        XCTAssertTrue(queue.synchronize(pendingIDs: [id], issueIDs: [], revision: 10))
        queue.finish(id, retained: false, revision: 11)
        XCTAssertFalse(queue.synchronize(pendingIDs: [id], issueIDs: [], revision: 10))
        XCTAssertEqual(queue.occupiedCount, 0)
        XCTAssertTrue(queue.pendingJobIDs.isEmpty)
        XCTAssertTrue(queue.synchronize(pendingIDs: [recovered], issueIDs: [], revision: 12))
        XCTAssertEqual(queue.pendingJobIDs, [recovered])
        XCTAssertEqual(queue.retainedCount, 1)
    }

    func testOlderInventoriesCannotHideOrReclassifyAFailedOrCancelledCapture() {
        let id = UUID()
        var queue = CaptureQueueState()
        XCTAssertTrue(queue.synchronize(pendingIDs: [], issueIDs: [], revision: 1))
        XCTAssertTrue(queue.reserve(id, bytes: 128, maximumJobs: 1))
        queue.activate([id])
        queue.finish(id, retained: true, revision: 3)
        XCTAssertFalse(queue.synchronize(pendingIDs: [], issueIDs: [], revision: 1))
        XCTAssertFalse(queue.synchronize(pendingIDs: [], issueIDs: [id], revision: 2))
        XCTAssertEqual(queue.pendingJobIDs, [id])
        XCTAssertEqual(queue.retainedCount, 1)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.occupiedCount, 1)
    }
}
