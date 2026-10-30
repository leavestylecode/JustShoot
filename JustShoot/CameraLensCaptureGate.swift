import CoreGraphics

/// A timeout is a failed request, not evidence that the selected focal length was reached.
struct CameraLensCaptureGate: Sendable {
    struct RequestStamp: Equatable, Sendable {
        let generation: UInt64
        let focalSequence: UInt64
    }

    /// Updated on the native KVO thread before its main-actor task. This closes the window
    /// where the hardware queue could otherwise invoke a capture before that task runs.
    struct SourceStability: Sendable {
        private(set) var observationEpoch: UInt64 = 0
        private(set) var revision: UInt64 = 0
        private var change: (stamp: RequestStamp, at: Double)?

        mutating func invalidateObservations() -> UInt64 {
            observationEpoch &+= 1
            revision &+= 1
            change = nil
            return observationEpoch
        }

        mutating func record(stamp: RequestStamp, observationEpoch: UInt64, at now: Double) -> Bool {
            guard self.observationEpoch == observationEpoch, now.isFinite else { return false }
            if let change {
                guard stamp.generation >= change.stamp.generation, now >= change.at else { return false }
                if stamp.generation == change.stamp.generation,
                   stamp.focalSequence < change.stamp.focalSequence { return false }
            }
            change = (stamp, now)
            revision &+= 1
            return true
        }

        func remainingGrace(stamp: RequestStamp, at now: Double) -> Double {
            guard let change, change.stamp == stamp else { return 0 }
            return max(0, change.at + 0.150 - now)
        }
    }

    private(set) var targetZoom: CGFloat?
    private(set) var requestStamp: RequestStamp?
    private(set) var isTransitioning = false
    private(set) var hasFailed = false
    private var hardwarePending = false
    private var graceSeconds: Double = 0
    private var onTargetSince: Double?

    mutating func begin(zoom: CGFloat, graceMs: Int, hardwarePending: Bool = false,
                        stamp: RequestStamp? = nil) {
        targetZoom = zoom
        requestStamp = stamp
        graceSeconds = Double(graceMs) / 1_000
        self.hardwarePending = hardwarePending
        onTargetSince = nil
        hasFailed = false
        isTransitioning = true
    }

    mutating func hardwareApplied() { hardwarePending = false }

    /// A physical source can change after the zoom's grace has completed. Restart a full
    /// source grace without clearing a failed request or acknowledging pending hardware.
    mutating func sourceDidChange(stamp: RequestStamp, graceMs: Int = 150) -> Bool {
        guard requestStamp == stamp, targetZoom != nil, !hasFailed else { return false }
        graceSeconds = max(graceSeconds, Double(graceMs) / 1_000)
        onTargetSince = nil
        isTransitioning = true
        return true
    }

    func isOnTarget(zoom: CGFloat, isRamping: Bool) -> Bool {
        guard !hardwarePending, !isRamping, zoom.isFinite else { return false }
        return targetZoom.map { abs(zoom - $0) < 0.1 } ?? true
    }

    func isReady(zoom: CGFloat, isRamping: Bool) -> Bool {
        // Completion also schedules any physical telephoto lock. A polling capture task must
        // not bypass that callback merely because its clock observes the elapsed grace first.
        !hasFailed && !isTransitioning && isOnTarget(zoom: zoom, isRamping: isRamping)
    }

    /// Repeating the selected focal length must not reissue its ramp or restart ZSL grace.
    /// Failed, stale and externally moved targets remain eligible for a real retry.
    func canReuseSelection(generation: UInt64, zoom: CGFloat, isRamping: Bool) -> Bool {
        requestStamp?.generation == generation && targetZoom != nil && !hasFailed &&
            (isTransitioning || isOnTarget(zoom: zoom, isRamping: isRamping))
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
