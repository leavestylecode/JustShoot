import CoreImage
import XCTest
@testable import JustShoot

final class FilmLargeCubeTests: XCTestCase {
    func testLargeCubesKeepEveryNodeInterpolationAndPremultipliedAlpha() throws {
        let space = FilmImagePipeline.colorSpace
        let colors: [SIMD4<Float>] = [SIMD4(0.13, 0.47, 0.89, 1), SIMD4(0.73, 0.24, 0.58, 0.4), .zero]
        let source = colors.flatMap { [$0.x * $0.w, $0.y * $0.w, $0.z * $0.w, $0.w] }
        let image = CIImage(bitmapData: source.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: colors.count * 16, size: CGSize(width: colors.count, height: 1), format: .RGBAf, colorSpace: space)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        for dimension in [65, CubeLUT.maximumDimension] {
            let divisor = Float(dimension - 1)
            var nodes = [Float]()
            nodes.reserveCapacity(dimension * dimension * dimension * 4)
            for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
                nodes += [pow(Float(r) / divisor, 2) * 0.75,
                          pow(Float(g) / divisor, 2) * 0.75,
                          pow(Float(b) / divisor, 2) * 0.75, 0.75]
            } } }
            let lut = try CubeLUT.validated(data: nodes.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: dimension)
            let output = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: lut)?.applying(to: image))
            var pixels = [Float](repeating: 0, count: source.count)
            context.render(output, toBitmap: &pixels, rowBytes: colors.count * 16, bounds: image.extent,
                format: .RGBAf, colorSpace: space)
            for (index, color) in colors.enumerated() {
                for channel in 0..<3 {
                    let position = color[channel] * divisor
                    let low = floor(position) / divisor
                    let high = min(floor(position) + 1, divisor) / divisor
                    let fraction = position - floor(position)
                    let expected = (low * low * (1 - fraction) + high * high * fraction) * 0.75 * color.w
                    XCTAssertEqual(pixels[index * 4 + channel], expected, accuracy: 0.001,
                        "\(dimension)³, pixel \(index), channel \(channel)")
                }
                XCTAssertEqual(pixels[index * 4 + 3], 0.75 * color.w, accuracy: 0.001)
            }
        }
    }
}
