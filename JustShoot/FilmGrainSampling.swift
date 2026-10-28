import Foundation
import os

/// Match the variance of a reduced 4000-pixel film frame rather than making every
/// small preview pixel carry one full-resolution grain sample. No image readback.
enum FilmGrainSampling {
    private struct Key: Hashable {
        let size: Float
        let longEdge: Int
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Key: Float]())

    static func amplitudeScale(size: Float, longEdge: CGFloat) -> Float {
        guard size.isFinite, longEdge.isFinite, size > 0, longEdge > 0 else { return 0 }
        guard longEdge < 4_000 else { return 1 }
        let key = Key(size: size, longEdge: max(1, Int(longEdge.rounded())))
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let scale = calculate(size: size, longEdge: Float(key.longEdge))
        cache.withLock {
            // Bound resize/custom-ISO combinations for the lifetime of the process.
            if $0.count >= 128 { $0.removeAll(keepingCapacity: true) }
            $0[key] = scale
        }
        return scale
    }

    private static func smooth(_ value: Float) -> Float { value * value * (3 - 2 * value) }

    private static func calculate(size: Float, longEdge: Float) -> Float {
        let footprint = 4_000 / longEdge
        // The very small thumbnail limit follows the 1/area noise-variance law.
        let measuredFootprint = min(64, footprint)
        let referenceSize = max(1, size)
        let previewSize = max(1, size * longEdge / 4_000)
        var broadVariance: Float = 0
        var fineVariance: Float = 0
        var previewVariance: Float = 0
        // Separable value noise: sum squared interpolation weights in one axis,
        // then square that expectation for the two-dimensional film plane.
        for phase in 0..<32 {
            let start = Float(phase * 127) * measuredFootprint
            let end = start + measuredFootprint
            var coefficients: [Int: Float] = [:]
            var fine: Float = 0
            for pixel in Int(floor(start))..<Int(ceil(end)) {
                let overlap = max(0, min(end, Float(pixel + 1)) - max(start, Float(pixel)))
                let weight = overlap / measuredFootprint
                let point = (Float(pixel) + 0.5) / referenceSize
                let cell = Int(floor(point))
                let blend = smooth(point - Float(cell))
                coefficients[cell, default: 0] += weight * (1 - blend)
                coefficients[cell + 1, default: 0] += weight * blend
                fine += weight * weight
            }
            broadVariance += coefficients.values.reduce(0) { $0 + $1 * $1 }
            fineVariance += fine
            let point = (Float(phase * 127) + 0.5) / previewSize
            let blend = smooth(point - floor(point))
            previewVariance += (1 - blend) * (1 - blend) + blend * blend
        }
        broadVariance /= 32
        fineVariance /= 32
        previewVariance /= 32
        // Same 82/18 broad/fine mixture as the balanced Metal/CI grain kernel.
        let target = 0.82 * 0.82 * broadVariance * broadVariance
            + 0.18 * 0.18 * fineVariance * fineVariance
        let source = 0.82 * 0.82 * previewVariance * previewVariance + 0.18 * 0.18
        return min(1, sqrt(target / source) * measuredFootprint / footprint)
    }
}
