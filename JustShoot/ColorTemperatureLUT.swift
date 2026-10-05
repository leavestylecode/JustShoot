import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Build temperature and tint into the same immutable LUT consumed by preview, stills and Live Photos.
/// No capture-device white-balance setter is involved (virtual cameras can reject those setters).
actor ColorTemperatureLUT {
    static let shared = ColorTemperatureLUT()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var context: CIContext?
    private var cache: [String: CubeLUT] = [:]
    private var accessOrder: [String] = []
    private let maximumCacheBytes: Int
    private(set) var cachedBytes = 0
    var cachedCount: Int { cache.count }

    init(maximumCacheBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumCacheBytes = max(0, maximumCacheBytes)
    }

    nonisolated static func cacheKey(baseKey: String, selection: CameraWhiteBalanceSelection,
                                    tint: CameraTintSelection = .automatic,
                                    reference: CameraWhiteBalanceReading? = CameraWhiteBalanceReading.neutral) -> String {
        guard let resolved = ResolvedCameraColorAdjustment.resolve(temperature: selection, tint: tint, reading: reference) else {
            return baseKey + "#white-balance-unavailable"
        }
        guard !resolved.isNeutral else { return baseKey }
        return baseKey + "#wb-\(Int(resolved.temperature))-\(Int(resolved.tint))-ref-\(Int(resolved.reference.temperature))-\(Int(resolved.reference.tint))"
    }

    func prepare(source: FilmSource, curve: FilmCurve, selection: CameraWhiteBalanceSelection,
                 tint: CameraTintSelection = .automatic,
                 reference: CameraWhiteBalanceReading? = CameraWhiteBalanceReading.neutral) throws -> CubeLUT {
        try Task.checkCancellation()
        let processor = FilmProcessor.shared
        processor.preload(source: source, curve: curve)
        let baseKey = processor.composedLUTCacheKey(source.lutCacheKey, curve: curve)
        guard let base = processor.getCachedLUT(cacheKey: baseKey) else { throw CubeLUT.ParseError.malformed }
        return try prepare(base: base, baseKey: baseKey, selection: selection, tint: tint, reference: reference)
    }

    func prepare(base: CubeLUT, baseKey: String, selection: CameraWhiteBalanceSelection,
                 tint: CameraTintSelection = .automatic,
                 reference: CameraWhiteBalanceReading? = CameraWhiteBalanceReading.neutral) throws -> CubeLUT {
        try Task.checkCancellation()
        guard let resolved = ResolvedCameraColorAdjustment.resolve(temperature: selection, tint: tint, reading: reference) else {
            throw CubeLUT.ParseError.malformed
        }
        // Automatic axes keep the camera's current values; no-op recipes use the original bytes.
        guard !resolved.isNeutral else { return base }
        let key = Self.cacheKey(baseKey: baseKey, selection: selection, tint: tint, reference: reference)
        if let existing = cache[key] {
            touch(key)
            return existing
        }
        let result = try autoreleasepool { try bake(base: base, adjustment: resolved) }
        if result.data.count <= maximumCacheBytes {
            while cachedBytes + result.data.count > maximumCacheBytes || cache.count >= 8 {
                guard let oldest = accessOrder.first else { break }
                accessOrder.removeFirst()
                if let removed = cache.removeValue(forKey: oldest) { cachedBytes -= removed.data.count }
            }
            cache[key] = result
            cachedBytes += result.data.count
            touch(key)
        }
        return result
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func bake(base: CubeLUT, adjustment recipe: ResolvedCameraColorAdjustment) throws -> CubeLUT {
        let dimension = base.dimension
        guard (2...CubeLUT.maximumDimension).contains(dimension),
              base.data.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.stride else {
            throw CubeLUT.ParseError.malformed
        }
        let width = dimension * dimension
        let height = dimension
        let stride = 4 * MemoryLayout<Float>.stride
        let divisor = Float(dimension - 1)
        var samples = [Float](repeating: 1, count: width * height * 4)
        for blue in 0..<dimension {
            try Task.checkCancellation()
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let offset = (blue * dimension * dimension + green * dimension + red) * 4
                    samples[offset] = Float(red) / divisor
                    samples[offset + 1] = Float(green) / divisor
                    samples[offset + 2] = Float(blue) / divisor
                }
            }
        }
        let input = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: input, bytesPerRow: width * stride,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace)
        let adjustment = CIFilter.temperatureAndTint()
        adjustment.inputImage = image
        adjustment.neutral = CIVector(x: CGFloat(recipe.temperature), y: CGFloat(recipe.tint))
        adjustment.targetNeutral = CIVector(x: CGFloat(recipe.reference.temperature), y: CGFloat(recipe.reference.tint))
        guard let adjusted = adjustment.outputImage,
              let cube = CIFilter(name: "CIColorCubeWithColorSpace") else { throw CubeLUT.ParseError.malformed }
        cube.setValue(adjusted, forKey: kCIInputImageKey)
        cube.setValue(dimension, forKey: "inputCubeDimension")
        cube.setValue(base.data, forKey: "inputCubeData")
        cube.setValue(colorSpace, forKey: "inputColorSpace")
        guard let output = cube.outputImage else { throw CubeLUT.ParseError.malformed }
        if context == nil {
            // The table is small, not a camera frame. CPU rendering avoids competing with
            // the live viewfinder's GPU and happens only on this serial actor, never MainActor.
            context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace,
                .useSoftwareRenderer: true, .cacheIntermediates: false])
        }
        guard let context else { throw CubeLUT.ParseError.malformed }
        try Task.checkCancellation()
        var data = Data(count: input.count)
        try data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { throw CubeLUT.ParseError.malformed }
            let destination = CIRenderDestination(bitmapData: address, width: width, height: height,
                bytesPerRow: width * stride, format: .RGBAf)
            destination.colorSpace = colorSpace
            let task = try context.startTask(toRender: output, to: destination)
            _ = try task.waitUntilCompleted()
        }
        try Task.checkCancellation()
        return try CubeLUT.validated(data: data, dimension: dimension)
    }
}
