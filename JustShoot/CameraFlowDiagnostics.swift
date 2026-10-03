import Foundation
import os

/// Counts events and gaps, including gaps crossing a reporting boundary. No per-frame strings.
struct DiagnosticCadence: Sendable {
    private(set) var count = 0
    private(set) var lastTime: TimeInterval?
    private(set) var maximumGap: TimeInterval = 0

    mutating func record(at time: TimeInterval) {
        guard time.isFinite else { return }
        if let lastTime {
            guard time >= lastTime else { return }
            maximumGap = max(maximumGap, time - lastTime)
        }
        lastTime = time
        count += 1
    }

    mutating func resetWindow() {
        count = 0
        maximumGap = 0
    }

    func fields(_ prefix: String, at now: TimeInterval) -> String {
        let age = lastTime.map { max(0, now - $0) * 1_000 } ?? -1
        return "\(prefix)_n=\(count) \(prefix)_gap_ms=\(String(format: "%.1f", maximumGap * 1_000)) \(prefix)_age_ms=\(String(format: "%.1f", age))"
    }
}

/// A constant-sized window shared by capture, GPU completion and presentation callbacks.
/// Reporting runs on the existing watchdog; instrumentation never schedules a task per frame.
final class CameraFlowDiagnostics: Sendable {
    struct Stamp: Equatable, Sendable {
        let generation: UInt64
        let focal: UInt64
    }

    enum Skip: String, Sendable {
        case noFrame = "no_frame", duplicate, backpressure, drawable, pipeline, texture, lut, encoder
    }

    private struct Window: Sendable {
        var startedAt = ProcessInfo.processInfo.systemUptime
        var capture = DiagnosticCadence()
        var pts = DiagnosticCadence()
        var submitted = DiagnosticCadence()
        var presented = DiagnosticCadence()
        var skips: [Skip: Int] = [:]
        var captureDrops = 0
        var dropReason = "none"
        var inputWidth = 0
        var inputHeight = 0
        var dimensionChanges = 0
        var gpuCount = 0
        var gpuMaxMS = 0.0
        var gpuErrorCount = 0
        var completionMaxMS = 0.0
        var recycleWaitMaxMS = 0.0
        var cpuMaxMS = 0.0
        var drawableWaitMaxMS = 0.0
        var frameAgeMaxMS = 0.0
        var presentLatencyMaxMS = 0.0
        var unconfirmedPresentations = 0
        var staleCallbacks = 0
        var targetAllocations = 0
        var zoomCount = 0
        var zoomSamples: [(time: TimeInterval, value: Double, ramping: Bool)] = []

        mutating func reset(at now: TimeInterval) {
            var next = Window()
            next.startedAt = now
            next.capture = capture; next.capture.resetWindow()
            next.pts = pts; next.pts.resetWindow()
            next.submitted = submitted; next.submitted.resetWindow()
            next.presented = presented; next.presented.resetWindow()
            next.inputWidth = inputWidth; next.inputHeight = inputHeight
            self = next
        }
    }

    private struct State: Sendable {
        var stamp = Stamp(generation: 0, focal: 0)
        var window = Window()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let trace: DiagnosticTrace

    init(trace: DiagnosticTrace) { self.trace = trace }

    var stamp: Stamp { state.withLock { $0.stamp } }

    func reset(generation: UInt64) {
        guard Diagnostics.enabled else { return }
        flush(reason: "cycle_end", force: true)
        state.withLock { $0 = State(stamp: Stamp(generation: generation, focal: 0)) }
    }

    func beginFocal(_ focal: UInt64) {
        guard Diagnostics.enabled else { return }
        flush(reason: "before_focal", force: true)
        state.withLock { $0.stamp = Stamp(generation: $0.stamp.generation, focal: focal) }
    }

    func capture(at now: TimeInterval, pts: TimeInterval, width: Int, height: Int) {
        guard Diagnostics.enabled else { return }
        state.withLock {
            $0.window.capture.record(at: now)
            $0.window.pts.record(at: pts)
            if $0.window.inputWidth != 0, ($0.window.inputWidth != width || $0.window.inputHeight != height) {
                $0.window.dimensionChanges += 1
            }
            $0.window.inputWidth = width; $0.window.inputHeight = height
        }
    }

    func captureDropped(reason: String) {
        guard Diagnostics.enabled else { return }
        state.withLock { $0.window.captureDrops += 1; $0.window.dropReason = reason }
    }

    func zoom(_ value: Double, ramping: Bool) {
        guard Diagnostics.enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock {
            $0.window.zoomCount += 1
            let sample = (time: now, value: value, ramping: ramping)
            // Preserve the first 23 observations plus the latest; disclose the total count.
            if $0.window.zoomSamples.count < 24 { $0.window.zoomSamples.append(sample) }
            else { $0.window.zoomSamples[23] = sample }
        }
    }

    func skipped(_ reason: Skip) {
        guard Diagnostics.enabled else { return }
        state.withLock { $0.window.skips[reason, default: 0] += 1 }
    }

    func allocatedTargets() {
        guard Diagnostics.enabled else { return }
        state.withLock { $0.window.targetAllocations += 1 }
    }

    func encoded(cpuMS: Double, drawableWaitMS: Double) {
        guard Diagnostics.enabled else { return }
        state.withLock {
            $0.window.cpuMaxMS = max($0.window.cpuMaxMS, cpuMS)
            $0.window.drawableWaitMaxMS = max($0.window.drawableWaitMaxMS, drawableWaitMS)
        }
    }

    func submitted(at now: TimeInterval, capturedAt: TimeInterval) -> Stamp {
        state.withLock {
            if Diagnostics.enabled {
                $0.window.submitted.record(at: now)
                $0.window.frameAgeMaxMS = max($0.window.frameAgeMaxMS, max(0, now - capturedAt) * 1_000)
            }
            return $0.stamp
        }
    }

    func completed(_ stamp: Stamp, gpuMS: Double, elapsedMS: Double, failed: Bool) {
        guard Diagnostics.enabled else { return }
        state.withLock {
            guard $0.stamp == stamp else { $0.window.staleCallbacks += 1; return }
            $0.window.gpuCount += 1
            $0.window.gpuMaxMS = max($0.window.gpuMaxMS, gpuMS)
            $0.window.completionMaxMS = max($0.window.completionMaxMS, elapsedMS)
            if failed { $0.window.gpuErrorCount += 1 }
        }
    }

    func recycled(_ stamp: Stamp, waitMS: Double) {
        guard Diagnostics.enabled else { return }
        state.withLock {
            guard $0.stamp == stamp else { return }
            $0.window.recycleWaitMaxMS = max($0.window.recycleWaitMaxMS, waitMS)
        }
    }

    func presented(_ stamp: Stamp, at time: TimeInterval, submittedAt: TimeInterval) {
        guard Diagnostics.enabled else { return }
        state.withLock {
            guard $0.stamp == stamp else { $0.window.staleCallbacks += 1; return }
            guard time > 0 else { $0.window.unconfirmedPresentations += 1; return }
            $0.window.presented.record(at: time)
            $0.window.presentLatencyMaxMS = max($0.window.presentLatencyMaxMS, max(0, time - submittedAt) * 1_000)
        }
    }

    func flush(reason: String = "periodic", force: Bool = false) {
        guard Diagnostics.enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = state.withLock { state -> (Stamp, Window)? in
            guard force || now - state.window.startedAt >= 2 else { return nil }
            let result = (state.stamp, state.window)
            state.window.reset(at: now)
            return result
        }
        guard let (stamp, window) = snapshot else { return }
        let skips = window.skips.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")
        let zoom = window.zoomSamples.map {
            "\(Int(($0.time - window.startedAt) * 1_000)):\(String(format: "%.3f", $0.value)):\($0.ramping ? 1 : 0)"
        }.joined(separator: ",")
        #if targetEnvironment(simulator)
        let presentationSupported = false
        #else
        let presentationSupported = true
        #endif
        trace.event("preview_flow", "generation=\(stamp.generation) focal_seq=\(stamp.focal) reason=\(reason) window_ms=\(Int((now - window.startedAt) * 1_000)) " +
            "\(window.capture.fields("capture", at: now)) pts_gap_ms=\(String(format: "%.1f", window.pts.maximumGap * 1_000)) " +
            "\(window.submitted.fields("submit", at: now)) \(window.presented.fields("present", at: now)) presentation_supported=\(presentationSupported) " +
            "input=\(window.inputWidth)x\(window.inputHeight) dimension_changes=\(window.dimensionChanges) capture_drops=\(window.captureDrops) drop_reason=\(window.dropReason) skips=[\(skips)] " +
            "gpu_n=\(window.gpuCount) gpu_max_ms=\(String(format: "%.2f", window.gpuMaxMS)) gpu_errors=\(window.gpuErrorCount) completion_max_ms=\(String(format: "%.2f", window.completionMaxMS)) " +
            "recycle_wait_max_ms=\(String(format: "%.2f", window.recycleWaitMaxMS)) cpu_max_ms=\(String(format: "%.2f", window.cpuMaxMS)) drawable_wait_max_ms=\(String(format: "%.2f", window.drawableWaitMaxMS)) " +
            "frame_age_max_ms=\(String(format: "%.2f", window.frameAgeMaxMS)) present_latency_max_ms=\(String(format: "%.2f", window.presentLatencyMaxMS)) present_unconfirmed=\(window.unconfirmedPresentations) stale_callbacks=\(window.staleCallbacks) target_allocations=\(window.targetAllocations) zoom_n=\(window.zoomCount) zoom_samples=[\(zoom)]")
    }
}
