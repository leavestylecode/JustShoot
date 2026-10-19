import Metal
import os

/// Published only after its CPU upload finishes. Renderers never mutate this texture.
struct PreviewLUTTexture: @unchecked Sendable {
    let key: String
    let texture: any MTLTexture
    let dimension: Int
    let byteCount: Int
}

/// A separate serial worker keeps uploads out of drawing and out of the image-decoder queue.
/// A second cache check on that worker coalesces concurrent requests without duplicate uploads.
final class PreviewLUTTextureCache: Sendable {
    static let shared = PreviewLUTTextureCache()

    enum PreparationError: Error { case allocationFailed }

    private let worker: BlockingImageWork
    private let cache: OSAllocatedUnfairLock<ByteBudgetLRU<String, PreviewLUTTexture>>
    private let upload: @Sendable (String, CubeLUT) -> PreviewLUTTexture?

    init(worker: BlockingImageWork = BlockingImageWork(maximumConcurrentOperations: 1, label: "com.justshoot.preview-lut-upload"),
         maximumBytes: Int = 32 * 1_024 * 1_024, maximumEntries: Int = 8,
         upload: @escaping @Sendable (String, CubeLUT) -> PreviewLUTTexture? = PreviewLUTTextureCache.upload) {
        self.worker = worker
        cache = OSAllocatedUnfairLock(initialState: ByteBudgetLRU(
            maximumBytes: maximumBytes, maximumEntries: maximumEntries))
        self.upload = upload
    }

    func prepare(key: String, lut: CubeLUT) async throws -> PreviewLUTTexture {
        try Task.checkCancellation()
        if let cached = cache.withLock({ $0.value(forKey: key) }) { return cached }
        do { try await PreviewMetalResources.warmUp() }
        catch is CancellationError { throw CancellationError() }
        catch { throw PreparationError.allocationFailed }
        try Task.checkCancellation()
        let prepared = await worker.run { [self] in
            if let cached = cache.withLock({ $0.value(forKey: key) }) { return cached }
            guard let value = upload(key, lut) else { return nil }
            _ = cache.withLock { $0.insert(value, forKey: key, cost: value.byteCount) }
            return value
        }
        try Task.checkCancellation()
        guard let prepared else { throw PreparationError.allocationFailed }
        return prepared
    }

    static func upload(key: String, lut: CubeLUT) -> PreviewLUTTexture? {
        guard let device = PreviewMetalResources.shared.device else { return nil }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let dimension = lut.dimension
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = dimension
        descriptor.height = dimension
        descriptor.depth = dimension
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        lut.data.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: dimension, height: dimension, depth: dimension)),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: dimension * 4 * MemoryLayout<Float>.size,
                bytesPerImage: dimension * dimension * 4 * MemoryLayout<Float>.size)
        }
        Diagnostics.emit("preview_lut_uploaded", fields: "dimension=\(dimension) bytes=\(lut.data.count) duration_ms=\(Diagnostics.milliseconds(since: startedAt))")
        return PreviewLUTTexture(key: key, texture: texture, dimension: dimension,
            byteCount: max(lut.data.count, texture.allocatedSize))
    }
}
