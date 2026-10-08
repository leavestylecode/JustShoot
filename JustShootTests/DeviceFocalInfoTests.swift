import XCTest
@testable import JustShoot

/// 焦距档位与硬件镜头绑定的纯函数单测（产品语义：档位由实际镜头存在性决定）。
final class DeviceFocalInfoTests: XCTestCase {

    /// 三摄（超广 + 主摄 + 长焦）→ 全档 [13, 24, 35, 50, 100, 200]。
    func testTripleCameraShowsAllStops() {
        XCTAssertEqual(
            DeviceFocalInfo.optionValues(mainMm: 24, ultraWideMm: 13, hasTele: true),
            [13, 24, 35, 50, 100, 200]
        )
    }

    /// 双摄（超广 + 主摄，无长焦）→ 不显示 100/200。
    func testDualWideOmitsTeleStops() {
        XCTAssertEqual(
            DeviceFocalInfo.optionValues(mainMm: 24, ultraWideMm: 13, hasTele: false),
            [13, 24, 35, 50]
        )
    }

    /// 双摄（主摄 + 长焦，无超广）→ 不显示 13。
    func testDualWithTeleOmitsUltraWideStop() {
        XCTAssertEqual(
            DeviceFocalInfo.optionValues(mainMm: 24, ultraWideMm: nil, hasTele: true),
            [24, 35, 50, 100, 200]
        )
    }

    /// 单摄（仅标准主摄）→ 仅 [24, 35, 50]；主摄标称非 24（如旧机型 26mm）时首档用实际标称。
    func testSingleMainCameraShowsStandardStopsOnly() {
        XCTAssertEqual(
            DeviceFocalInfo.optionValues(mainMm: 24, ultraWideMm: nil, hasTele: false),
            [24, 35, 50]
        )
        XCTAssertEqual(
            DeviceFocalInfo.optionValues(mainMm: 26, ultraWideMm: nil, hasTele: false),
            [26, 35, 50]
        )
    }

    /// 硬件分类阈值：超广 < 20mm、长焦 > 50mm（主摄 24–28mm 落在两者之间）。
    func testHardwareClassificationThresholds() {
        XCTAssertLessThan(Float(13), DeviceFocalInfo.ultraWideNativeMmCeiling)
        XCTAssertLessThanOrEqual(DeviceFocalInfo.ultraWideNativeMmCeiling, 24)
        XCTAssertLessThan(28, DeviceFocalInfo.teleNativeMmFloor)
        XCTAssertGreaterThan(Float(77), DeviceFocalInfo.teleNativeMmFloor)
    }
}
