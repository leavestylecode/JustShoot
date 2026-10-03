import Foundation
import UIKit
import Darwin
import os

/// All diagnostic durations use uptime; wall-clock changes cannot distort a stage's duration.
struct DiagnosticTrace: Sendable {
    let id: String
    let startedAt: TimeInterval

    init(id: String = String(UUID().uuidString.prefix(8))) {
        self.id = id
        startedAt = Diagnostics.traceStart(id: id)
    }

    func event(_ name: String, _ fields: @autoclosure () -> String = "") {
        guard Diagnostics.enabled else { return }
        Diagnostics.emit(name, id: id, fields: "elapsed_ms=\(Diagnostics.milliseconds(since: startedAt)) \(fields())")
    }

    func span(_ stage: String, _ fields: String = "") -> DiagnosticSpan {
        event(stage + "_begin", fields)
        return DiagnosticSpan(trace: self, stage: stage, startedAt: ProcessInfo.processInfo.systemUptime)
    }

    func measure<T>(_ stage: String, _ operation: () throws -> T) rethrows -> T {
        let interval = span(stage)
        do {
            let result = try operation()
            interval.end()
            return result
        } catch {
            interval.end("error", Diagnostics.errorFields(error))
            throw error
        }
    }
}

struct DiagnosticSpan: Sendable {
    let trace: DiagnosticTrace
    let stage: String
    let startedAt: TimeInterval

    func end(_ status: String = "ok", _ fields: String = "") {
        trace.event(stage + "_end", "duration_ms=\(Diagnostics.milliseconds(since: startedAt)) status=\(status) \(fields)")
    }
}

enum Diagnostics {
    static let enabled = ProcessInfo.processInfo.environment["JUSTSHOOT_DIAGNOSTICS"] != "0"
    static let runID = String(UUID().uuidString.prefix(8))
    private static let runStartedAt = ProcessInfo.processInfo.systemUptime
    private static let traceStarts = OSAllocatedUnfairLock<[String: TimeInterval]>(initialState: [:])

    static func traceStart(id: String) -> TimeInterval {
        traceStarts.withLock { starts in
            if let existing = starts[id] { return existing }
            if starts.count >= 512, let oldest = starts.min(by: { $0.value < $1.value })?.key { starts[oldest] = nil }
            let now = ProcessInfo.processInfo.systemUptime
            starts[id] = now
            return now
        }
    }

    static func milliseconds(since time: TimeInterval) -> String {
        String(format: "%.1f", max(0, ProcessInfo.processInfo.systemUptime - time) * 1_000)
    }

    static func emit(_ name: String, id: String = "app", fields: @autoclosure () -> String = "") {
        guard enabled else { return }
        DiagnosticWatchdog.shared.noteStage(id: id, stage: name)
        let line = "diag event=\(name) run=\(runID) id=\(id) run_ms=\(milliseconds(since: runStartedAt)) \(fields())"
        Log.diagnostics.info("\(line, privacy: .public)")
        DiagnosticLogStore.shared.append(line)
    }

    static func errorFields(_ error: any Error) -> String {
        let error = error as NSError
        return "error_domain=\(error.domain) error_code=\(error.code)"
    }

    static func resourceFields() -> String {
        let process = ProcessInfo.processInfo
        let memory = footprintMB().map { String(format: "%.1f", $0) } ?? "unavailable"
        return "footprint_mb=\(memory) thermal=\(process.thermalState.rawValue) low_power=\(process.isLowPowerModeEnabled)"
    }

    private static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    @MainActor
    static func start() {
        RuntimeDiagnosticLifecycle.shared.start()
    }
}

/// A single outstanding main-queue probe prevents a blocked UI from accumulating callbacks.
/// Long gaps in the watchdog itself are identified separately (suspension/debugger/scheduling).
struct MainQueueProbe: Sendable {
    private(set) var token: UInt64 = 0
    private(set) var pendingSince: TimeInterval?
    private(set) var hasReported = false
    private var lastReport: TimeInterval?
    private var lastTick: TimeInterval?

    mutating func reset() {
        token &+= 1
        pendingSince = nil
        hasReported = false
        lastReport = nil
        lastTick = nil
    }

    mutating func tick(at now: TimeInterval) -> (probe: UInt64?, stall: TimeInterval?, gap: TimeInterval?) {
        let gap = lastTick.map { now - $0 }
        if let gap, gap > 1.5 {
            reset()
            lastTick = now
            return (nil, nil, gap)
        }
        lastTick = now
        if let pendingSince {
            let delay = now - pendingSince
            if delay >= 0.25, lastReport.map({ now - $0 >= 2 }) ?? true {
                hasReported = true
                lastReport = now
                return (nil, delay, nil)
            }
            return (nil, nil, nil)
        }
        token &+= 1
        pendingSince = now
        return (token, nil, nil)
    }

    mutating func acknowledge(_ token: UInt64, at now: TimeInterval) -> (delay: TimeInterval?, gap: TimeInterval?) {
        guard token == self.token, let pendingSince else { return (nil, nil) }
        if let lastTick, now - lastTick > 1.5 {
            let gap = now - lastTick
            reset()
            return (nil, gap)
        }
        let delay = now - pendingSince
        let report = hasReported || delay >= 0.25
        self.pendingSince = nil
        hasReported = false
        lastReport = nil
        return (report ? delay : nil, nil)
    }
}

struct PreviewHealth: Sendable {
    let frameID: UInt64
    let lastFrameAt: TimeInterval?
    let width: Int
    let height: Int
    let droppedFrames: UInt64
    let lastDropReason: String
}

final class DiagnosticWatchdog: @unchecked Sendable {
    static let shared = DiagnosticWatchdog()

    private struct Camera: Sendable {
        let health: @Sendable () -> PreviewHealth?
        let flow: CameraFlowDiagnostics?
        var stage = "camera_view_appear"
    }
    private struct State {
        var active = false
        var probe = MainQueueProbe()
        var cameras: [String: Camera] = [:]
        var lastHeartbeat: TimeInterval = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timer: any DispatchSourceTimer

    private init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "diagnostics.watchdog", qos: .utility))
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    func setActive(_ active: Bool) {
        state.withLock { state in
            state.active = active
            state.probe.reset()
            state.lastHeartbeat = 0
        }
        timer.schedule(deadline: active ? .now() + .milliseconds(250) : .distantFuture,
                       repeating: .milliseconds(250), leeway: .milliseconds(50))
    }

    func addCamera(id: String, flow: CameraFlowDiagnostics? = nil, health: @escaping @Sendable () -> PreviewHealth?) {
        guard Diagnostics.enabled else { return }
        state.withLock { $0.cameras[id] = Camera(health: health, flow: flow) }
    }

    func removeCamera(id: String) { state.withLock { _ = $0.cameras.removeValue(forKey: id) } }
    func flushCameras(reason: String) {
        let flows = state.withLock { $0.cameras.values.compactMap(\.flow) }
        for flow in flows { flow.flush(reason: reason, force: true) }
    }
    func noteStage(id: String, stage: String) {
        // Frame metrics must not obscure the lifecycle/configuration stage in watchdog reports.
        guard !stage.hasPrefix("preview_"), stage != "camera_heartbeat" else { return }
        state.withLock { state in
            if state.cameras[id] != nil { state.cameras[id]?.stage = stage }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = state.withLock { state -> ((probe: UInt64?, stall: TimeInterval?, gap: TimeInterval?), [String: Camera], Bool)? in
            guard state.active else { return nil }
            let result = state.probe.tick(at: now)
            let heartbeat = !state.cameras.isEmpty && now - state.lastHeartbeat >= 5
            if heartbeat { state.lastHeartbeat = now }
            return (result, state.cameras, heartbeat)
        }
        guard let (result, cameras, heartbeat) = snapshot else { return }
        for camera in cameras.values { camera.flow?.flush() }
        let context = cameras.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.stage)" }.joined(separator: ",")
        if let gap = result.gap { Diagnostics.emit("watchdog_gap", fields: "gap_ms=\(Int(gap * 1_000)) reason=scheduler_suspend_or_debugger") }
        if let delay = result.stall {
            Diagnostics.emit("main_queue_stall", fields: "delay_ms=\(Int(delay * 1_000)) cameras=\(context) \(Diagnostics.resourceFields())")
        }
        if let token = result.probe {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let result = self.state.withLock { state -> (delay: TimeInterval?, gap: TimeInterval?)? in
                    guard state.active else { return nil }
                    return state.probe.acknowledge(token, at: ProcessInfo.processInfo.systemUptime)
                }
                if let delay = result?.delay { Diagnostics.emit("main_queue_recovered", fields: "delay_ms=\(Int(delay * 1_000)) cameras=\(context)") }
                if let gap = result?.gap { Diagnostics.emit("watchdog_gap", fields: "gap_ms=\(Int(gap * 1_000)) reason=scheduler_suspend_or_debugger") }
            }
        }
        if heartbeat {
            for (id, camera) in cameras {
                guard let health = camera.health() else { continue }
                let age = health.lastFrameAt.map { Int(max(0, now - $0) * 1_000) } ?? -1
                Diagnostics.emit("camera_heartbeat", id: id,
                    fields: "phase=\(camera.stage) frame=\(health.frameID) frame_age_ms=\(age) input=\(health.width)x\(health.height) capture_dropped=\(health.droppedFrames) last_drop=\(health.lastDropReason) \(Diagnostics.resourceFields())")
            }
        }
    }
}

@MainActor
private final class RuntimeDiagnosticLifecycle {
    static let shared = RuntimeDiagnosticLifecycle()
    private var observers: [any NSObjectProtocol] = []
    private var started = false

    func start() {
        guard Diagnostics.enabled, !started else { return }
        started = true
        var system = utsname()
        uname(&system)
        let machineSize = MemoryLayout.size(ofValue: system.machine)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineSize) { String(cString: $0) }
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        Diagnostics.emit("run_begin", fields: "schema=2 utc=\(Date().ISO8601Format()) model=\(model) ios=\(version.majorVersion).\(version.minorVersion).\(version.patchVersion) configuration=\(configuration) simulator=\(simulator) app=\(app) build=\(build) stall_threshold_ms=250 preview_window_ms=2000 \(Diagnostics.resourceFields())")
        DiagnosticWatchdog.shared.setActive(UIApplication.shared.applicationState == .active)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            DiagnosticWatchdog.shared.setActive(true)
            Diagnostics.emit("app_active", fields: Diagnostics.resourceFields())
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            DiagnosticWatchdog.shared.flushCameras(reason: "app_inactive")
            DiagnosticWatchdog.shared.setActive(false)
            Diagnostics.emit("app_inactive")
        })
        for name in [UIApplication.didReceiveMemoryWarningNotification, ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Diagnostics.emit("system_state_changed", fields: "notification=\(name.rawValue) \(Diagnostics.resourceFields())")
            })
        }
    }
}
