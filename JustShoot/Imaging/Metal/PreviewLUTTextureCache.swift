import Metal
import os

/// Published only after its CPU upload finishes. Renderers never mutate this texture.
struct PreviewLUTTexture: @unchecked Sendable {
    let key: String
    let texture: any MTLTexture
    let dimension: Int
    let byteCount: Int
    var material: PreviewFilmMaterial? = nil
}

struct PreviewFilmMaterial: @unchecked Sendable {
    let density: any MTLTexture
    let paper: any MTLTexture
    let finish: any MTLTexture
    let maximum: SIMD3<Float>
    let refinement: SIMD4<Float>
    let identityFlags: UInt32
}

/// A separate serial worker keeps uploads out of drawing and out of the image-decoder queue.
/// A second cache check on that worker coalesces concurrent requests without duplicate uploads.
final class PreviewLUTTextureCache: Sendable {
    static let shared = PreviewLUTTextureCache()

    enum PreparationError: Error { case allocationFailed }

    private let worker: BlockingImageWork
    private let cache: OSAllocatedUnfairLock<ByteBudgetLRU<String, PreviewLUTTexture>>
    private let upload: @Sendable (String, CubeLUT) -> PreviewLUTTexture?

    /// Weak entries reuse tables already owned by a recipe or an in-flight frame.
    /// They add no GPU retention outside the existing recipe byte/entry budget.
    private final class MaterialTablePool: Sendable {
        private final class Entry: @unchecked Sendable {
            weak var texture: (any MTLTexture)?
            let dimension: Int
            let byteCount: Int

            init(_ value: PreviewLUTTexture) {
                texture = value.texture
                dimension = value.dimension
                byteCount = value.byteCount
            }
        }
        private let entries: OSAllocatedUnfairLock<ByteBudgetLRU<UUID, Entry>>

        init(maximumEntries: Int) {
            entries = OSAllocatedUnfairLock(initialState: ByteBudgetLRU(
                maximumBytes: 0, maximumEntries: maximumEntries))
        }

        func upload(key: String, table: FilmMaterial.Table) -> PreviewLUTTexture? {
            // Used only during background preparation, never by the draw callback.
            entries.withLock { cache in
                if let entry = cache.value(forKey: table.textureIdentifier), let texture = entry.texture {
                    return PreviewLUTTexture(key: key, texture: texture,
                        dimension: entry.dimension, byteCount: entry.byteCount)
                }
                guard let value = PreviewLUTTextureCache.upload(key: key, lut: table.cube) else { return nil }
                cache.insert(Entry(value), forKey: table.textureIdentifier, cost: 0)
                return value
            }
        }
    }

    init(worker: BlockingImageWork = BlockingImageWork(maximumConcurrentOperations: 1, label: "com.justshoot.preview-lut-upload"),
         maximumBytes: Int = 32 * 1_024 * 1_024, maximumEntries: Int = 8,
         upload: (@Sendable (String, CubeLUT) -> PreviewLUTTexture?)? = nil) {
        self.worker = worker
        cache = OSAllocatedUnfairLock(initialState: ByteBudgetLRU(
            maximumBytes: maximumBytes, maximumEntries: maximumEntries))
        let tables = MaterialTablePool(maximumEntries: min(max(0, maximumEntries), 32) * 4)
        self.upload = upload ?? { key, lut in Self.upload(key: key, lut: lut, tables: tables) }
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
        upload(key: key, lut: lut, tables: nil)
    }

    private static func upload(key: String, lut: CubeLUT, tables: MaterialTablePool?) -> PreviewLUTTexture? {
        if let material = lut.material {
            func table(_ value: FilmMaterial.Table) -> PreviewLUTTexture? {
                if let tables { return tables.upload(key: key, table: value) }
                return upload(key: key, lut: value.cube)
            }
            guard let input = table(material.input), let density = table(material.density),
                  let paper = table(material.print), let finish = table(material.finish) else { return nil }
            return PreviewLUTTexture(key: key, texture: input.texture, dimension: input.dimension,
                byteCount: input.byteCount + density.byteCount + paper.byteCount + finish.byteCount,
                material: PreviewFilmMaterial(density: density.texture, paper: paper.texture, finish: finish.texture,
                    maximum: material.densityMaximum, refinement: material.refinement,
                    identityFlags: (material.input.isIdentity ? 1 : 0) | (material.finish.isIdentity ? 2 : 0)))
        }
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
