import CoreVideo
import Foundation
import os

/// The camera delegate and renderer share bounded frame state without queue hops or UI objects.
final class CameraPreviewFrameStore: Sendable {
    private struct State: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var frameID: UInt64 = 0
        var lastFrameAt: TimeInterval?
        var focalSequence: UInt64 = 0
        var sourceRevision: UInt64 = 0
        var presented: CameraPreviewFrame?
        var droppedFrames: UInt64 = 0
        var lastDropReason = "none"
        var lastDropLogAt: TimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let firstFrame = OSAllocatedUnfairLock(initialState: false)

    func latestFrame() -> (CVPixelBuffer, UInt64, TimeInterval, UInt64, UInt64)? {
        state.withLockUnchecked {
            guard let buffer = $0.buffer, let capturedAt = $0.lastFrameAt else { return nil }
            return (buffer, $0.frameID, capturedAt, $0.focalSequence, $0.sourceRevision)
        }
    }

    func store(_ buffer: CVPixelBuffer, focalSequence: UInt64, sourceRevision: UInt64,
               at time: TimeInterval) {
        state.withLockUnchecked {
            $0.buffer = buffer
            $0.frameID &+= 1
            $0.lastFrameAt = time
            $0.focalSequence = focalSequence
            $0.sourceRevision = sourceRevision
        }
    }

    func recordPresented(_ frame: CameraPreviewFrame, at time: TimeInterval) {
        var presented = frame
        presented.presentedAt = time
        state.withLockUnchecked {
            guard $0.presented.map({ $0.frameID < frame.frameID }) ?? true else { return }
            $0.presented = presented
        }
    }

    var presentedFrame: CameraPreviewFrame? { state.withLockUnchecked { $0.presented } }

    func health() -> PreviewHealth {
        state.withLockUnchecked {
            PreviewHealth(frameID: $0.frameID, lastFrameAt: $0.lastFrameAt,
                width: $0.buffer.map(CVPixelBufferGetWidth) ?? 0,
                height: $0.buffer.map(CVPixelBufferGetHeight) ?? 0,
                droppedFrames: $0.droppedFrames, lastDropReason: $0.lastDropReason)
        }
    }

    func frameAge(at time: TimeInterval) -> TimeInterval {
        state.withLock { $0.lastFrameAt.map { time - $0 } ?? .infinity }
    }

    func claimFirstFrame() -> Bool {
        firstFrame.withLock {
            guard !$0 else { return false }
            $0 = true
            return true
        }
    }

    func resetFirstFrame() { firstFrame.withLock { $0 = false } }

    func clearFrames() {
        state.withLockUnchecked { $0.buffer = nil; $0.presented = nil }
    }

    func recordDrop(reason: String, at time: TimeInterval) -> UInt64? {
        state.withLock {
            $0.droppedFrames &+= 1
            $0.lastDropReason = reason
            guard time - $0.lastDropLogAt >= 2 else { return nil }
            $0.lastDropLogAt = time
            return $0.droppedFrames
        }
    }
}
