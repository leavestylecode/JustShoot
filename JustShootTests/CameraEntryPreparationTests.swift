import XCTest
@testable import JustShoot

final class CameraEntryPreparationTests: XCTestCase {
    private func preparing(generation: UInt64 = 1, key: String = "film") -> CameraEntryPreparation {
        var entry = CameraEntryPreparation()
        entry.updateLUT(expectedKey: key, preparedKey: key)
        entry.begin(generation: generation)
        return entry
    }

    private func finishSessionWork(_ entry: inout CameraEntryPreparation, generation: UInt64 = 1) {
        entry.preparedDevice(generation: generation, completedAt: 10)
        entry.preparedResources(generation: generation)
        entry.preparedPhotoTemplate(generation: generation)
        entry.preparedAudio(generation: generation)
        entry.updateReadiness(generation: generation, session: true, preview: true, capture: true, pipeline: true)
    }

    func testSessionAndLUTReadinessCannotRevealBeforeSuccessfulGPUCompletion() {
        var entry = preparing()
        finishSessionWork(&entry)
        XCTAssertTrue(entry.coversContent)
        entry.rendered(generation: 0, lutKey: "film", capturedAt: 11)
        entry.rendered(generation: 1, lutKey: "another-film", capturedAt: 11)
        XCTAssertTrue(entry.isPreparing)
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        XCTAssertTrue(entry.isRevealed)
        XCTAssertFalse(entry.coversContent)
    }

    func testNativeReadinessRevealsImmediatelyAfterTheCurrentFrameWithoutAnotherTimer() {
        var entry = preparing()
        finishSessionWork(&entry)
        entry.updateReadiness(generation: 1, session: true, preview: false, capture: true, pipeline: true)
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 10.01)
        XCTAssertTrue(entry.isPreparing)
        entry.updateReadiness(generation: 1, session: true, preview: true, capture: false, pipeline: true)
        XCTAssertTrue(entry.isPreparing)
        entry.updateReadiness(generation: 1, session: true, preview: true, capture: true, pipeline: true)
        XCTAssertTrue(entry.isRevealed)
    }

    func testDeviceWarmupCannotUseAnOlderGPUFrameToUnlockEntry() {
        var entry = preparing()
        entry.preparedResources(generation: 1)
        entry.preparedPhotoTemplate(generation: 1)
        entry.preparedAudio(generation: 1)
        entry.updateReadiness(generation: 1, session: true, preview: true, capture: true, pipeline: true)
        XCTAssertFalse(entry.needsRender(generation: 1, lutKey: "film", capturedAt: 11))
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        entry.preparedDevice(generation: 1, completedAt: 12)
        XCTAssertTrue(entry.isPreparing)
        XCTAssertFalse(entry.needsRender(generation: 1, lutKey: "film", capturedAt: 11))
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        XCTAssertTrue(entry.isPreparing)
        XCTAssertTrue(entry.needsRender(generation: 1, lutKey: "film", capturedAt: 12.01))
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 12.01)
        XCTAssertTrue(entry.isRevealed)
    }

    func testOldDeviceWarmupAndOldFramesCannotCompleteAResumedEntry() {
        var entry = preparing()
        finishSessionWork(&entry)
        entry.cancel()
        entry.begin(generation: 2)
        finishSessionWork(&entry, generation: 2)
        entry.preparedDevice(generation: 2, completedAt: 30)
        entry.preparedDevice(generation: 1, completedAt: 35)
        XCTAssertEqual(entry.deviceWarmupCompletedAt, 30)
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 31)
        entry.rendered(generation: 2, lutKey: "film", capturedAt: 29)
        XCTAssertTrue(entry.isPreparing)
        entry.rendered(generation: 2, lutKey: "film", capturedAt: 31)
        XCTAssertTrue(entry.isRevealed)
    }

    func testCurrentStyleGPUCanArriveBeforeItsPreparedKeyPublication() {
        var entry = preparing()
        finishSessionWork(&entry)
        entry.updateLUT(expectedKey: "edited-curve", preparedKey: "film")
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        XCTAssertTrue(entry.isPreparing)
        entry.rendered(generation: 1, lutKey: "edited-curve", capturedAt: 11)
        XCTAssertTrue(entry.isPreparing)
        entry.updateLUT(expectedKey: "edited-curve", preparedKey: "edited-curve")
        XCTAssertTrue(entry.isRevealed)
    }

    func testCurrentAudioAndNativePhotoConfigurationMustComplete() {
        var entry = preparing()
        entry.preparedResources(generation: 1)
        entry.preparedDevice(generation: 1, completedAt: 10)
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        entry.updateReadiness(generation: 1, session: true, preview: true, capture: true, pipeline: true)
        XCTAssertTrue(entry.isPreparing)
        entry.preparedPhotoTemplate(generation: 1)
        XCTAssertTrue(entry.isPreparing)
        entry.preparedAudio(generation: 1)
        XCTAssertTrue(entry.isRevealed)
    }

    func testCapturePipelineAndNativeWarmupAreIndependentRequiredWork() {
        var entry = preparing()
        entry.preparedDevice(generation: 1, completedAt: 10)
        entry.preparedPhotoTemplate(generation: 1)
        entry.preparedAudio(generation: 1)
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        entry.updateReadiness(generation: 1, session: true, preview: true, capture: true, pipeline: false)
        XCTAssertTrue(entry.isPreparing)
        entry.preparedResources(generation: 1)
        XCTAssertTrue(entry.isPreparing)
        entry.updateReadiness(generation: 1, session: true, preview: true, capture: true, pipeline: true)
        XCTAssertTrue(entry.isRevealed)
    }

    func testNormalFilterAndFocalChangesDoNotShowTheEntryCoverAgain() {
        var entry = preparing()
        finishSessionWork(&entry)
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        entry.updateLUT(expectedKey: "new-film", preparedKey: "film")
        entry.updateReadiness(generation: 1, session: true, preview: true, capture: false, pipeline: true)
        XCTAssertTrue(entry.isRevealed)
        XCTAssertFalse(entry.coversContent)
    }

    func testResumeRequiresFreshGenerationWorkAndRejectsLateBackgroundCompletion() {
        var entry = preparing()
        finishSessionWork(&entry)
        entry.cancel()
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        XCTAssertEqual(entry.phase, .inactive)
        entry.begin(generation: 3)
        finishSessionWork(&entry, generation: 3)
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        XCTAssertTrue(entry.isPreparing)
        entry.rendered(generation: 3, lutKey: "film", capturedAt: 11)
        XCTAssertTrue(entry.isRevealed)
    }

    func testFailureCannotBeOverwrittenByLateReadyCallbacksAndRetryStartsFresh() {
        var entry = preparing()
        finishSessionWork(&entry)
        entry.fail(.timedOut, generation: 1)
        entry.rendered(generation: 1, lutKey: "film", capturedAt: 11)
        finishSessionWork(&entry)
        XCTAssertEqual(entry.failure, .timedOut)
        XCTAssertTrue(entry.coversContent)
        entry.begin(generation: 2)
        entry.fail(.previewUnavailable, generation: 1)
        XCTAssertNil(entry.failure)
        finishSessionWork(&entry, generation: 2)
        entry.rendered(generation: 2, lutKey: "film", capturedAt: 11)
        XCTAssertTrue(entry.isRevealed)
    }

    func testPermissionSheetsAndInactiveTimeDoNotConsumeTheActiveTimeoutBudget() {
        var timer = CameraEntryPreparation.ActiveTimer()
        timer.reset(at: 0, counting: true)
        timer.update(at: 2, counting: false) // permission prompt begins
        timer.update(at: 200, counting: false)
        XCTAssertEqual(timer.elapsed, 2)
        timer.update(at: 201, counting: true)
        timer.update(at: 204, counting: true)
        XCTAssertEqual(timer.elapsed, 5)
        timer.update(at: 205, counting: false) // scene becomes inactive
        timer.update(at: 400, counting: true)
        timer.update(at: 401, counting: true)
        XCTAssertEqual(timer.elapsed, 7)
        timer.reset(at: 500, counting: true)
        XCTAssertEqual(timer.elapsed, 0)
    }
}
