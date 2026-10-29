import Foundation

struct CameraExposureRange: Equatable, Sendable {
    let bounds: ClosedRange<Float>

    init(minimum: Float = -1, maximum: Float = 1, recommended: ClosedRange<Float>? = nil) {
        let hardware = minimum.isFinite && maximum.isFinite && minimum <= maximum ? minimum...maximum : -1...1
        let preferred = recommended ?? hardware
        let lower = max(hardware.lowerBound, preferred.lowerBound)
        let upper = min(hardware.upperBound, preferred.upperBound)
        bounds = lower.isFinite && upper.isFinite && lower <= upper ? lower...upper : hardware
    }

    func clamp(_ value: Float) -> Float? {
        guard value.isFinite else { return nil }
        return min(bounds.upperBound, max(bounds.lowerBound, value))
    }

    func fraction(_ value: Float) -> Float {
        let span = value >= 0 ? bounds.upperBound : -bounds.lowerBound
        guard span > 0, let value = clamp(value) else { return 0 }
        return min(1, max(-1, value / span))
    }
}

/// Acknowledgements from superseded requests or a previous camera session cannot
/// make a newer EV appear applied. Protected by the manager's hardware-state lock.
struct CameraExposureApplication: Sendable {
    struct Request: Equatable, Sendable {
        let epoch: UInt64
        let sequence: UInt64
        let bias: Float
    }

    private var epoch: UInt64 = 0
    private var sequence: UInt64 = 0
    private var applied: UInt64 = 0
    private var failed: UInt64?
    private var pending: Request?

    var isReady: Bool { applied == sequence && failed == nil }
    var hasFailed: Bool { failed == sequence }

    mutating func request(_ bias: Float) -> Bool {
        let schedule = pending == nil
        sequence &+= 1
        pending = Request(epoch: epoch, sequence: sequence, bias: bias)
        failed = nil
        return schedule
    }

    mutating func takePending() -> Request? {
        defer { pending = nil }
        return pending
    }

    func permits(_ request: Request) -> Bool { request.epoch == epoch }

    mutating func acknowledge(_ request: Request) {
        guard permits(request) else { return }
        applied = max(applied, request.sequence)
    }

    mutating func fail(_ request: Request) {
        guard permits(request), request.sequence == sequence else { return }
        failed = request.sequence
    }

    mutating func reset() {
        epoch &+= 1
        sequence = 0
        applied = 0
        failed = nil
        pending = nil
    }

    /// The system slider has already written the device property when its action runs.
    mutating func acceptSystemChange() {
        reset()
    }
}
