import Foundation
import os

/// Bounded, asynchronous text logs. This store receives diagnostic fields only, never photo data.
final class DiagnosticLogStore: Sendable {
    static let shared = DiagnosticLogStore(root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Diagnostics", isDirectory: true))

    private struct Pending: Sendable {
        var lines: [Data] = []
        var bytes = 0
        var dropped = 0
        var scheduled = false
    }

    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private let queue = DispatchQueue(label: "diagnostics.files", qos: .utility)
    private let writeFailures = OSAllocatedUnfairLock(initialState: 0)
    private let root: URL
    private let maximumFileBytes: Int
    private let maximumPendingBytes: Int
    private let fileCount = 3

    init(root: URL, maximumFileBytes: Int = 2 * 1_024 * 1_024, maximumPendingBytes: Int = 256 * 1_024) {
        self.root = root
        self.maximumFileBytes = max(128, maximumFileBytes)
        self.maximumPendingBytes = max(128, maximumPendingBytes)
    }

    func append(_ line: String) {
        // Keep records single-line and cap even an accidentally oversized field.
        let normalized = line.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let limit = min(8_192, maximumFileBytes - 1)
        var bytes = Data(normalized.utf8.prefix(limit))
        while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        bytes.append(0x0a)
        let record = bytes
        let schedule = pending.withLock { state -> Bool in
            guard state.bytes + record.count <= maximumPendingBytes else { state.dropped += 1; return false }
            state.lines.append(record)
            state.bytes += record.count
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule {
            queue.async {
                do { try self.drain() }
                catch {
                    self.writeFailures.withLock { $0 += 1 }
                    // Never recursively feed a write failure back into the file writer.
                    Log.diagnostics.error("diagnostic_file_write_failed code=\((error as NSError).code)")
                }
            }
        }
    }

    private func drain() throws {
        let batch = pending.withLock { state -> ([Data], Int) in
            let result = (state.lines, state.dropped)
            state = Pending()
            return result
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var lines = batch.0
        if batch.1 > 0 { lines.append(Data("diag event=diagnostic_log_overflow dropped=\(batch.1)\n".utf8)) }
        for line in lines { try write(line) }
    }

    private func file(_ index: Int) -> URL { root.appendingPathComponent("diagnostics-\(index).log") }

    private func write(_ data: Data) throws {
        let manager = FileManager.default
        let current = file(0)
        let size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > maximumFileBytes {
            for index in stride(from: fileCount - 1, through: 1, by: -1) {
                if manager.fileExists(atPath: file(index).path) { try manager.removeItem(at: file(index)) }
                if manager.fileExists(atPath: file(index - 1).path) { try manager.moveItem(at: file(index - 1), to: file(index)) }
            }
        }
        if !manager.fileExists(atPath: current.path) { try Data().write(to: current) }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Enqueued after preceding writes. Drains pending records before reading, off the main actor.
    func snapshot() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.drain()
                    var result = Data("JustShoot diagnostics schema=\(Diagnostics.schemaVersion) retained_files=3 max_file_bytes=\(self.maximumFileBytes) file_write_failures=\(self.writeFailures.withLock { $0 })\n".utf8)
                    for index in stride(from: self.fileCount - 1, through: 0, by: -1) {
                        if FileManager.default.fileExists(atPath: self.file(index).path) {
                            result.append(try Data(contentsOf: self.file(index)))
                        }
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func export() async throws -> URL {
        let data = try await snapshot()
        return try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let directory = manager.temporaryDirectory.appendingPathComponent("DiagnosticExports", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let old = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .sorted { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast >
                    (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
            for url in old.dropFirst(2) { try? manager.removeItem(at: url) }
            let date = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("JustShoot-\(date)-\(UUID().uuidString.prefix(8)).txt")
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }
}
