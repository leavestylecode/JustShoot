import XCTest
import UIKit
import os
@testable import JustShoot

final class FilmCardImageCacheTests: XCTestCase {
    /// A synthetic codec gate. Poll only on the blocking image worker so test
    /// synchronization cannot introduce a semaphore QoS inversion warning.
    private final class DecodeGate: Sendable {
        private let released = OSAllocatedUnfairLock(initialState: false)

        func wait() {
            for _ in 0..<600 {
                if released.withLock({ $0 }) { return }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        func open() { released.withLock { $0 = true } }
    }

    func testConcurrentNearbySizesDecodeOnceAndShareThePreparedImage() async {
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let cache = FilmCardImageCache { _, pixel in
            XCTAssertEqual(pixel, 640)
            decodes.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.03)
            return UIImage()
        }
        let images = await withTaskGroup(of: UIImage?.self, returning: [UIImage].self) { group in
            for index in 0..<24 {
                group.addTask { await cache.loadImage(imageName: "shared.heic", maxPixel: index.isMultiple(of: 2) ? 540 : 600) }
            }
            var images: [UIImage] = []
            for await image in group { if let image { images.append(image) } }
            return images
        }
        XCTAssertEqual(images.count, 24)
        XCTAssertEqual(decodes.withLock { $0 }, 1)
        XCTAssertTrue(images.allSatisfy { $0 === images.first })
        XCTAssertTrue(cache.cachedImage(imageName: "shared.heic", maxPixel: 600) === images.first)
    }

    func testCancellingOneConsumerReturnsBeforeTheCodecAndKeepsAnotherConsumerUsable() async {
        let started = expectation(description: "Decode started")
        let cancelled = expectation(description: "Cancelled consumer returned")
        let gate = DecodeGate()
        let didStart = OSAllocatedUnfairLock(initialState: false)
        let cache = FilmCardImageCache { _, _ in
            // If cancellation removes the last consumer before the second one
            // registers, a replacement decode is allowed to start.
            let first = didStart.withLock { value in
                let first = !value
                value = true
                return first
            }
            if first { started.fulfill() }
            gate.wait()
            return UIImage()
        }
        let first = Task {
            let image = await cache.loadImage(imageName: "shared.heic", maxPixel: 200)
            XCTAssertNil(image)
            cancelled.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        let remaining = Task { await cache.loadImage(imageName: "shared.heic", maxPixel: 230) }
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        gate.open()
        let image = await remaining.value
        XCTAssertNotNil(image)
        await first.value
    }

    func testFailureCanBeRetriedAndDoesNotPoisonTheCache() async {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let cache = FilmCardImageCache { _, _ in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return attempt == 1 ? nil : UIImage()
        }
        let first = await cache.loadImage(imageName: "retry.heic", maxPixel: 200)
        let second = await cache.loadImage(imageName: "retry.heic", maxPixel: 200)
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    func testCancelledQueuedRequestDoesNotDecodeAndCanBeRequestedAgain() async {
        let worker = BlockingImageWork(maximumConcurrentOperations: 1)
        let started = expectation(description: "Worker occupied")
        let gate = DecodeGate()
        let occupied = Task {
            await worker.run {
                started.fulfill()
                gate.wait()
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let cache = FilmCardImageCache(worker: worker) { _, _ in
            decodes.withLock { $0 += 1 }
            return UIImage()
        }
        let request = Task { await cache.loadImage(imageName: "queued.heic", maxPixel: 300) }
        request.cancel()
        let cancelled = await request.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(decodes.withLock { $0 }, 0)
        gate.open()
        _ = await occupied.value
        let retried = await cache.loadImage(imageName: "queued.heic", maxPixel: 300)
        XCTAssertNotNil(retried)
        XCTAssertEqual(decodes.withLock { $0 }, 1)
    }

    func testBundledFilenameRequestsReuseTheSameDisplaySizeAcrossScreens() async throws {
        let cache = FilmCardImageCache()
        let loaded = await cache.loadImage(imageName: "00001_000.heic", maxPixel: 540)
        let home = try XCTUnwrap(loaded)
        let grid = await cache.loadImage(imageName: "00001_000.heic", maxPixel: 600)
        XCTAssertTrue(home === grid)
        XCTAssertLessThanOrEqual(max(home.cgImage?.width ?? 0, home.cgImage?.height ?? 0), 640)
    }

    func testExtremePixelRequestsStayWithinBundledImageBounds() {
        XCTAssertEqual(FilmCardImageCache.pixelSize(for: .min), 128)
        XCTAssertEqual(FilmCardImageCache.pixelSize(for: 0), 128)
        XCTAssertEqual(FilmCardImageCache.pixelSize(for: 256), 256)
        XCTAssertEqual(FilmCardImageCache.pixelSize(for: .max), 1024)
    }
}
