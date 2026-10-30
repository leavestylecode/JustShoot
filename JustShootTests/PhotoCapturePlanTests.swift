import XCTest
@testable import JustShoot

final class PhotoCapturePlanTests: XCTestCase {
    func testOrdinaryCaptureUsesProcessedSDRForEveryLook() {
        let custom = FilmSource.custom(id: UUID(), displayName: "Imported", iso: 200, fileName: "test.jslut")
        for source in FilmPreset.allCases.map(FilmSource.preset) + [custom] {
            let plan = PhotoCapturePlan.resolve(mode: .quality)
            XCTAssertTrue(plan.isValid)
            XCTAssertEqual(plan.format, .processed)
            XCTAssertEqual(plan.inputSpace, source.inputSpace)
            XCTAssertFalse(plan.capturesRAW)
            XCTAssertTrue(plan.accepts(rawRecipe: nil))
            XCTAssertEqual(source.captureRenderProfile.effectiveChromatic.responseGain(sceneCCT: 3_200), .one)
        }
    }

    func testLiveRetainsProcessedDisplayContractAndFrozenPlan() throws {
        let plan = PhotoCapturePlan.resolve(mode: .livePhoto)
        XCTAssertTrue(plan.capturesLivePhoto)
        XCTAssertFalse(plan.capturesRAW)
        XCTAssertEqual(plan.inputSpace, .displaySRGB)
        XCTAssertEqual(try JSONDecoder().decode(PhotoCapturePlan.self, from: JSONEncoder().encode(plan)), plan)
    }

    func testFrozenRAWJobsRemainValidWithoutChangingNewCapturePolicy() throws {
        let cube = try FilmProcessor().loadCubeLUT(resourceName: "KodakPortra400")
        let raw = RawCaptureRecipe(unifiedLUT: cube)
        let previous = PhotoCapturePlan(version: 2, format: .appleProRAW, inputSpace: .displaySRGB, approximateLook: false)
        XCTAssertTrue(previous.accepts(rawRecipe: raw))
        XCTAssertFalse(PhotoCapturePlan.resolve(mode: .quality).accepts(rawRecipe: raw))
        XCTAssertTrue(PhotoCapturePlan(version: 1, format: .appleProRAW,
            inputSpace: .sceneLinearRec2020, approximateLook: false).isValid)
        XCTAssertFalse(PhotoCapturePlan(version: 2, format: .appleProRAW,
            inputSpace: .sceneLinearRec2020, approximateLook: false).isValid)
    }
}
