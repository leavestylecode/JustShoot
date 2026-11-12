import Foundation

/// Frozen display-color parameters carried by historical capture journals.
struct FilmColorBalanceParameters: Codable, Sendable, Equatable {
    enum SkinResponse: String, Codable, Sendable {
        case portraitV2 = "portrait_v2"
    }

    static let portraV1 = Self(neutralRetention: 0.72, skinHueRetention: 0.30, skinChromaRetention: 0.35)
    static let portra = Self(neutralRetention: 0.72, skinHueRetention: 0.60,
        skinChromaRetention: 0.65, skinResponse: .portraitV2)

    let neutralRetention: Float
    let skinHueRetention: Float
    let skinChromaRetention: Float
    // Absent in frozen v1 payloads. Their narrower hue gate must remain unchanged.
    var skinResponse: SkinResponse? = nil

    var shaderResponse: Float { skinResponse == .portraitV2 ? 1 : 0 }

    var isValid: Bool {
        [neutralRetention, skinHueRetention, skinChromaRetention].allSatisfy {
            $0.isFinite && (0...0.8).contains($0)
        }
    }
}
