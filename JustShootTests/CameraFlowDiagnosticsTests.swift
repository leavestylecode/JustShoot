import XCTest
@testable import JustShoot

final class CameraFlowDiagnosticsTests: XCTestCase {
    func testFrameGapAcrossWindowsIsNotHidden() {
        var cadence = DiagnosticCadence()
        cadence.record(at: 10)
        cadence.record(at: 10.02)
        cadence.resetWindow()
        cadence.record(at: 10.3)
        XCTAssertEqual(cadence.count, 1)
        XCTAssertEqual(cadence.maximumGap, 0.28, accuracy: 0.0001)
    }

    func testInvalidAndOutOfOrderPresentationTimesDoNotCorruptCadence() {
        var cadence = DiagnosticCadence()
        cadence.record(at: 5)
        cadence.record(at: .nan)
        cadence.record(at: 4)
        cadence.record(at: 5.1)
        XCTAssertEqual(cadence.count, 2)
        XCTAssertEqual(cadence.maximumGap, 0.1, accuracy: 0.0001)
    }

    func testLateGPUCallbacksCannotBeAttributedToANewFocalRequest() async throws {
        let trace = DiagnosticTrace()
        let flow = CameraFlowDiagnostics(trace: trace)
        flow.reset(generation: 1)
        flow.beginFocal(1)
        let old = flow.submitted(at: 1, capturedAt: 0.9)
        flow.beginFocal(2)
        flow.completed(old, gpuMS: 500, elapsedMS: 600, failed: true)
        flow.flush(reason: "test_stale", force: true)
        let text = String(decoding: try await DiagnosticLogStore.shared.snapshot(), as: UTF8.self)
        let line = try XCTUnwrap(text.split(separator: "\n").last { $0.contains("id=\(trace.id) ") && $0.contains("reason=test_stale") })
        XCTAssertTrue(line.contains("focal_seq=2"))
        XCTAssertTrue(line.contains("stale_callbacks=1"))
        XCTAssertTrue(line.contains("gpu_n=0"))
        XCTAssertTrue(line.contains("gpu_errors=0"))
    }

    func testZoomHistoryIsBoundedAndKeepsTheLatestSample() async throws {
        let trace = DiagnosticTrace()
        let flow = CameraFlowDiagnostics(trace: trace)
        for index in 1...500 { flow.zoom(Double(index), ramping: index < 500) }
        flow.flush(reason: "test_zoom", force: true)
        let text = String(decoding: try await DiagnosticLogStore.shared.snapshot(), as: UTF8.self)
        let line = try XCTUnwrap(text.split(separator: "\n").last { $0.contains("id=\(trace.id) ") && $0.contains("reason=test_zoom") })
        XCTAssertTrue(line.contains("zoom_n=500"))
        let samples = try XCTUnwrap(line.components(separatedBy: "zoom_samples=[").last).dropLast()
        XCTAssertEqual(samples.split(separator: ",").count, 24)
        XCTAssertTrue(samples.hasSuffix(":500.000:0"))
    }
}
