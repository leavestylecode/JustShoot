import UIKit

/// Preview geometry follows its own window, including iPad multitasking and rotation lock.
/// Capture orientation remains tied to the physical camera at shutter admission.
enum CameraOrientationPolicy {
    static func previewRotation(for orientation: UIInterfaceOrientation) -> UInt32 {
        switch orientation {
        case .landscapeLeft: return 2
        case .portraitUpsideDown: return 3
        case .landscapeRight: return 0
        default: return 1
        }
    }

    static func previewAspect(for orientation: UIInterfaceOrientation) -> CGFloat {
        orientation.isLandscape ? 1 / CameraFraming.portraitAspect : CameraFraming.portraitAspect
    }

    static func controlsOrientation(device: UIDeviceOrientation, interface: UIInterfaceOrientation) -> UIDeviceOrientation {
        let windowDevice: UIDeviceOrientation
        switch interface {
        case .landscapeLeft: windowDevice = .landscapeRight
        case .landscapeRight: windowDevice = .landscapeLeft
        case .portraitUpsideDown: windowDevice = .portraitUpsideDown
        default: windowDevice = .portrait
        }
        let turns = (controlTurns(device) - controlTurns(windowDevice) + 4) % 4
        switch turns {
        case 1: return .landscapeLeft
        case 2: return .portraitUpsideDown
        case 3: return .landscapeRight
        default: return .portrait
        }
    }

    private static func controlTurns(_ orientation: UIDeviceOrientation) -> Int {
        switch orientation {
        case .landscapeLeft: return 1
        case .portraitUpsideDown: return 2
        case .landscapeRight: return 3
        default: return 0
        }
    }

    /// Inverse of the renderer's clockwise rotation, in normalized sensor coordinates.
    static func focusPoint(at point: CGPoint, viewport: CGSize, rotation: UInt32) -> CGPoint {
        let x = min(1, max(0, point.x / max(1, viewport.width)))
        let y = min(1, max(0, point.y / max(1, viewport.height)))
        switch rotation {
        case 1: return CGPoint(x: y, y: 1 - x)
        case 2: return CGPoint(x: 1 - x, y: 1 - y)
        case 3: return CGPoint(x: 1 - y, y: x)
        default: return CGPoint(x: x, y: y)
        }
    }
}
