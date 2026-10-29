import XCTest
@testable import JustShoot

final class PhotoCapturePlanTests: XCTestCase {
    func testNative24MPUsesProcessedSourceInsteadOf12MPProRAW() {
        let pro = CameraRAWFormat(pixelFormat: 1, kind: .appleProRAW)
        let plan = PhotoCapturePlan.resolve(mode: .quality, rawFormat: pro, prefersProcessedPhoto: true)
        XCTAssertEqual(plan.format, .processed)
        XCTAssertEqual(plan.inputSpace, .displaySRGB)
        XCTAssertTrue(plan.accepts(rawRecipe: nil))
        XCTAssertEqual(PhotoCapturePlan.resolve(mode: .livePhoto, rawFormat: pro,
            prefersProcessedPhoto: true).format, .livePhoto)
        XCTAssertTrue(PhotoCapturePlan.resolve(mode: .quality, rawFormat: pro,
            prefersProcessedPhoto: false).capturesRAW)
    }
    func testEveryLookPrefersProRAWInQualityMode() {
        let pro = CameraRAWFormat(pixelFormat: 1, kind: .appleProRAW)
        for preset in FilmPreset.allCases {
            let source = FilmSource.preset(preset)
            let plan = PhotoCapturePlan.resolve(mode: .quality, rawFormat: pro)
            XCTAssertTrue(plan.isValid)
            XCTAssertTrue(plan.capturesRAW)
            XCTAssertEqual(plan.inputSpace, source.inputSpace)
            XCTAssertFalse(plan.approximateLook)
            XCTAssertEqual(source.captureRenderProfile.effectiveChromatic.responseGain(sceneCCT: 3_200), .one)
        }
    }

    func testBayerDoesNotSilentlyReplaceComputationalProRAWAndFallbackIsExplicit() {
        let bayer = CameraRAWFormat(pixelFormat: 2, kind: .bayerRAW)
        for capability: CameraRAWFormat? in [nil, bayer] {
            let fuji = PhotoCapturePlan.resolve(mode: .quality, rawFormat: capability)
            XCTAssertEqual(fuji.format, .processed)
            XCTAssertEqual(fuji.inputSpace, .displaySRGB)
            XCTAssertFalse(fuji.approximateLook)
            XCTAssertEqual(fuji.version, 2)
            let portra = PhotoCapturePlan.resolve(mode: .quality, rawFormat: capability)
            XCTAssertFalse(portra.approximateLook)
        }
    }

    func testLiveAlwaysUsesDisplayInputAndRoundTripsFrozenPlan() throws {
        let plan = PhotoCapturePlan.resolve(mode: .livePhoto,
            rawFormat: CameraRAWFormat(pixelFormat: 1, kind: .appleProRAW))
        XCTAssertTrue(plan.capturesLivePhoto)
        XCTAssertFalse(plan.capturesRAW)
        XCTAssertFalse(plan.approximateLook)
        XCTAssertEqual(try JSONDecoder().decode(PhotoCapturePlan.self, from: JSONEncoder().encode(plan)), plan)
        XCTAssertFalse(PhotoCapturePlan(version: 1, format: .processed, inputSpace: .sceneLinearRec2020, approximateLook: false).isValid)
    }

    func testCustomAndBuiltInLooksUseOneContractForEveryCaptureFormat() {
        let custom = FilmSource.custom(id: UUID(), displayName: "Imported", iso: 200, fileName: "test.jslut")
        for source in FilmPreset.allCases.map(FilmSource.preset) + [custom] {
            XCTAssertEqual(source.inputSpace, .displaySRGB)
            for mode in [PhotoCaptureMode.quality, .livePhoto] {
                for raw: CameraRAWFormat? in [nil, .init(pixelFormat: 1, kind: .appleProRAW)] {
                    let plan = PhotoCapturePlan.resolve(mode: mode, rawFormat: raw)
                    XCTAssertEqual(plan.version, 2)
                    XCTAssertEqual(plan.inputSpace, .displaySRGB)
                    XCTAssertFalse(plan.approximateLook)
                    XCTAssertTrue(plan.isValid)
                }
            }
        }
        // Frozen old scene-linear jobs must still be recoverable.
        XCTAssertTrue(PhotoCapturePlan(version: 1, format: .appleProRAW,
            inputSpace: .sceneLinearRec2020, approximateLook: false).isValid)
        XCTAssertFalse(PhotoCapturePlan(version: 2, format: .appleProRAW,
            inputSpace: .sceneLinearRec2020, approximateLook: false).isValid)
    }
}
