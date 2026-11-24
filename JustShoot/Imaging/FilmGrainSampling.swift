import Foundation
import os

/// Match the variance of a reduced 4000-pixel film frame rather than making every
/// small preview pixel carry one full-resolution grain sample. No image readback.
enum FilmGrainSampling {
    struct Adjustment: Sendable {
        var scale: Float
        var broadOffset: Float = 0
        var fineOffset: Float = 0
        var fineWeight: Float = 0.22

        static let native = Self(scale: 1)
    }

    private struct Key: Hashable {
        let size: Float
        let longEdge: Int
        let response: FilmGrainParameters.Response
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Key: Adjustment]())

    static func adjustment(size: Float, longEdge: CGFloat,
                           response: FilmGrainParameters.Response) -> Adjustment {
        guard size.isFinite, longEdge.isFinite, size > 0, longEdge > 0 else { return .init(scale: 0) }
        guard longEdge < 4_000 else { return .native }
        let key = Key(size: size, longEdge: max(1, Int(longEdge.rounded())), response: response)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let scale = calculate(size: size, longEdge: Float(key.longEdge), response: response)
        cache.withLock {
            // Bound resize/custom-ISO combinations for the lifetime of the process.
            if $0.count >= 128 { $0.removeAll(keepingCapacity: true) }
            $0[key] = scale
        }
        return scale
    }

    private static func smooth(_ value: Float) -> Float { value * value * (3 - 2 * value) }

    private static func transition(_ value: Float, from start: Float, to end: Float) -> Float {
        smooth(max(0, min(1, (value - start) / (end - start))))
    }

    private static func calculate(size: Float, longEdge: Float,
                                  response: FilmGrainParameters.Response) -> Adjustment {
        let footprint = 4_000 / longEdge
        // The very small thumbnail limit follows the 1/area noise-variance law.
        let measuredFootprint = min(64, footprint)
        let thumbnailScale = measuredFootprint / footprint
        // Rejoin the native response continuously as the output approaches the reference frame.
        let nativeWeight = transition(longEdge, from: 2_400, to: 4_000)
        if response == .fujifilmFineFiltered {
            let broad = filteredBand(size: size, longEdge: longEdge, footprint: measuredFootprint,
                                     thumbnailScale: thumbnailScale, nativeWeight: nativeWeight)
            let fine = filteredBand(size: size * 0.65, longEdge: longEdge, footprint: measuredFootprint,
                                    thumbnailScale: thumbnailScale, nativeWeight: nativeWeight)
            let total = 0.78 * broad.scale + 0.22 * fine.scale
            return Adjustment(scale: total, broadOffset: broad.offset, fineOffset: fine.offset,
                              fineWeight: 0.22 * fine.scale / total)
        }

        let broad = variancesPerAxis(size: size, longEdge: longEdge, footprint: measuredFootprint)
        let target: Float
        let source: Float
        if response == .fujifilmFine {
            // Same two independent, interpolated bands as the Metal/CI grain kernel.
            let fine = variancesPerAxis(size: size * 0.65, longEdge: longEdge, footprint: measuredFootprint)
            target = 0.78 * 0.78 * broad.reduced * broad.reduced + 0.22 * 0.22 * fine.reduced * fine.reduced
            source = 0.78 * 0.78 * broad.preview * broad.preview + 0.22 * 0.22 * fine.preview * fine.preview
        } else {
            // Preserve the area response frozen in older recipes.
            target = 0.82 * 0.82 * broad.reduced * broad.reduced
                + 0.18 * 0.18 * broad.reducedPixelNoise * broad.reducedPixelNoise
            source = 0.82 * 0.82 * broad.preview * broad.preview + 0.18 * 0.18
        }
        let scale = min(1, sqrt(target / source) * thumbnailScale)
        return Adjustment(scale: response == .balancedContinuous ? scale + (1 - scale) * nativeWeight : scale)
    }

    private static func filteredBand(size: Float, longEdge: Float, footprint: Float, thumbnailScale: Float,
                                     nativeWeight: Float) -> (scale: Float, offset: Float) {
        // Before the native lattice resolves, choose a two-tap filter from the
        // covariance of adjacent reduced pixels. Restore native sampling before
        // the lattice grows past one output pixel.
        let latticeLimit = 4_000 / max(1, size)
        let filtering = 1 - transition(longEdge, from: latticeLimit * 0.80, to: latticeLimit)
        let axis = variancesPerAxis(size: size, longEdge: longEdge, footprint: footprint,
                                    measureAdjacent: filtering > 0)
        let correlation = min(0.5, max(0, axis.adjacent / axis.reduced * thumbnailScale))
        let blend = (1 - sqrt((1 - 2 * correlation) / (1 + 2 * correlation))) * 0.5
        // Invert smoothstep to express that blend as a phase of the existing noise lattice.
        let offset = -sin(asin(1 - 2 * blend) / 3) * filtering
        let shiftedBlend = smooth(0.5 + offset)
        let previewVariance = filtering > 0 ? (1 - shiftedBlend) * (1 - shiftedBlend)
            + shiftedBlend * shiftedBlend : axis.preview
        // Separable in two axes, so the ratio of axis variances is the 2D amplitude ratio.
        let scale = min(1, axis.reduced / previewVariance * thumbnailScale)
        return (scale + (1 - scale) * nativeWeight, offset)
    }

    private static func variancesPerAxis(size: Float, longEdge: Float, footprint: Float,
                                         measureAdjacent: Bool = false)
        -> (reduced: Float, preview: Float, reducedPixelNoise: Float, adjacent: Float) {
        let referenceSize = max(1, size)
        let previewSize = max(1, size * longEdge / 4_000)
        var broadVariance: Float = 0
        var fineVariance: Float = 0
        var previewVariance: Float = 0
        var adjacentCovariance: Float = 0
        // Separable value noise: sum squared weights on one axis. The caller
        // squares these averages for the two-dimensional film plane.
        for phase in 0..<32 {
            let start = Float(phase * 127) * footprint
            let (coefficients, fine) = boxWeights(start: start, footprint: footprint, size: referenceSize)
            if measureAdjacent {
                let (neighbor, _) = boxWeights(start: start + footprint, footprint: footprint, size: referenceSize)
                adjacentCovariance += coefficients.reduce(0) { $0 + $1.value * neighbor[$1.key, default: 0] }
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
        return (broadVariance, previewVariance, fineVariance, adjacentCovariance / 32)
    }

    private static func boxWeights(start: Float, footprint: Float, size: Float) -> ([Int: Float], Float) {
        let end = start + footprint
        var coefficients: [Int: Float] = [:]
        var pixelVariance: Float = 0
        for pixel in Int(floor(start))..<Int(ceil(end)) {
            let overlap = max(0, min(end, Float(pixel + 1)) - max(start, Float(pixel)))
            let weight = overlap / footprint
            let point = (Float(pixel) + 0.5) / size
            let cell = Int(floor(point))
            let blend = smooth(point - Float(cell))
            coefficients[cell, default: 0] += weight * (1 - blend)
            coefficients[cell + 1, default: 0] += weight * blend
            pixelVariance += weight * weight
        }
        return (coefficients, pixelVariance)
    }
}
