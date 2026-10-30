import CoreVideo
import os
import XCTest
@testable import JustShoot

final class CameraPreviewPresentationLeaseTests: XCTestCase {
    private let allocationLimit = [kCVPixelBufferPoolAllocationThresholdKey: 1] as CFDictionary

    func testCompletedPresentationReleasesTheCameraPoolBufferWhileCallbackRemainsAlive() throws {
        let pool = try makePool()
        let lease = try makeLease(pool)
        XCTAssertEqual(allocationStatus(pool), kCVReturnWouldExceedAllocationThreshold)
        var presentedFrame = lease.takeFrame()
        XCTAssertNotNil(presentedFrame)
        withExtendedLifetime(presentedFrame) {
            XCTAssertEqual(allocationStatus(pool), kCVReturnWouldExceedAllocationThreshold,
                "The shutter snapshot must still own its buffer")
        }
        presentedFrame = nil
        withExtendedLifetime(lease) {
            XCTAssertEqual(allocationStatus(pool), kCVReturnSuccess,
                "A retained presentation callback must not pin a camera-pool buffer")
            XCTAssertNil(lease.takeFrame())
        }
    }

    func testFailedGPUWorkCanDiscardThePresentationWithoutWaitingForADrawableCallback() throws {
        let pool = try makePool()
        let lease = try makeLease(pool)
        _ = lease.takeFrame()
        withExtendedLifetime(lease) {
            XCTAssertEqual(allocationStatus(pool), kCVReturnSuccess)
            XCTAssertNil(lease.takeFrame())
        }
    }

    func testPresentationAndFailureCallbacksCannotBothConsumeTheFrame() throws {
        let lease = try makeLease(makePool())
        let consumers = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if lease.takeFrame() != nil { consumers.withLock { $0 += 1 } }
        }
        XCTAssertEqual(consumers.withLock { $0 }, 1)
    }

    private func makePool() throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
            [kCVPixelBufferWidthKey: 8, kCVPixelBufferHeightKey: 4,
             kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary, &pool), kCVReturnSuccess)
        return try XCTUnwrap(pool)
    }

    private func makeLease(_ pool: CVPixelBufferPool) throws -> CameraPreviewPresentationLease {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            allocationLimit, &buffer), kCVReturnSuccess)
        return CameraPreviewPresentationLease(CameraPreviewFrame(buffer: try XCTUnwrap(buffer),
            generation: 1, frameID: 1, capturedAt: 1, lutKey: "test", rotation: 0, crop: 1,
            outputSize: CGSize(width: 3, height: 4), grainSeed: 1))
    }

    private func allocationStatus(_ pool: CVPixelBufferPool) -> CVReturn {
        var buffer: CVPixelBuffer?
        return CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, allocationLimit, &buffer)
    }
}
