import CoreVideo
import XCTest
@testable import JustShoot

final class CameraPreviewFrameStoreTests: XCTestCase {
    func testLatestCaptureDoesNotReplacePresentedFrameAndLatePresentationCannotRewindIt() throws {
        let store = CameraPreviewFrameStore()
        let first = try frame(id: 1)
        let second = try frame(id: 2)
        store.store(first.buffer, focalSequence: 3, sourceRevision: 4, at: 1)
        store.recordPresented(first, at: 1.1)
        store.store(second.buffer, focalSequence: 5, sourceRevision: 6, at: 2)
        XCTAssertTrue(store.latestFrame()?.0 === second.buffer)
        XCTAssertEqual(store.presentedFrame?.frameID, 1)
        store.recordPresented(second, at: 2.1)
        store.recordPresented(first, at: 2.2)
        XCTAssertEqual(store.presentedFrame?.frameID, 2)
        XCTAssertEqual(store.presentedFrame?.presentedAt, 2.1)
        XCTAssertEqual(store.latestFrame()?.3, 5)
        XCTAssertEqual(store.latestFrame()?.4, 6)
    }

    func testClearingFramesReleasesBothSlotsWithoutReusingFrameIdentity() throws {
        let store = CameraPreviewFrameStore()
        let input = try frame(id: 1)
        store.store(input.buffer, focalSequence: 0, sourceRevision: 0, at: 1)
        store.recordPresented(input, at: 1.1)
        store.clearFrames()
        XCTAssertNil(store.latestFrame())
        XCTAssertNil(store.presentedFrame)
        store.store(input.buffer, focalSequence: 1, sourceRevision: 1, at: 2)
        XCTAssertEqual(store.latestFrame()?.1, 2)
    }

    func testConcurrentNativeUpdatesKeepEveryFrameIdentity() throws {
        let store = CameraPreviewFrameStore()
        let input = try frame(id: 1)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            store.store(input.buffer, focalSequence: UInt64(index), sourceRevision: 1, at: Double(index))
            _ = store.latestFrame()
            _ = store.health()
        }
        XCTAssertEqual(store.latestFrame()?.1, 200)
    }

    private func frame(id: UInt64) throws -> CameraPreviewFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return CameraPreviewFrame(buffer: try XCTUnwrap(buffer), generation: 1, frameID: id,
            capturedAt: Double(id), lutKey: "test", rotation: 0, crop: 1,
            outputSize: CGSize(width: 4, height: 4), grainSeed: 1)
    }
}
