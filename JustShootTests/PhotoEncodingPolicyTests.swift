import XCTest
@testable import JustShoot

final class PhotoEncodingPolicyTests: XCTestCase {
    func testQualityPlanImprovesPrecisionWithoutChangingUnversionedRecoveryJobs() {
        for codec in PhotoEncodingPolicy.Codec.allCases {
            let existing = PhotoEncodingPolicy.decision(for: codec)
            let current = PhotoEncodingPolicy.decision(for: codec, mode: .quality)
            XCTAssertEqual(current.mode, .quality)
            XCTAssertGreaterThan(current.quality, existing.quality)
            XCTAssertLessThan(current.quality, 1)
            XCTAssertEqual(PhotoEncodingPolicy.decision(for: codec, legacyQuality: 0.6, mode: .quality).quality, 0.6)
        }
        XCTAssertEqual(PhotoEncodingPolicy.decision(for: .heif10).quality, 0.85)
        XCTAssertEqual(PhotoEncodingPolicy.decision(for: .jpeg).quality, 0.9)
    }

    func testAutomaticDefaultsAvoidTheLosslessEndpointForEveryFallbackCodec() {
        for codec in PhotoEncodingPolicy.Codec.allCases {
            let decision = PhotoEncodingPolicy.decision(for: codec)
            XCTAssertEqual(decision.mode, .automatic)
            XCTAssertGreaterThan(decision.quality, 0.5)
            XCTAssertLessThan(decision.quality, 1)
        }
    }

    func testExistingJournalsKeepTheirFrozenQualityAcrossCodecFallbacks() {
        for quality: CGFloat in [0.6, 0.8, 0.95, 1] {
            for codec in PhotoEncodingPolicy.Codec.allCases {
                let decision = PhotoEncodingPolicy.decision(for: codec, legacyQuality: quality)
                XCTAssertEqual(decision.mode, .legacy)
                XCTAssertEqual(decision.quality, quality)
            }
        }
    }

    func testInvalidLegacyValuesCannotReachTheEncoderAsNonFiniteOptions() {
        let decision = PhotoEncodingPolicy.decision(for: .heif10, legacyQuality: .nan)
        XCTAssertEqual(decision.mode, .automatic)
        XCTAssertTrue(decision.quality.isFinite)
        XCTAssertEqual(PhotoEncodingPolicy.decision(for: .jpeg, legacyQuality: 2).quality, 1)
        XCTAssertEqual(PhotoEncodingPolicy.decision(for: .jpeg, legacyQuality: -1).quality, 0)
    }
}
