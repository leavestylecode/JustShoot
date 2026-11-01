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

/// Hiding the controls also removes both manual corrections from preview and capture.
struct CameraColorControlsState: Equatable, Sendable {
    private(set) var isVisible = false
    var temperature: CameraWhiteBalanceSelection = .automatic
    var tint: CameraTintSelection = .automatic

    mutating func setVisible(_ visible: Bool) {
        isVisible = visible
        if !visible { resetAutomatic() }
    }

    mutating func resetAutomatic() {
        temperature = .automatic
        tint = .automatic
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
