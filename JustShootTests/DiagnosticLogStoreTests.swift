import XCTest
@testable import JustShoot

final class DiagnosticLogStoreTests: XCTestCase {
    func testSnapshotDrainsPendingWritesAndPreservesRecordOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(root: root)
        for index in 0..<100 { store.append("record=\(index)") }
        let text = String(decoding: try await store.snapshot(), as: UTF8.self)
        let records = text.split(separator: "\n").filter { $0.hasPrefix("record=") }
        XCTAssertEqual(records.map(String.init), (0..<100).map { "record=\($0)" })
    }

    func testRotationKeepsThreeBoundedFilesInChronologicalOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(root: root, maximumFileBytes: 128)
        for index in 0..<10 {
            store.append("record=\(index) " + String(repeating: "x", count: 90))
            _ = try await store.snapshot()
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 128) }
        let text = String(decoding: try await store.snapshot(), as: UTF8.self)
        let records = text.split(separator: "\n").filter { $0.hasPrefix("record=") }
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records[0].hasPrefix("record=7"))
        XCTAssertTrue(records[2].hasPrefix("record=9"))
    }

    func testOversizedUnicodeRecordStaysValidAndSingleLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(root: root, maximumFileBytes: 128)
        store.append("prefix\n" + String(repeating: "测试", count: 100))
        _ = try await store.snapshot()
        let data = try Data(contentsOf: root.appendingPathComponent("diagnostics-0.log"))
        XCTAssertLessThanOrEqual(data.count, 128)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
    }

    func testOverflowIsExplicitRatherThanUnbounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(root: root, maximumPendingBytes: 128)
        store.append(String(repeating: "x", count: 256))
        let text = String(decoding: try await store.snapshot(), as: UTF8.self)
        XCTAssertTrue(text.contains("diagnostic_log_overflow dropped=1"))
    }

    func testUnwritableDirectoryDoesNotProduceASuccessfulExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root)
        let store = DiagnosticLogStore(root: root)
        do {
            _ = try await store.snapshot()
            XCTFail("A file in place of the log directory must fail the export")
        } catch { XCTAssertNotNil(error as NSError) }
    }
}
