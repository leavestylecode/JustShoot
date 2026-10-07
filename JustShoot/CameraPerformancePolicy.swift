import AVFoundation
import CoreGraphics

/// Generation checks invalidate queued work after a navigation or background transition.
struct CameraSessionIntent: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var wantsRunning = false

    mutating func request(running: Bool) -> UInt64 {
        generation &+= 1
        wantsRunning = running
        return generation
    }

    func permitsStart(_ token: UInt64) -> Bool { wantsRunning && generation == token }
}

enum CameraPerformancePolicy {
    static let maximumPreviewLongEdge: CGFloat = 1280

    static func configurePreviewOutput(_ output: AVCaptureVideoDataOutput) {
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // Restore AVFoundation's default negotiation. Forcing the preview proxy was introduced
        // with the performance refactor; device traces now show zoom advancing while the user
        // reports an unchanged viewfinder. Keep drawable work bounded separately below.
        output.automaticallyConfiguresOutputBufferDimensions = true
    }

    static func drawableSize(bounds: CGSize, scale: CGFloat) -> CGSize {
        guard bounds.width.isFinite, bounds.height.isFinite, scale.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let factor = min(max(1, scale), maximumPreviewLongEdge / max(bounds.width, bounds.height))
        return CGSize(width: max(1, floor(bounds.width * factor)), height: max(1, floor(bounds.height * factor)))
    }

    static func diffusionSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(1, (width + 1) / 2), max(1, (height + 1) / 2))
    }

    static func frameRate(in ranges: [ClosedRange<Double>], ceiling: Double = 60) -> Double? {
        ranges.compactMap { range in
            let value = min(ceiling, range.upperBound)
            return value >= range.lowerBound && value > 0 ? value : nil
        }.max()
    }
}

/// AVFoundation smooths ramp-rate changes with an acceleration limit. Retargeting a ramp
/// while it is moving can carry its old velocity past the new destination. Assigning the
/// current zoom cancels that ramp without jumping to the requested destination, then the
/// new ramp starts from the device's actual position. cancelVideoZoomRamp() only eases out.
struct CameraZoomTransition: Sendable {
    let anchorZoom: CGFloat?
    let targetZoom: CGFloat
    let rate: Float
    let usesRamp: Bool

    init?(currentZoom: CGFloat, targetZoom: CGFloat, isRamping: Bool, animated: Bool) {
        guard currentZoom.isFinite, targetZoom.isFinite, currentZoom > 0, targetZoom > 0 else { return nil }
        self.targetZoom = targetZoom
        anchorZoom = animated && isRamping ? currentZoom : nil
        let ratio = max(targetZoom / currentZoom, currentZoom / targetZoom)
        rate = ratio < 1.5 ? 4 : ratio < 3 ? 8 : 16
        usesRamp = animated && abs(targetZoom - currentZoom) > 0.0001
    }
}
