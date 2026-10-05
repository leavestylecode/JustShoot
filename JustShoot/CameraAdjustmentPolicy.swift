import CoreGraphics
import UIKit

/// Keep slider-driven LUT work within the camera's 30 fps cadence. Waiting requests may be
/// cancelled/replaced without moving the deadline, so continuous dragging still updates live.
struct CameraLUTPreparationCadence: Sendable {
    static let minimumInterval: TimeInterval = 1.0 / 30.0
    private var lastStartedAt: TimeInterval?

    func delay(at now: TimeInterval) -> TimeInterval {
        guard let lastStartedAt else { return 0 }
        return max(0, lastStartedAt + Self.minimumInterval - now)
    }

    mutating func started(at now: TimeInterval) { lastStartedAt = now }
}

/// Classify once per gesture so a diagonal tail cannot change a film swipe into an EV drag.
struct PreviewGestureRouting: Sendable {
    enum Intent: Sendable { case undecided, exposure, film }
    private(set) var intent: Intent = .undecided

    static func axes(for translation: CGSize, orientation: UIDeviceOrientation) -> (vertical: CGFloat, horizontal: CGFloat) {
        switch orientation {
        case .portraitUpsideDown: return (translation.height, -translation.width)
        case .landscapeLeft: return (translation.width, translation.height)
        case .landscapeRight: return (-translation.width, -translation.height)
        default: return (-translation.height, translation.width)
        }
    }

    mutating func update(horizontal: CGFloat, vertical: CGFloat, allowsFilmSwipe: Bool) -> Intent {
        guard intent == .undecided else { return intent }
        if abs(vertical) > 14, abs(vertical) > abs(horizontal) * 1.5 {
            intent = .exposure
        } else if allowsFilmSwipe, abs(horizontal) > 14, abs(horizontal) > abs(vertical) * 1.5 {
            intent = .film
        }
        return intent
    }
}

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
struct CameraWhiteBalanceReading: Equatable, Sendable {
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
struct ResolvedCameraColorAdjustment: Equatable, Sendable {
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

/// Coalesces the frequent KVO callbacks without adding per-frame main-actor tasks.
struct WhiteBalanceReadingGate: Sendable {
    static let samplingInterval: TimeInterval = 0.5
    private var pending = false
    private var lastStarted: TimeInterval?

    mutating func begin(at now: TimeInterval) -> Bool {
        guard !pending, lastStarted.map({ now - $0 >= Self.samplingInterval }) ?? true else { return false }
        pending = true
        lastStarted = now
        return true
    }

    mutating func finish() { pending = false }
}

/// Drag from the indicator's visible position, including midway through an automatic animation.
/// Keep this continuous; only the value sent to the color pipeline is quantized.
struct CameraColorSliderDrag: Sendable {
    let startX: CGFloat
    let startFraction: CGFloat

    func fraction(at x: CGFloat, travel: CGFloat) -> CGFloat {
        guard x.isFinite, travel.isFinite, travel > 0 else { return startFraction }
        return min(1, max(0, startFraction + (x - startX) / travel))
    }

    func endingFraction(at x: CGFloat, trackStart: CGFloat, travel: CGFloat, hasEmittedValue: Bool) -> CGFloat {
        guard travel.isFinite, travel > 0 else { return startFraction }
        // A drag that returns near its starting point is still a drag, not a tap-to-jump.
        if !hasEmittedValue, abs(x - startX) < 2, x >= trackStart {
            return min(1, max(0, (x - trackStart) / travel))
        }
        return fraction(at: x, travel: travel)
    }
}

enum CameraWhiteBalancePolicy {
    static let temperatureRange: ClosedRange<Float> = 3_000...8_000
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
