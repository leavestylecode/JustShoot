import XCTest
@testable import JustShoot

final class CurveLUTComposerTests: XCTestCase {
    private func cube(dimension: Int, value: (Float, Float, Float) -> [Float]) throws -> CubeLUT {
        var values: [Float] = []
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let denominator = Float(dimension - 1)
                    values.append(contentsOf: value(Float(red) / denominator, Float(green) / denominator,
                        Float(blue) / denominator))
                }
            }
        }
        return try CubeLUT.validated(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: dimension)
    }

    private func node(_ lut: CubeLUT, red: Int, green: Int, blue: Int) -> [Float] {
        let offset = ((blue * lut.dimension + green) * lut.dimension + red) * 16
        return lut.data.withUnsafeBytes { bytes in
            (0..<4).map { bytes.loadUnaligned(fromByteOffset: offset + $0 * 4, as: Float.self) }
        }
    }

    func testTwoAndThreePointIdentityCubesActuallyRenderSoftAndSCurveTones() throws {
        for dimension in [2, 3] {
            let original = try cube(dimension: dimension) { [$0, $1, $2, 1] }
            for preset in [CurvePreset.filmSoft, .punch] {
                let curve = FilmCurve.builtIn(preset)
                let composed = curve.applied(to: original)
                XCTAssertGreaterThanOrEqual(composed.dimension, 33)
                let quarter = (composed.dimension - 1) / 4
                let threeQuarters = quarter * 3
                let shadow = node(composed, red: quarter, green: quarter, blue: quarter)
                let highlight = node(composed, red: threeQuarters, green: threeQuarters, blue: threeQuarters)
                let selectedShadow = curve.sampleGray(0.25)
                let selectedHighlight = curve.sampleGray(0.75)
                XCTAssertEqual(shadow[0], selectedShadow.red, accuracy: 0.000001)
                XCTAssertEqual(shadow[1], selectedShadow.green, accuracy: 0.000001)
                XCTAssertEqual(shadow[2], selectedShadow.blue, accuracy: 0.000001)
                XCTAssertEqual(highlight[0], selectedHighlight.red, accuracy: 0.000001)
                XCTAssertEqual(shadow[3], 1)
                if preset == .filmSoft {
                    XCTAssertGreaterThan(shadow[0], 0.25)
                    XCTAssertLessThan(highlight[0], 0.75)
                } else {
                    XCTAssertLessThan(shadow[0], 0.25)
                    XCTAssertGreaterThan(highlight[0], 0.75)
                }
            }
        }
    }

    func testTrilinearUpsamplingPreservesAnAffineRGBAFilmIncludingHDRValues() throws {
        func response(_ red: Float, _ green: Float, _ blue: Float) -> [Float] {
            [-0.2 + red * 1.4 + green * 0.1, green * 0.7 + blue * 0.2,
             -0.1 + blue * 1.5 + red * 0.1, 0.25 + red * 0.15 + green * 0.2 + blue * 0.2]
        }
        for dimension in [2, 3, 17, 25, 32] {
            let original = try cube(dimension: dimension, value: response)
            let prepared = CurveLUTComposer.preparedSource(original)
            XCTAssertEqual(prepared.dimension, 33)
            for coordinate in [(0, 0, 0), (32, 32, 32), (3, 11, 27), (29, 7, 17), (16, 16, 16)] {
                let expected = response(Float(coordinate.0) / 32, Float(coordinate.1) / 32, Float(coordinate.2) / 32)
                let actual = node(prepared, red: coordinate.0, green: coordinate.1, blue: coordinate.2)
                for channel in 0..<4 { XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.000001) }
            }
            XCTAssertLessThan(node(prepared, red: 0, green: 0, blue: 0)[0], 0)
            XCTAssertGreaterThan(node(prepared, red: 32, green: 32, blue: 32)[2], 1)
        }
    }

    func testAlreadyDenseCubesAndNeutralCurvesKeepTheirOriginalBytes() throws {
        for dimension in [33, 64] {
            let original = try cube(dimension: dimension) { [$0, $1, $2, 1] }
            let prepared = CurveLUTComposer.preparedSource(original)
            XCTAssertEqual(prepared.dimension, original.dimension)
            XCTAssertEqual(prepared.data, original.data)
        }
        let small = try cube(dimension: 2) { [-0.2 + $0 * 1.5, $1, $2, 1] }
        let neutral = FilmCurve.builtIn(.none).applied(to: small)
        XCTAssertEqual(neutral.dimension, 2)
        XCTAssertEqual(neutral.data, small.data)
    }

    func testInvalidStructuresReturnWithoutOverflowOrChangingTheirPayload() {
        for invalid in [CubeLUT(data: Data(), dimension: Int.max), CubeLUT(data: Data(), dimension: Int.min),
                        CubeLUT(data: Data([1, 2, 3]), dimension: 2), CubeLUT(data: Data(), dimension: 1)] {
            let prepared = CurveLUTComposer.preparedSource(invalid)
            XCTAssertEqual(prepared.dimension, invalid.dimension)
            XCTAssertEqual(prepared.data, invalid.data)
        }
    }

    func testLargeFiniteOppositeValuesDoNotOverflowDuringInterpolation() throws {
        let maximum = Float.greatestFiniteMagnitude
        let source = try cube(dimension: 2) { red, green, blue in
            [red == 0 ? -maximum : maximum, green, blue, 1]
        }
        let prepared = CurveLUTComposer.preparedSource(source)
        XCTAssertEqual(node(prepared, red: 16, green: 16, blue: 16)[0], 0)
        XCTAssertEqual(node(prepared, red: 0, green: 0, blue: 0)[0], -maximum)
        XCTAssertEqual(node(prepared, red: 32, green: 32, blue: 32)[0], maximum)
        XCTAssertNoThrow(try CubeLUT.validated(data: prepared.data, dimension: prepared.dimension))
    }
}
