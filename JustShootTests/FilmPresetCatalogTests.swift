import XCTest
@testable import JustShoot

final class FilmPresetCatalogTests: XCTestCase {
    private let retired = [
        "fujiRawRealaAce": "FujiRawREALAACE",
        "fujiRawProNegStd": "FujiRawPRONegStd",
        "fujiRawETERNA": "FujiRawETERNA",
        "fujiRawEternaBB": "FujiRawETERNABB",
        "kodakVision5219": "KodakVision5219",
        "kodakVision5203": "KodakVision5203",
        "kodak5207": "Kodak5207",
        "harmanPhoenix200": "HarmanPhoenix200"
    ]

    func testCatalogContainsOnlyTheNineRemainingLooks() {
        XCTAssertEqual(Set(FilmPreset.allCases.map(\.rawValue)), [
            "fujiRawVelvia", "fujiRawASTIA", "fujiRawClassicChrome", "fujiRawClassicNeg",
            "fujiRawACROS", "fujiC200", "fujiPro400H", "fujiProvia100F", "kodakPortra400"
        ])
        XCTAssertEqual(Set(FilmPreset.allCases.compactMap(\.rawSimulation)), Set(FujifilmSimulation.allCases))
    }

    func testRetiredLooksHaveNoBundledTablesOrCapturePreset() {
        for (identifier, resource) in retired {
            XCTAssertNil(FilmPreset(rawValue: identifier))
            for suffix in ["cube", "jslut", "jsraw"] {
                XCTAssertNil(Bundle.main.url(forResource: resource, withExtension: suffix), "\(resource).\(suffix)")
            }
        }
    }
}
