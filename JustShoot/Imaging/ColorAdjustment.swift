import Foundation

enum CameraWhiteBalanceSelection: Equatable, Sendable {
    case automatic
    case temperature(Float)

    var isAutomatic: Bool { self == .automatic }
    var kelvin: Float {
        if case .temperature(let value) = self { return value }
        return 6_500
    }
}

enum CameraTintSelection: Equatable, Sendable {
    case automatic
    case value(Float)

    var isAutomatic: Bool { self == .automatic }
}

/// Rounded camera telemetry, not a made-up fallback. Auto can legitimately read outside manual limits.
struct CameraWhiteBalanceReading: Codable, Equatable, Sendable {
    let temperature: Float
    let tint: Float

    init?(temperature: Float, tint: Float) {
        guard temperature.isFinite, (1_000...40_000).contains(temperature),
              tint.isFinite, (-150...150).contains(tint) else { return nil }
        self.temperature = (temperature / 100).rounded() * 100
        self.tint = tint.rounded()
    }

    static let neutral = CameraWhiteBalanceReading(temperature: 6_500, tint: 0)!
}

/// Values used by the software correction: desired white point -> camera's current AWB white point.
struct ResolvedCameraColorAdjustment: Codable, Equatable, Sendable {
    let temperature: Float
    let tint: Float
    let reference: CameraWhiteBalanceReading

    var isNeutral: Bool { temperature == reference.temperature && tint == reference.tint }

    static func resolve(temperature: CameraWhiteBalanceSelection, tint: CameraTintSelection,
                        reading: CameraWhiteBalanceReading?) -> Self? {
        if temperature.isAutomatic && tint.isAutomatic {
            let reference = reading ?? .neutral
            return Self(temperature: reference.temperature, tint: reference.tint, reference: reference)
        }
        guard let reference = reading else { return nil }
        let resolvedTemperature: Float
        switch temperature {
        case .automatic: resolvedTemperature = reference.temperature
        case .temperature(let value):
            guard let value = CameraWhiteBalancePolicy.temperature(value) else { return nil }
            resolvedTemperature = value
        }
        let resolvedTint: Float
        switch tint {
        case .automatic: resolvedTint = reference.tint
        case .value(let value):
            guard let value = CameraWhiteBalancePolicy.tint(value) else { return nil }
            resolvedTint = value
        }
        return Self(temperature: resolvedTemperature, tint: resolvedTint, reference: reference)
    }
}

enum CameraWhiteBalancePolicy {
    static let temperatureRange: ClosedRange<Float> = 2_000...10_000
    static let tintRange: ClosedRange<Float> = -30...30

    static func canReadGains(red: Float, green: Float, blue: Float, maximum: Float) -> Bool {
        maximum.isFinite && maximum >= 1 && [red, green, blue].allSatisfy { $0.isFinite && $0 >= 1 && $0 <= maximum }
    }

    static func temperature(_ value: Float) -> Float? {
        guard value.isFinite else { return nil }
        return min(temperatureRange.upperBound, max(temperatureRange.lowerBound, (value / 100).rounded() * 100))
    }

    static func tint(_ value: Float) -> Float? {
        guard value.isFinite else { return nil }
        return min(tintRange.upperBound, max(tintRange.lowerBound, value.rounded()))
    }
}
