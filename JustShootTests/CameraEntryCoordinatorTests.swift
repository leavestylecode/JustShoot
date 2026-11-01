import XCTest
@testable import JustShoot

private actor EntryResourceProbe {
    private var attempts: [CheckedContinuation<Void, any Error>] = []
    private let started: [XCTestExpectation]

    init(started: XCTestExpectation...) { self.started = started }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { continuation in
            attempts.append(continuation)
            started[attempts.count - 1].fulfill()
        }
    }

    func finish(_ index: Int, failing: Bool = false) {
        if failing { attempts[index].resume(throwing: ResourceFailure()) }
        else { attempts[index].resume() }
    }

    private struct ResourceFailure: Error {}
}

@MainActor
final class CameraEntryCoordinatorTests: XCTestCase {
    func testCancelledResourceCompletionCannotReviveEntry() async {
        let started = expectation(description: "resources started")
        let probe = EntryResourceProbe(started: started)
        let coordinator = makeCoordinator(probe: probe)
        coordinator.beginEntryPreparation(generation: 1)
        await fulfillment(of: [started], timeout: 1)
        coordinator.cancelEntryPreparation()
        await probe.finish(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(coordinator.entryPreparation.phase, .inactive)
        XCTAssertFalse(coordinator.entryPreparation.resourcesReady)
    }

    func testSupersededResourceFailureCannotFailNewGeneration() async {
        let firstStarted = expectation(description: "first resource attempt started")
        let secondStarted = expectation(description: "second resource attempt started")
        let ready = expectation(description: "current generation prepared")
        let probe = EntryResourceProbe(started: firstStarted, secondStarted)
        var generation: UInt64 = 1
        let coordinator = makeCoordinator(probe: probe, isCurrent: { $0 == generation }) {
            if $0.generation == 2 && $0.resourcesReady { ready.fulfill() }
        }
        coordinator.beginEntryPreparation(generation: 1)
        await fulfillment(of: [firstStarted], timeout: 1)
        generation = 2
        coordinator.beginEntryPreparation(generation: 2)
        await fulfillment(of: [secondStarted], timeout: 1)
        await probe.finish(0, failing: true)
        await probe.finish(1)
        await fulfillment(of: [ready], timeout: 1)
        XCTAssertEqual(coordinator.entryPreparation.generation, 2)
        XCTAssertNil(coordinator.entryPreparation.failure)
        XCTAssertTrue(coordinator.entryPreparation.resourcesReady)
        coordinator.cancelEntryPreparation()
    }

    func testResourceFailureIsRecoverableWithFreshAttempt() async {
        let started = expectation(description: "resources started")
        let failed = expectation(description: "resource failure published")
        let probe = EntryResourceProbe(started: started)
        let coordinator = makeCoordinator(probe: probe, stateChanged: {
            if $0.failure == .previewUnavailable { failed.fulfill() }
        })
        coordinator.beginEntryPreparation(generation: 1)
        await fulfillment(of: [started], timeout: 1)
        await probe.finish(0, failing: true)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(coordinator.entryPreparation.failure, .previewUnavailable)
        coordinator.cancelEntryPreparation()
        coordinator.resetFailures()
        coordinator.beginEntryPreparation(generation: 2)
        XCTAssertEqual(coordinator.entryPreparation.phase, .preparing)
        coordinator.cancelEntryPreparation()
    }

    private func makeCoordinator(probe: EntryResourceProbe,
                                 isCurrent: @escaping (UInt64) -> Bool = { _ in true },
                                 stateChanged: @escaping (CameraEntryPreparation) -> Void = { _ in }) -> CameraEntryCoordinator {
        CameraEntryCoordinator(diagnostics: DiagnosticTrace(id: "entry-coordinator-test"),
            isCurrentGeneration: isCurrent, readinessSnapshot: { .init() }, stateChanged: stateChanged,
            prepareResources: { try await probe.prepare() })
    }
}
