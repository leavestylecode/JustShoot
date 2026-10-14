import XCTest
@testable import JustShoot

final class CurveMathTests: XCTestCase {
    private func points(_ values: [(Float, Float)]) -> [CurveControlPoint] {
        values.map { CurveControlPoint(input: $0.0, output: $0.1) }
    }

    func testIdentityAndCollinearControlPointsPreserveEveryToneExactly() {
        for controls in [
            points([(0, 0), (1, 1)]),
            points([(0, 0), (0.125, 0.125), (0.5, 0.5), (0.875, 0.875), (1, 1)])
        ] {
            let table = CurveMath.expand(controls)
            XCTAssertEqual(table, CurveMath.identityTable)
            for value: Float in [0, 0.001, 0.08, 0.25, 0.5, 0.75, 0.999, 1] {
                XCTAssertEqual(CurveMath.sample(table, at: value), value, accuracy: 0.000001)
            }
        }
    }

    func testNonFiniteAndOutOfRangeSamplesCannotTrapOrEscapeTheDisplayRange() {
        for table in [CurveMath.identityTable, []] {
            XCTAssertEqual(CurveMath.sample(table, at: .nan), 0)
            XCTAssertEqual(CurveMath.sample(table, at: -.infinity), 0)
            XCTAssertEqual(CurveMath.sample(table, at: .infinity), 1)
            XCTAssertEqual(CurveMath.sample(table, at: -10), 0)
            XCTAssertEqual(CurveMath.sample(table, at: 10), 1)
        }
    }

    func testInvalidGeometryOrNonFiniteControlPointsFallBackToIdentity() {
        let invalid: [[CurveControlPoint]] = [
            [],
            points([(0, 0)]),
            points([(0.1, 0), (1, 1)]),
            points([(0, 0), (0.9, 1)]),
            points([(0, 0), (0.5, 0.4), (0.5, 0.6), (1, 1)]),
            points([(0, 0), (0.7, 0.4), (0.3, 0.6), (1, 1)]),
            points([(0, 0), (-0.1, 0.2), (1, 1)]),
            points([(0, 0), (1.1, 0.8), (1, 1)]),
            points([(0, -0.1), (1, 1)]),
            points([(0, 0), (1, 1.1)]),
            points([(0, 0), (.nan, 0.5), (1, 1)]),
            points([(0, 0), (0.5, .infinity), (1, 1)]),
            points([(0, 0), (0.5, .nan), (1, 1)])
        ]
        for controls in invalid {
            XCTAssertEqual(CurveMath.expand(controls), CurveMath.identityTable)
        }
    }

    func testEditableControlPointsStayContinuousAtTheToneTheyTarget() {
        let controls = points([(0, 0.05), (0.21, 0.28), (0.58, 0.64), (0.83, 0.90), (1, 0.97)])
        let table = CurveMath.expand(controls)
        XCTAssertEqual(table.count, CurveMath.sampleCount)
        for point in controls {
            let value = CurveMath.sample(table, at: point.input)
            XCTAssertEqual(value, point.output, accuracy: 0.0005)
            if point.input > 0 && point.input < 1 {
                let before = CurveMath.sample(table, at: point.input - 0.0001)
                let after = CurveMath.sample(table, at: point.input + 0.0001)
                XCTAssertLessThan(abs(before - value), 0.0005)
                XCTAssertLessThan(abs(after - value), 0.0005)
            }
        }
        XCTAssertTrue(table.allSatisfy { $0.isFinite && (0...1).contains($0) })
    }

    func testArtistCurvesCanIntentionallyInvertTones() {
        let table = CurveMath.expand(points([(0, 1), (0.5, 0.5), (1, 0)]))
        XCTAssertEqual(CurveMath.sample(table, at: 0), 1)
        XCTAssertEqual(CurveMath.sample(table, at: 1), 0)
        XCTAssertGreaterThan(CurveMath.sample(table, at: 0.2), CurveMath.sample(table, at: 0.8))
        XCTAssertTrue(table.allSatisfy { $0.isFinite && (0...1).contains($0) })
    }

    func testExistingCustomNaturalSplineCharacterIsNotReplacedByAMonotoneInterpolator() {
        // Legacy user curves use natural splines, which may reverse between monotone nodes.
        // Preserve that authored response while keeping the safer builtin node sets separate.
        let table = CurveMath.expand(points([(0, 0), (0.2, 0.7), (0.6, 0.701), (1, 1)]))
        XCTAssertTrue(zip(table, table.dropFirst()).contains { $0.1 < $0.0 - 0.00001 })
        XCTAssertGreaterThan(CurveMath.sample(table, at: 0.35), CurveMath.sample(table, at: 0.6))
    }
}
