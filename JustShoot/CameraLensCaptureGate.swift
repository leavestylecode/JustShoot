import CoreGraphics

/// A timeout is a failed request, not evidence that the selected focal length was reached.
struct CameraLensCaptureGate: Sendable {
    private(set) var targetZoom: CGFloat?
    private(set) var isTransitioning = false
    private(set) var hasFailed = false
    private var hardwarePending = false
    private var graceSeconds: Double = 0
    private var onTargetSince: Double?

    mutating func begin(zoom: CGFloat, graceMs: Int, hardwarePending: Bool = false) {
        targetZoom = zoom
        graceSeconds = Double(graceMs) / 1_000
        self.hardwarePending = hardwarePending
        onTargetSince = nil
        hasFailed = false
        isTransitioning = true
    }

    mutating func hardwareApplied() { hardwarePending = false }

    func isOnTarget(zoom: CGFloat, isRamping: Bool) -> Bool {
        guard !hardwarePending, !isRamping, zoom.isFinite else { return false }
        return targetZoom.map { abs(zoom - $0) < 0.1 } ?? true
    }

    func isReady(zoom: CGFloat, isRamping: Bool) -> Bool {
        // Completion also schedules any physical telephoto lock. A polling capture task must
        // not bypass that callback merely because its clock observes the elapsed grace first.
        !hasFailed && !isTransitioning && isOnTarget(zoom: zoom, isRamping: isRamping)
    }

    /// Returns true once, when a transition completes its uninterrupted grace period.
    mutating func evaluate(zoom: CGFloat, isRamping: Bool, now: Double) -> Bool {
        guard isTransitioning else { return false }
        guard isOnTarget(zoom: zoom, isRamping: isRamping) else {
            onTargetSince = nil
            return false
        }
        if onTargetSince == nil { onTargetSince = now }
        guard let onTargetSince, now - onTargetSince >= graceSeconds else { return false }
        isTransitioning = false
        return true
    }

    mutating func fail() {
        hasFailed = true
        isTransitioning = false
        hardwarePending = false
        onTargetSince = nil
    }

    mutating func reset() { self = Self() }
}
