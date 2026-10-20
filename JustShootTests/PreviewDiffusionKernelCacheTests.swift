import XCTest
import MetalPerformanceShaders
import os
@testable import JustShoot

@MainActor
final class PreviewDiffusionKernelCacheTests: XCTestCase {
    private struct PreparationTimeout: Error {}
    private func recipe(_ preset: FilmPreset, width: Int = 801, height: Int = 603) throws -> PreviewDiffusionKernelCache.Recipe {
        try XCTUnwrap(PreviewDiffusionKernelCache.Recipe(optics: preset.filmOptics, width: width, height: height))
    }

    private func ready(_ cache: PreviewDiffusionKernelCache, _ recipe: PreviewDiffusionKernelCache.Recipe) async throws -> PreviewDiffusionKernelCache.Kernels {
        for _ in 0..<400 {
            if let kernels = cache.request(recipe) { return kernels }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Diffusion worker did not finish within the test deadline")
        throw PreparationTimeout()
    }

    func testFilmRevisitsReuseKernelsCreatedAwayFromMainActor() async throws {
        try await PreviewMetalResources.warmUp()
        let creations = OSAllocatedUnfairLock(initialState: 0)
        let cache = PreviewDiffusionKernelCache { recipe in
            XCTAssertFalse(Thread.isMainThread)
            creations.withLock { $0 += 1 }
            return PreviewDiffusionKernelCache.makeKernels(recipe)
        }
        let a = try recipe(.fujiC200)
        let first = try await ready(cache, a)
        for _ in 0..<120 { XCTAssertTrue(cache.request(a)?.halation === first.halation) }
        let b = try recipe(.kodakVision5219)
        let next = try await ready(cache, b)
        XCTAssertFalse(next.halation === first.halation)
        XCTAssertTrue(cache.request(a)?.halation === first.halation)
        XCTAssertEqual(creations.withLock { $0 }, 2)
        XCTAssertEqual(first.halation?.edgeMode, .zero)
        XCTAssertEqual(first.bloom?.edgeMode, .zero)
    }

    func testBusyWorkerKeepsOnlyTheLatestQueuedFilmAndDoesNotBlockDrawing() async throws {
        try await PreviewMetalResources.warmUp()
        let began = expectation(description: "First driver allocation began")
        let release = DispatchSemaphore(value: 0)
        let creations = OSAllocatedUnfairLock(initialState: [PreviewDiffusionKernelCache.Recipe]())
        let a = try recipe(.fujiC200)
        let b = try recipe(.fujiPro400H)
        let c = try recipe(.harmanPhoenix200)
        let cache = PreviewDiffusionKernelCache { recipe in
            let isFirst = creations.withLock { $0.append(recipe); return $0.count == 1 }
            if isFirst {
                began.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            return PreviewDiffusionKernelCache.makeKernels(recipe)
        }
        defer { release.signal() }
        XCTAssertNil(cache.request(a))
        await fulfillment(of: [began], timeout: 2)
        for _ in 0..<120 { XCTAssertNil(cache.request(a)) }
        XCTAssertNil(cache.request(b))
        XCTAssertNil(cache.request(c))
        release.signal()
        _ = try await ready(cache, c)
        XCTAssertEqual(creations.withLock { $0 }, [a, c])
    }

    func testEvictedKernelsRemainUsableByAnActiveFrame() async throws {
        try await PreviewMetalResources.warmUp()
        let cache = PreviewDiffusionKernelCache(maximumEntries: 1)
        let a = try recipe(.fujiC200)
        let active = try await ready(cache, a)
        _ = try await ready(cache, recipe(.kodakPortra400))
        let revisited = try await ready(cache, a)
        XCTAssertFalse(active.halation === revisited.halation)
        XCTAssertEqual(active.halation?.sigma, a.halationSigma)
        XCTAssertEqual(active.bloom?.edgeMode, .zero)
    }

    func testFailedPreparationCanRetry() async throws {
        try await PreviewMetalResources.warmUp()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let cache = PreviewDiffusionKernelCache { recipe in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return attempt == 1 ? nil : PreviewDiffusionKernelCache.makeKernels(recipe)
        }
        _ = try await ready(cache, recipe(.fujiC200))
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    func testPreparedKernelsPreservePixelsThroughActualGPUEncoding() async throws {
        try await PreviewMetalResources.warmUpForRenderer()
        let resources = try XCTUnwrap(PreviewMetalResources.shared.rendererResources)
        let selected = try recipe(.kodakPortra400)
        let kernels = try await ready(PreviewDiffusionKernelCache(), selected)
        let size = 32
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
            width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let input = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
        var samples = [UInt16](repeating: 0, count: size * size)
        samples[(size / 2) * size + size / 2] = Float16(1).bitPattern
        samples.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size * MemoryLayout<UInt16>.size)
        }
        for (cached, sigma) in [(kernels.halation, selected.halationSigma), (kernels.bloom, selected.bloomSigma)] {
            let cached = try XCTUnwrap(cached)
            let sigma = try XCTUnwrap(sigma)
            let reference = MPSImageGaussianBlur(device: resources.device, sigma: sigma)
            reference.edgeMode = .zero
            let actual = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
            let expected = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
            let buffer = try XCTUnwrap(resources.commandQueue.makeCommandBuffer())
            cached.encode(commandBuffer: buffer, sourceTexture: input, destinationTexture: actual)
            reference.encode(commandBuffer: buffer, sourceTexture: input, destinationTexture: expected)
            let status = await withCheckedContinuation { continuation in
                buffer.addCompletedHandler { continuation.resume(returning: $0.status.rawValue) }
                buffer.commit()
            }
            XCTAssertEqual(status, MTLCommandBufferStatus.completed.rawValue)
            func pixels(_ texture: any MTLTexture) -> [UInt16] {
                var values = [UInt16](repeating: 0, count: size * size)
                values.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: size * MemoryLayout<UInt16>.size,
                        from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
                }
                return values
            }
            let output = pixels(actual)
            XCTAssertEqual(output, pixels(expected))
            let center = Float16(bitPattern: output[(size / 2) * size + size / 2])
            XCTAssertGreaterThan(center, 0)
            XCTAssertLessThan(center, 1)
        }
    }

    func testRecipesPreserveDiffusionRadiiAcrossFilmsAndOddDrawableSizes() throws {
        for preset in FilmPreset.allCases {
            for size in [(801, 603), (1440, 1920), (393, 851)] {
                let optics = preset.filmOptics
                let small = CameraPerformancePolicy.diffusionSize(width: size.0, height: size.1)
                let longEdge = max(size.0, size.1)
                let scale = Float(max(small.width, small.height)) / Float(longEdge)
                let actual = try recipe(preset, width: size.0, height: size.1)
                XCTAssertEqual(actual.halationSigma, optics.radiusPixels(optics.halationRadius, forLongEdge: CGFloat(longEdge)) * 0.55 * scale)
                XCTAssertEqual(actual.bloomSigma, optics.radiusPixels(optics.bloomRadius, forLongEdge: CGFloat(longEdge)) * 0.45 * scale)
            }
        }
        XCTAssertNil(PreviewDiffusionKernelCache.Recipe(optics: FilmPreset.fujiC200.filmOptics, width: 0, height: 500))
        let disabled = try XCTUnwrap(PreviewDiffusionKernelCache.Recipe(optics: .disabled, width: 800, height: 600))
        XCTAssertNil(disabled.halationSigma)
        XCTAssertNil(disabled.bloomSigma)
    }
}
