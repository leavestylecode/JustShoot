import Foundation

/// Nonlinear curves need more than the corner samples of a small color cube. Preserve the
/// original trilinear film response on a denser grid before applying the per-channel curve.
enum CurveLUTComposer {
    static let minimumDimension = 33

    static func preparedSource(_ lut: CubeLUT) -> CubeLUT {
        guard (2...CubeLUT.maximumDimension).contains(lut.dimension),
              lut.data.count == lut.dimension * lut.dimension * lut.dimension * 4 * MemoryLayout<Float>.stride,
              lut.dimension < minimumDimension else { return lut }

        // Data may not be Float-aligned. Read once, retaining extended RGB and alpha values.
        let source = lut.data.withUnsafeBytes { bytes in
            (0..<(bytes.count / MemoryLayout<Float>.stride)).map {
                bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.stride, as: Float.self)
            }
        }
        guard source.allSatisfy(\.isFinite) else { return lut }
        let sourceDimension = lut.dimension
        let dimension = minimumDimension
        let scale = Double(sourceDimension - 1) / Double(dimension - 1)
        var output = [Float](repeating: 0, count: dimension * dimension * dimension * 4)

        func index(_ red: Int, _ green: Int, _ blue: Int, _ channel: Int) -> Int {
            ((blue * sourceDimension + green) * sourceDimension + red) * 4 + channel
        }
        // Double intermediates also keep interpolation of large finite Float values finite.
        func mix(_ a: Double, _ b: Double, _ fraction: Double) -> Double {
            a * (1 - fraction) + b * fraction
        }

        for blue in 0..<dimension {
            let bluePosition = Double(blue) * scale
            let blue0 = Int(bluePosition), blue1 = min(blue0 + 1, sourceDimension - 1)
            let blueFraction = bluePosition - Double(blue0)
            for green in 0..<dimension {
                let greenPosition = Double(green) * scale
                let green0 = Int(greenPosition), green1 = min(green0 + 1, sourceDimension - 1)
                let greenFraction = greenPosition - Double(green0)
                for red in 0..<dimension {
                    let redPosition = Double(red) * scale
                    let red0 = Int(redPosition), red1 = min(red0 + 1, sourceDimension - 1)
                    let redFraction = redPosition - Double(red0)
                    let destination = ((blue * dimension + green) * dimension + red) * 4
                    for channel in 0..<4 {
                        let lower0 = mix(Double(source[index(red0, green0, blue0, channel)]),
                            Double(source[index(red1, green0, blue0, channel)]), redFraction)
                        let lower1 = mix(Double(source[index(red0, green1, blue0, channel)]),
                            Double(source[index(red1, green1, blue0, channel)]), redFraction)
                        let upper0 = mix(Double(source[index(red0, green0, blue1, channel)]),
                            Double(source[index(red1, green0, blue1, channel)]), redFraction)
                        let upper1 = mix(Double(source[index(red0, green1, blue1, channel)]),
                            Double(source[index(red1, green1, blue1, channel)]), redFraction)
                        output[destination + channel] = Float(mix(
                            mix(lower0, lower1, greenFraction), mix(upper0, upper1, greenFraction), blueFraction))
                    }
                }
            }
        }
        return CubeLUT(data: output.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: dimension)
    }
}
