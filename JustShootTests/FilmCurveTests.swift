import XCTest
@testable import JustShoot

final class FilmCurveTests: XCTestCase {
    func testStartingFromAPresetReproducesItsResponse() {
        for preset in CurvePreset.allCases {
            var definition = CustomFilmCurve(name: "Template")
            definition.applyTemplate(preset)
            let custom = definition.filmCurve.previewData
            let builtIn = preset.previewData
            XCTAssertEqual(custom.red, builtIn.red, preset.rawValue)
            XCTAssertEqual(custom.green, builtIn.green, preset.rawValue)
            XCTAssertEqual(custom.blue, builtIn.blue, preset.rawValue)
        }
    }

    func testResetAndCollinearCustomPointsAreNeutral() {
        var definition = CustomFilmCurve(name: "Reset")
        definition.applyTemplate(.crossProcess)
        XCTAssertFalse(definition.filmCurve.isNeutral)
        definition.resetAllChannels()
        definition.masterPoints.insert(CurveControlPoint(input: 0.4, output: 0.4), at: 1)
        XCTAssertTrue(definition.filmCurve.isNeutral)
        XCTAssertEqual(definition.filmCurve.cacheKeySuffix, "")
    }

    func testComposedInverseChannelsRecognizeTheEffectiveIdentity() {
        var definition = CustomFilmCurve(name: "Double inverse")
        let inverse = CurveMath.points([(0, 1), (1, 0)])
        definition.masterPoints = inverse
        definition.redPoints = inverse
        definition.greenPoints = inverse
        definition.bluePoints = inverse
        XCTAssertTrue(definition.filmCurve.isNeutral)
    }

    func testEqualRGBResponsesUseASinglePreviewLine() {
        var definition = CustomFilmCurve(name: "RGB together")
        let points = CurveMath.points([(0, 0.1), (1, 0.9)])
        definition.redPoints = points
        definition.greenPoints = points
        definition.bluePoints = points
        XCTAssertFalse(definition.filmCurve.usesChannelCurves)
        definition.bluePoints = CurveMath.identityPoints
        XCTAssertTrue(definition.filmCurve.usesChannelCurves)
    }

    func testCacheIdentityTracksPixelsWhileIgnoringMetadataChanges() {
        var definition = CustomFilmCurve(name: "Original")
        definition.applyTemplate(.matte)
        let key = definition.filmCurve.cacheKeySuffix
        definition.name = "Renamed"
        definition.isVisible = false
        definition.updatedAt = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(definition.filmCurve.cacheKeySuffix, key)
        definition.redPoints = CurveMath.points([(0, 0.02), (1, 1)])
        XCTAssertNotEqual(definition.filmCurve.cacheKeySuffix, key)
    }

    func testLegacyFixedPointCurvesKeepTheirChannelsWhenDecoded() throws {
        let object: [String: Any] = [
            "name": "Legacy", "masterOutputs": [0, 0.2, 0.5, 0.8, 1],
            "redOutputs": [0.04, 0.3, 0.5, 0.7, 0.98]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let curve = try JSONDecoder().decode(CustomFilmCurve.self, from: data)
        XCTAssertEqual(curve.masterPoints.map(\.output), [0, 0.2, 0.5, 0.8, 1])
        XCTAssertEqual(curve.redPoints.map(\.output), [0.04, 0.3, 0.5, 0.7, 0.98])
        XCTAssertEqual(curve.greenPoints.map(\.input), CurveMath.legacyEditorInputs)
        XCTAssertEqual(curve.greenPoints.map(\.output), CurveMath.legacyEditorInputs)
        XCTAssertEqual(try JSONDecoder().decode(CustomFilmCurve.self,
            from: JSONEncoder().encode(curve)), curve)
    }
}
