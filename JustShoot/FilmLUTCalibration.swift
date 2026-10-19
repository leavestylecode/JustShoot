import Foundation

/// Conservative output-tone calibration for the two portrait stocks. Baked once
/// into the bundled LUT, before user curves, so all renderers consume identical
/// bytes. Custom LUTs and LUT snapshots in pending capture jobs are untouched.
enum FilmLUTCalibration {
    static func applying(to lut: CubeLUT, resourceName: String) -> CubeLUT {
        let points: [CurveControlPoint]
        switch resourceName {
        case FilmPreset.kodakPortra400.lutResourceName:
            points = [(0, 0), (0.12, 0.145), (0.30, 0.325), (0.60, 0.575), (0.82, 0.805), (1, 1)]
                .map { CurveControlPoint(input: $0.0, output: $0.1) }
        case FilmPreset.fujiPro400H.lutResourceName:
            points = [(0, 0), (0.12, 0.140), (0.30, 0.315), (0.60, 0.585), (0.82, 0.810), (1, 1)]
                .map { CurveControlPoint(input: $0.0, output: $0.1) }
        default:
            return lut
        }

        let table = CurveMath.expand(points)
        let source = CurveLUTComposer.preparedSource(lut)
        var values = source.data.withUnsafeBytes { bytes in
            (0..<(bytes.count / MemoryLayout<Float>.stride)).map {
                bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.stride, as: Float.self)
            }
        }
        for offset in stride(from: 0, to: values.count, by: 4) {
            let rgb = SIMD3<Float>(values[offset], values[offset + 1], values[offset + 2])
            let luminance = rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
            var mapped = CurveMath.sample(table, at: luminance)
            if resourceName == FilmPreset.fujiPro400H.lutResourceName {
                // Open low dark-grays by at most 0.0065, with about 6% less
                // contrast around 0.15. The quadratic reaches zero with zero
                // slope at 0.30, avoiding a compensating contrast spike above it.
                let distance = max(0.30 - mapped, 0)
                mapped += distance * distance * 0.20 * smoothstep(0.075, 0.12, mapped)
            }
            let chroma = rgb - SIMD3<Float>(repeating: luminance)
            // Move along the neutral axis; reduce chroma only when necessary to
            // stay in gamut. Per-channel curves would rotate skin-tone hues.
            var chromaScale: Float = 1
            for component in [chroma.x, chroma.y, chroma.z] {
                if component > 0 { chromaScale = min(chromaScale, (1 - mapped) / component) }
                if component < 0 { chromaScale = min(chromaScale, -mapped / component) }
            }
            let output = SIMD3<Float>(repeating: mapped) + chroma * max(chromaScale, 0)
            values[offset] = output.x
            values[offset + 1] = output.y
            values[offset + 2] = output.z
        }
        return CubeLUT(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: source.dimension)
    }

    private static func smoothstep(_ lower: Float, _ upper: Float, _ value: Float) -> Float {
        let t = min(max((value - lower) / (upper - lower), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
