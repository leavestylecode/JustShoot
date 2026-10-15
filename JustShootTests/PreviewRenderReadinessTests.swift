import XCTest
@testable import JustShoot

final class PreviewRenderReadinessTests: XCTestCase {
    func testOnlyOneConcurrentCompletionCanNotifyTheEntryGate() async throws {
        let gate = PreviewRenderCompletionGate()
        gate.setActive(true)
        let ticket = try XCTUnwrap(gate.ticket(generation: 7, lutKey: "film-a"))
        let notifications = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<30 { group.addTask { gate.complete(ticket) } }
            var count = 0
            for await claimed in group where claimed { count += 1 }
            return count
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertFalse(gate.complete(ticket))
    }

    func testLateCompletionCannotSatisfyANewerFilmOrCameraGeneration() throws {
        let gate = PreviewRenderCompletionGate()
        gate.setActive(true)
        let first = try XCTUnwrap(gate.ticket(generation: 1, lutKey: "film-a"))
        let changedFilm = try XCTUnwrap(gate.ticket(generation: 1, lutKey: "film-b"))
        XCTAssertFalse(gate.complete(first))
        XCTAssertTrue(gate.complete(changedFilm))
        let resumedCamera = try XCTUnwrap(gate.ticket(generation: 2, lutKey: "film-b"))
        XCTAssertFalse(gate.isCurrent(changedFilm))
        XCTAssertFalse(gate.complete(changedFilm))
        XCTAssertTrue(gate.complete(resumedCamera))
    }

    func testPauseInvalidatesBothInFlightAndQueuedNotifications() throws {
        let gate = PreviewRenderCompletionGate()
        XCTAssertNil(gate.ticket(generation: 1, lutKey: "film"))
        gate.setActive(true)
        let old = try XCTUnwrap(gate.ticket(generation: 1, lutKey: "film"))
        XCTAssertTrue(gate.complete(old))
        gate.setActive(false)
        XCTAssertFalse(gate.isCurrent(old))
        XCTAssertNil(gate.ticket(generation: 1, lutKey: "film"))
        gate.setActive(true)
        let fresh = try XCTUnwrap(gate.ticket(generation: 1, lutKey: "film"))
        XCTAssertNotEqual(old, fresh)
        XCTAssertFalse(gate.complete(old))
        XCTAssertTrue(gate.complete(fresh))
    }

    func testRepeatedActiveUpdatesDoNotResetTheOneShotNotification() throws {
        let gate = PreviewRenderCompletionGate()
        gate.setActive(true)
        let first = try XCTUnwrap(gate.ticket(generation: 3, lutKey: "film"))
        XCTAssertTrue(gate.complete(first))
        gate.setActive(true)
        let repeated = try XCTUnwrap(gate.ticket(generation: 3, lutKey: "film"))
        XCTAssertEqual(first, repeated)
        XCTAssertFalse(gate.complete(repeated))
    }

    func testGPUStatisticsAcceptBackgroundCompletionsAndDiscardOldGenerations() async {
        let statistics = PreviewGPUStatistics()
        statistics.reset(generation: 1)
        await Task.detached { statistics.record(generation: 1, milliseconds: 2.5) }.value
        statistics.record(generation: 1, milliseconds: 1.5)
        statistics.record(generation: 1, milliseconds: .nan)
        statistics.record(generation: 1, milliseconds: .infinity)
        XCTAssertEqual(statistics.take(generation: 1), .init(count: 2, totalMS: 4, maximumMS: 2.5))
        XCTAssertEqual(statistics.take(generation: 1), .init())
        statistics.reset(generation: 2)
        statistics.record(generation: 1, milliseconds: 99)
        statistics.record(generation: 2, milliseconds: 3)
        XCTAssertEqual(statistics.take(generation: 1), .init())
        XCTAssertEqual(statistics.take(generation: 2), .init(count: 1, totalMS: 3, maximumMS: 3))
    }

    func testAwaitedMetalPreparationProvidesReusablePipelines() async throws {
        try await PreviewMetalResources.warmUp()
        let resources = PreviewMetalResources.shared
        let device = try XCTUnwrap(resources.device)
        let pipeline = try XCTUnwrap(resources.computePipeline)
        XCTAssertNotNil(resources.finishPipeline)
        try await PreviewMetalResources.warmUp()
        XCTAssertTrue(resources.device === device)
        XCTAssertTrue(resources.computePipeline === pipeline)
    }
}
