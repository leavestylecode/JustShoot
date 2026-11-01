import Foundation

/// Product rendering calibration, independent of the spectral table's density
/// transport bounds. Absent in historical recipes; never a physical film fit.
struct FilmMaterialCalibration: Codable, Sendable, Equatable {
    static let portra = Self(shadowLift: 0.65, toneCeiling: 0.60, grainScale: 0.65)

    let shadowLift: Float
    let toneCeiling: Float
    let grainScale: Float

    var isValid: Bool {
        shadowLift.isFinite && (0...1).contains(shadowLift)
            && toneCeiling.isFinite && (0.3...0.7).contains(toneCeiling)
            && grainScale.isFinite && (0...1).contains(grainScale)
    }
}
