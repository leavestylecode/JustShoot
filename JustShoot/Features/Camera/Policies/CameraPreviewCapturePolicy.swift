import Foundation

/// Reject a frame from an old focal request, a source change, or a stalled view.
/// Presentation and capture timestamps use the host uptime clock.
enum CameraPreviewCapturePolicy {
    static let maximumFrameAge: TimeInterval = 0.25

    static func permits(frame: CameraPreviewFrame, generation: UInt64, focalSequence: UInt64,
                        sourceRevision: UInt64, settledAt: TimeInterval, expectedCrop: CGFloat,
                        now: TimeInterval) -> Bool {
        guard frame.generation == generation, frame.focalSequence == focalSequence,
              frame.sourceRevision == sourceRevision, let presentedAt = frame.presentedAt,
              now.isFinite, settledAt.isFinite, frame.capturedAt.isFinite, presentedAt.isFinite,
              frame.capturedAt >= settledAt, presentedAt >= frame.capturedAt, now >= presentedAt,
              now - frame.capturedAt <= maximumFrameAge,
              frame.crop.isFinite, expectedCrop.isFinite, expectedCrop >= 1 else { return false }
        return abs(frame.crop / expectedCrop - 1) < 0.001
    }
}
