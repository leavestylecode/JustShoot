import SwiftUI
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
        XCTAssertEqual(definition.filmCurve.previewData.sharedRGBResponse, CurveMath.expand(points))
        definition.bluePoints = CurveMath.identityPoints
        XCTAssertTrue(definition.filmCurve.usesChannelCurves)
        XCTAssertNil(definition.filmCurve.previewData.sharedRGBResponse)
    }

    func testPlotMapsEveryRenderedChannelSampleToInputAndOutputCoordinates() {
        let bounds = CGRect(x: 12, y: 8, width: 255, height: 255)
        let pathPrecision = CGFloat(Float(max(bounds.maxX, bounds.maxY)).ulp)
        let rgb = CurvePreset.crossProcess.previewData
        for samples in [CurveMath.identityTable, rgb.red, rgb.green, rgb.blue] {
            var positions: [CGPoint] = []
            ToneCurvePlot.path(for: samples, in: bounds).forEach { element in
                switch element {
                case .move(let point), .line(let point): positions.append(point)
                default: XCTFail("A transfer curve must follow the sampled response")
                }
            }
            XCTAssertEqual(positions.count, 256)
            for (input, point) in positions.enumerated() {
                XCTAssertEqual(point.x, bounds.minX + CGFloat(input), accuracy: pathPrecision)
                XCTAssertEqual(point.y, bounds.maxY - CGFloat(samples[input]) * 255, accuracy: pathPrecision)
            }
        }
    }

    func testDifferenceShadingFollowsBothSidesOfTheDiagonal() throws {
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 200)
        let response = ToneCurvePlot.path(for: [0.2, 0.5, 0.8], in: bounds)
        let area = ToneCurvePlot.differenceArea(for: response, in: bounds)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 224, height: 224, bitsPerComponent: 8,
            bytesPerRow: 224, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.translateBy(x: 0, y: CGFloat(bitmap.height))
        bitmap.scaleBy(x: 1, y: -1)
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(bounds)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.addPath(area.cgPath)
        bitmap.drawPath(using: .eoFill)
        let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        func isShaded(input: CGFloat, output: CGFloat) -> Bool {
            let point = ToneCurvePlot.position(input: input, output: output, in: bounds)
            return pixels[Int(point.y) * bitmap.bytesPerRow + Int(point.x)] > 0
        }

        XCTAssertTrue(isShaded(input: 0.25, output: 0.30))
        XCTAssertFalse(isShaded(input: 0.25, output: 0.20))
        XCTAssertFalse(isShaded(input: 0.25, output: 0.40))
        XCTAssertTrue(isShaded(input: 0.75, output: 0.70))
        XCTAssertFalse(isShaded(input: 0.75, output: 0.60))
        XCTAssertFalse(isShaded(input: 0.75, output: 0.80))
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
