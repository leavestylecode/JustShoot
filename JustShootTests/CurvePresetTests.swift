import XCTest
@testable import JustShoot

final class CurvePresetTests: XCTestCase {
    private func gray(_ preset: CurvePreset, _ input: Float) -> Float {
        CurveMath.sample(preset.previewData.master, at: input)
    }

    func testCatalogueContainsFiveDistinctPhotographicRoles() {
        let expected: Set<CurvePreset> = [.none, .filmSoft, .punch, .matte, .crossProcess]
        XCTAssertEqual(Set(CurvePreset.allCases), expected)
        XCTAssertEqual(Set(CurvePreset.allCases.map(\.id)).count, 5)
        XCTAssertTrue(FilmCurve.builtIn(.none).isNeutral)
        XCTAssertTrue(CurvePreset.allCases.filter { $0 != .none }.allSatisfy { !FilmCurve.builtIn($0).isNeutral })
    }

    func testBuiltinsStayFiniteMonotoneAndAvoidClippedOrAbruptToneSteps() {
        for preset in CurvePreset.allCases {
            let data = preset.previewData
            for table in [data.red, data.green, data.blue] {
                XCTAssertEqual(table.count, CurveMath.sampleCount, preset.rawValue)
                XCTAssertTrue(table.allSatisfy { $0.isFinite && (0...1).contains($0) }, preset.rawValue)
                for (before, after) in zip(table, table.dropFirst()) {
                    let slope = (after - before) * Float(table.count - 1)
                    XCTAssertGreaterThan(slope, 0.1, "\(preset.rawValue) must not reverse or flatten tones")
                    XCTAssertLessThan(slope, 2.5, "\(preset.rawValue) must not create an abrupt tone boundary")
                }
            }
        }
    }

    func testSoftLiftsShadowsLowersHighlightsAndReducesMidtoneContrast() {
        let shadow = gray(.filmSoft, 0.25)
        let highlight = gray(.filmSoft, 0.75)
        XCTAssertGreaterThan(shadow, gray(.none, 0.25))
        XCTAssertLessThan(highlight, gray(.none, 0.75))
        XCTAssertLessThan(highlight - shadow, gray(.none, 0.75) - gray(.none, 0.25))
        XCTAssertEqual(gray(.filmSoft, 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(gray(.filmSoft, 0), 0)
        XCTAssertEqual(gray(.filmSoft, 1), 1)
    }

    func testSCurveSeparatesMidtonesWithoutChangingBlackAndWhitePoints() {
        let shadow = gray(.punch, 0.25)
        let highlight = gray(.punch, 0.75)
        XCTAssertLessThan(shadow, gray(.none, 0.25))
        XCTAssertGreaterThan(highlight, gray(.none, 0.75))
        XCTAssertGreaterThan(highlight - shadow, gray(.none, 0.75) - gray(.none, 0.25))
        XCTAssertEqual(gray(.punch, 0), 0)
        XCTAssertEqual(gray(.punch, 1), 1)
    }

    func testMatteLiftsTheBlackPointAndKeepsBrightWhites() {
        XCTAssertGreaterThan(gray(.matte, 0), 0.03)
        XCTAssertLessThan(gray(.matte, 0), 0.12)
        XCTAssertGreaterThan(gray(.matte, 1), 0.95)
        XCTAssertLessThan(gray(.matte, 1), 1)
    }

    func testTonePresetsLeaveNeutralGraysNeutralWhileXProSplitsTheirColor() {
        for preset in [CurvePreset.none, .filmSoft, .punch, .matte] {
            XCTAssertEqual(preset.previewData.red, preset.previewData.green)
            XCTAssertEqual(preset.previewData.green, preset.previewData.blue)
        }
        let xpro = FilmCurve.builtIn(.crossProcess)
        let shadow = xpro.sampleGray(0.1)
        XCTAssertLessThan(shadow.red, shadow.green)
        XCTAssertLessThan(shadow.green, shadow.blue)
        XCTAssertGreaterThan(shadow.blue - shadow.red, 0.04)
        let highlight = xpro.sampleGray(0.8)
        XCTAssertGreaterThan(highlight.red, highlight.green)
        XCTAssertGreaterThan(highlight.green, highlight.blue)
        XCTAssertGreaterThan(highlight.red - highlight.blue, 0.08)
    }

    func testPresetRolesProduceDifferentResultsOnTheSameNeutralRamp() {
        let presets = CurvePreset.allCases
        for first in presets.indices {
            for second in presets.indices where second > first {
                let lhs = presets[first].previewData
                let rhs = presets[second].previewData
                let a = lhs.red + lhs.green + lhs.blue
                let b = rhs.red + rhs.green + rhs.blue
                let meanSquaredDifference = zip(a, b).reduce(Float(0)) {
                    let difference = $1.0 - $1.1
                    return $0 + difference * difference
                } / Float(a.count)
                XCTAssertGreaterThan(meanSquaredDifference.squareRoot(), 0.015,
                    "\(presets[first].rawValue) and \(presets[second].rawValue) must have distinct roles")
            }
        }
    }
}
