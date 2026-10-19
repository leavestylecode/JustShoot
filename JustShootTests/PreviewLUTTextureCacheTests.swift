import XCTest
import Metal
import os
@testable import JustShoot

final class PreviewLUTTextureCacheTests: XCTestCase {
    private static func cube() -> CubeLUT {
        var values: [Float] = []
        for index in 0..<8 {
            values.append(Float(index % 2))
            values.append(Float((index / 2) % 2))
            values.append(Float(index / 4))
            values.append(1)
        }
        return CubeLUT(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: 2)
    }

    @MainActor
    func testConcurrentRequestsUploadOnceAwayFromMainActor() async throws {
        let uploads = OSAllocatedUnfairLock(initialState: 0)
        let cache = PreviewLUTTextureCache { key, lut in
            XCTAssertFalse(Thread.isMainThread)
            uploads.withLock { $0 += 1 }
            return PreviewLUTTextureCache.upload(key: key, lut: lut)
        }
        let lut = Self.cube()
        let textures = try await withThrowingTaskGroup(of: PreviewLUTTexture.self) { group in
            for _ in 0..<24 { group.addTask { try await cache.prepare(key: "film", lut: lut) } }
            var values: [PreviewLUTTexture] = []
            for try await value in group { values.append(value) }
            return values
        }
        let first = try XCTUnwrap(textures.first)
        XCTAssertEqual(uploads.withLock { $0 }, 1)
        XCTAssertTrue(textures.allSatisfy { $0.texture === first.texture })
        XCTAssertEqual(first.key, "film")
        XCTAssertEqual(first.dimension, 2)
        var actual = [Float](repeating: 0, count: 32)
        actual.withUnsafeMutableBytes { bytes in
            first.texture.getBytes(bytes.baseAddress!, bytesPerRow: 32, bytesPerImage: 64,
                from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: 2, height: 2, depth: 2)),
                mipmapLevel: 0, slice: 0)
        }
        XCTAssertEqual(actual.withUnsafeBufferPointer { Data(buffer: $0) }, lut.data)
    }

    func testEvictionDoesNotInvalidateAnActiveRendererTexture() async throws {
        let cache = PreviewLUTTextureCache(maximumEntries: 1)
        let lut = Self.cube()
        let active = try await cache.prepare(key: "a", lut: lut)
        let next = try await cache.prepare(key: "b", lut: lut)
        let revisited = try await cache.prepare(key: "a", lut: lut)
        XCTAssertFalse(active.texture === revisited.texture)
        XCTAssertFalse(next.texture === revisited.texture)
        XCTAssertEqual(active.texture.width, 2)
        XCTAssertEqual(active.texture.depth, 2)
        XCTAssertEqual(active.dimension, revisited.dimension)
    }

    func testOversizedTextureRemainsUsableWithoutEnteringTheCache() async throws {
        let cache = PreviewLUTTextureCache(maximumBytes: 1)
        let first = try await cache.prepare(key: "large", lut: Self.cube())
        let second = try await cache.prepare(key: "large", lut: Self.cube())
        XCTAssertGreaterThan(first.byteCount, 1)
        XCTAssertFalse(first.texture === second.texture)
        XCTAssertEqual(first.texture.width, first.dimension)
    }

    func testAllocationFailureCanBeRetried() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let cache = PreviewLUTTextureCache { key, lut in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return attempt == 1 ? nil : PreviewLUTTextureCache.upload(key: key, lut: lut)
        }
        do {
            _ = try await cache.prepare(key: "retry", lut: Self.cube())
            XCTFail("Expected a recoverable allocation failure")
        } catch is PreviewLUTTextureCache.PreparationError { }
        let retried = try await cache.prepare(key: "retry", lut: Self.cube())
        let cached = try await cache.prepare(key: "retry", lut: Self.cube())
        XCTAssertTrue(retried.texture === cached.texture)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    func testCancelledQueuedSelectionDoesNotUploadOrBlockTheNextSelection() async throws {
        try await PreviewMetalResources.warmUp()
        let worker = BlockingImageWork(maximumConcurrentOperations: 1)
        let started = expectation(description: "Upload worker occupied")
        let released = OSAllocatedUnfairLock(initialState: false)
        let blocker = Task {
            await worker.run {
                started.fulfill()
                for _ in 0..<600 {
                    if released.withLock({ $0 }) { break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return true
            }
        }
        defer { released.withLock { $0 = true } }
        await fulfillment(of: [started], timeout: 2)
        let uploads = OSAllocatedUnfairLock(initialState: [String]())
        let cache = PreviewLUTTextureCache(worker: worker) { key, lut in
            uploads.withLock { $0.append(key) }
            return PreviewLUTTextureCache.upload(key: key, lut: lut)
        }
        let cancelled = Task { try await cache.prepare(key: "stale", lut: Self.cube()) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled selection must not publish a texture")
        } catch is CancellationError { }
        XCTAssertTrue(uploads.withLock { $0.isEmpty })
        released.withLock { $0 = true }
        _ = await blocker.value
        let current = try await cache.prepare(key: "current", lut: Self.cube())
        XCTAssertEqual(current.key, "current")
        XCTAssertEqual(uploads.withLock { $0 }, ["current"])
    }
}
