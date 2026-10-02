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
        output.automaticallyConfiguresOutputBufferDimensions = false
        output.deliversPreviewSizedOutputBuffers = true
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
