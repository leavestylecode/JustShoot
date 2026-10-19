import XCTest
@testable import JustShoot

/// 胶片原生色温响应（未校白）的数学约定：T 卷在日光下偏蓝、日光卷在钨丝灯下偏橙、
/// 完全校白（strength=0）保持现状、极端读数有钳制、旧 journal 缺字段解码为中性。
final class FilmChromaticResponseTests: XCTestCase {
    func testOldChromaticRecipeKeepsLegacyHighlightResponse() throws {
        let data = Data(#"{"nativeCCT":5500,"strength":0.42}"#.utf8)
        let legacy = try JSONDecoder().decode(FilmChromaticResponseParameters.self, from: data)
        XCTAssertFalse(legacy.protectsHighlights)
        XCTAssertEqual(legacy.responseGain(sceneCCT: 3_200),
                       FilmPreset.kodakPortra400.chromaticResponse.responseGain(sceneCCT: 3_200))
    }

    func testNewChromaticRecipeFreezesHighlightProtection() throws {
        let current = FilmPreset.kodakPortra400.chromaticResponse
        XCTAssertTrue(current.protectsHighlights)
        let restored = try JSONDecoder().decode(FilmChromaticResponseParameters.self,
                                                from: JSONEncoder().encode(current))
        XCTAssertEqual(restored, current)
        XCTAssertTrue(restored.protectsHighlights)
        XCTAssertFalse(FilmChromaticResponseParameters.neutral.protectsHighlights)
    }

    func testNeutralStrengthReturnsUnitGain() {
        let neutral = FilmChromaticResponseParameters.neutral
        XCTAssertTrue(neutral.isNeutral)
        XCTAssertEqual(neutral.responseGain(sceneCCT: 5_500), SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(neutral.responseGain(sceneCCT: nil), SIMD3<Float>(1, 1, 1))
    }

    func testSceneMatchingNativeCCTReturnsUnitGain() {
        // 场景色温等于胶片原生平衡：乳剂眼中的白就是白，不应偏色。
        let daylightStock = FilmChromaticResponseParameters(nativeCCT: 5_500, strength: 1.0)
        let gain = daylightStock.responseGain(sceneCCT: 5_500)
        XCTAssertEqual(gain.x, 1, accuracy: 0.002)
        XCTAssertEqual(gain.y, 1, accuracy: 0.002)
        XCTAssertEqual(gain.z, 1, accuracy: 0.002)
    }

    func testTungstenStockShiftsBlueInDaylight() {
        // 5219（3200K 钨点平衡）在 5500K 日光下：蓝通道增益 > 1、红通道 < 1，整体偏蓝。
        let tungsten = FilmChromaticResponseParameters(nativeCCT: 3_200, strength: 1.0)
        let gain = tungsten.responseGain(sceneCCT: 5_500)
        XCTAssertGreaterThan(gain.z, 1.05, "日光下 T 卷蓝通道应被推高")
        XCTAssertLessThan(gain.x, 1.0, "日光下 T 卷红通道应被压低")
        XCTAssertGreaterThan(gain.z, gain.y, "偏色方向应为蓝")
    }

    func testDaylightStockShiftsWarmUnderTungstenLight() {
        // 日光卷在 3200K 钨丝灯下：红通道增益 > 1，整体偏橙暖。
        let daylight = FilmChromaticResponseParameters(nativeCCT: 5_500, strength: 1.0)
        let gain = daylight.responseGain(sceneCCT: 3_200)
        XCTAssertGreaterThan(gain.x, 1.05, "钨丝灯下日光卷红通道应被推高")
        XCTAssertLessThan(gain.z, 1.0, "钨丝灯下日光卷蓝通道应被压低")
    }

    func testPartialStrengthSoftensButPreservesDirection() {
        let full = FilmChromaticResponseParameters(nativeCCT: 3_200, strength: 1.0)
        let soft = FilmChromaticResponseParameters(nativeCCT: 3_200, strength: 0.3)
        let fullGain = full.responseGain(sceneCCT: 5_500)
        let softGain = soft.responseGain(sceneCCT: 5_500)
        // strength 是每通道幂：方向一致，幅度向 1 收敛。
        XCTAssertGreaterThan(softGain.z, 1.0, "部分强度仍应保持偏色方向")
        XCTAssertLessThan(softGain.z, fullGain.z, "部分强度应弱于完整响应")
        XCTAssertGreaterThan(softGain.z, 1.0)
        XCTAssertEqual(softGain.z, pow(fullGain.z, 0.3), accuracy: 0.001)
    }

    func testExtremeReadingsAreClamped() {
        let stock = FilmChromaticResponseParameters(nativeCCT: 5_500, strength: 1.0)
        // 40_000K 极端读数被钳制到 12_000K；增益也必须有上界，读数跳变不得失控。
        let extreme = stock.responseGain(sceneCCT: 40_000)
        XCTAssertLessThanOrEqual(extreme.z, 2.2)
        XCTAssertGreaterThanOrEqual(extreme.z, 0.5)
        let absurd = stock.responseGain(sceneCCT: .nan)
        XCTAssertEqual(absurd, SIMD3<Float>(1, 1, 1), "无效读数应退化为不响应")
    }

    func testUnitWhiteVectorIsNormalizedAndWarmAtLowCCT() {
        let warm = FilmChromaticResponseParameters.linearRGBUnitWhite(clamping: 3_000)
        let cool = FilmChromaticResponseParameters.linearRGBUnitWhite(clamping: 7_000)
        // 3000K 暖光：红最高；7000K 冷光：蓝相对更高。
        XCTAssertGreaterThan(warm.x, warm.z)
        XCTAssertGreaterThan(cool.z, warm.z)
        // 6500K 黑体 ≈ sRGB 的 D65 白点：三通道应接近中性（保留辐照度比例、未归一化，
        // 但偏离中性应在 ~15% 内）。
        let neutralish = FilmChromaticResponseParameters.linearRGBUnitWhite(clamping: 6_500)
        for channel in [neutralish.x, neutralish.y, neutralish.z] {
            XCTAssertGreaterThan(channel, 0.85)
            XCTAssertLessThan(channel, 1.15)
        }
    }

    func testLegacyJournalManifestDecodesAsNeutral() throws {
        // 旧 manifest：profile 无 chromatic 键、recipe 无 chromaticSceneCCT 键 → 中性，不响应。
        let legacyJSON = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "captureDate": 0,
          "filterName": "KodakPortra400",
          "displayLabel": null,
          "focalLength": 24,
          "outputQuality": 0.9,
          "profile": { "grain": { "amount": 0, "size": 1, "chroma": 0 },
                       "optics": { "halationAmount": 0, "halationRadius": 0, "halationHue": 0,
                                   "bloomAmount": 0, "bloomRadius": 0,
                                   "headroomAmount": 0, "headroomShoulder": 0 } },
          "grainSeed": 7,
          "location": null,
          "lutDimension": 64,
          "photoDisplayTime": null
        }
        """
        let job = try JSONDecoder().decode(CaptureRecipe.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(job.outputQuality, 0.9, "旧任务应保留拍摄时冻结的编码质量")
        XCTAssertNil(job.chromaticSceneCCT, "旧 manifest 无场景色温快照字段，应解码为 nil")
        XCTAssertEqual(job.profile.effectiveChromatic, .neutral)
        XCTAssertEqual(job.profile.effectiveChromatic.responseGain(sceneCCT: 3_200), SIMD3<Float>(1, 1, 1))
    }

    func testPerPresetResponsesFollowDesignIntent() {
        // T 卷（5219）是唯一钨点平衡；反转片响应最浅；电影卷深于同 ISO 消费卷。
        XCTAssertEqual(FilmPreset.kodakVision5219.chromaticResponse.nativeCCT, 3_200)
        XCTAssertLessThan(FilmPreset.fujiProvia100F.chromaticResponse.strength,
                          FilmPreset.fujiC200.chromaticResponse.strength)
        XCTAssertGreaterThan(FilmPreset.kodakVision5219.chromaticResponse.strength,
                             FilmPreset.kodakPortra400.chromaticResponse.strength)
        // 自定义 LUT：用户导入什么就出什么，色温响应关闭。
        XCTAssertEqual(FilmSource.custom(id: UUID(), displayName: "x", iso: 200, fileName: "a.cube")
            .renderProfile.effectiveChromatic, .neutral)
    }
}

