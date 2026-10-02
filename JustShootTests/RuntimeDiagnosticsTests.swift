import XCTest
@testable import JustShoot

final class RuntimeDiagnosticsTests: XCTestCase {
    func testResponsiveMainQueueDoesNotReportStall() throws {
        var probe = MainQueueProbe()
        let token = try XCTUnwrap(probe.tick(at: 0).probe)
        let acknowledgement = probe.acknowledge(token, at: 0.02)
        XCTAssertNil(acknowledgement.delay)
        XCTAssertNil(acknowledgement.gap)
        XCTAssertNil(probe.pendingSince)
    }

    func testStallHasOnlyOneOutstandingProbeAndRateLimitedReports() throws {
        var probe = MainQueueProbe()
        let token = try XCTUnwrap(probe.tick(at: 0).probe)
        let stalled = probe.tick(at: 0.3)
        XCTAssertNil(stalled.probe)
        XCTAssertEqual(stalled.stall, 0.3)
        XCTAssertNil(probe.tick(at: 0.8).stall)
        XCTAssertNil(probe.tick(at: 1.4).stall)
        XCTAssertNil(probe.tick(at: 2).stall)
        XCTAssertNotNil(probe.tick(at: 2.31).stall)
        XCTAssertEqual(probe.acknowledge(token, at: 2.4).delay, 2.4)
        XCTAssertNotNil(probe.tick(at: 2.5).probe)
    }

    func testBackgroundResetRejectsAnOldAcknowledgement() throws {
        var probe = MainQueueProbe()
        let old = try XCTUnwrap(probe.tick(at: 0).probe)
        probe.reset()
        let current = try XCTUnwrap(probe.tick(at: 10).probe)
        XCTAssertNotEqual(old, current)
        XCTAssertNil(probe.acknowledge(old, at: 10.01).delay)
        XCTAssertEqual(probe.pendingSince, 10)
        XCTAssertNil(probe.acknowledge(current, at: 10.02).delay)
    }

    func testSuspendedWatchdogDoesNotBlameTheMainQueue() throws {
        var probe = MainQueueProbe()
        let token = try XCTUnwrap(probe.tick(at: 0).probe)
        let result = probe.tick(at: 5)
        XCTAssertEqual(result.gap, 5)
        XCTAssertNil(result.stall)
        XCTAssertNil(probe.acknowledge(token, at: 5.01).delay)
    }

    func testAcknowledgementAfterDebuggerPauseReportsGap() throws {
        var probe = MainQueueProbe()
        let token = try XCTUnwrap(probe.tick(at: 0).probe)
        let result = probe.acknowledge(token, at: 5)
        XCTAssertNil(result.delay)
        XCTAssertEqual(result.gap, 5)
    }

    func testCaptureCorrelationPreservesItsOriginalClockAcrossStages() {
        let id = UUID().uuidString
        let shutter = DiagnosticTrace(id: id)
        let processing = DiagnosticTrace(id: id)
        XCTAssertEqual(shutter.id, processing.id)
        XCTAssertEqual(shutter.startedAt, processing.startedAt)
    }

    func testInstrumentationPreservesReturnValuesAndErrors() throws {
        enum TestError: Error { case expected }
        let trace = DiagnosticTrace()
        XCTAssertEqual(trace.measure("test_value") { 42 }, 42)
        XCTAssertThrowsError(try trace.measure("test_error") { throw TestError.expected }) { error in
            XCTAssertTrue(error is TestError)
        }
    }
}
