import XCTest
import UIKit
@testable import JustShoot

final class CameraOrientationPolicyTests: XCTestCase {
    private let interfaces: [UIInterfaceOrientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]

    func testEachWindowOrientationRetainsTheEntireSensorFrame() {
        let sensor = CGSize(width: 1920, height: 1440)
        let rotations: [UInt32] = [1, 2, 3, 0]
        for (orientation, expected) in zip(interfaces, rotations) {
            let rotation = CameraOrientationPolicy.previewRotation(for: orientation)
            XCTAssertEqual(rotation, expected)
            let output = orientation.isLandscape ? sensor : CGSize(width: sensor.height, height: sensor.width)
            XCTAssertEqual(CameraOrientationPolicy.previewAspect(for: orientation), output.width / output.height)
            let transform = CameraFraming.previewTransform(input: sensor, rotation: rotation, output: output, zoom: 1)
            XCTAssertEqual(transform.scale, 1)
            XCTAssertEqual(transform.offset.x, 0, accuracy: 0.00001)
            XCTAssertEqual(transform.offset.y, 0, accuracy: 0.00001)
        }
    }

    func testFocusUsesTheVisibleCornerForAllFourRotations() {
        let expected = [CGPoint(x: 0.3, y: 0.8), CGPoint(x: 0.8, y: 0.7),
                        CGPoint(x: 0.7, y: 0.2), CGPoint(x: 0.2, y: 0.3)]
        for (orientation, point) in zip(interfaces, expected) {
            let actual = CameraOrientationPolicy.focusPoint(at: CGPoint(x: 20, y: 60),
                viewport: CGSize(width: 100, height: 200), rotation: CameraOrientationPolicy.previewRotation(for: orientation))
            XCTAssertEqual(actual.x, point.x, accuracy: 0.00001)
            XCTAssertEqual(actual.y, point.y, accuracy: 0.00001)
        }
    }

    func testRotatingIPadWindowDoesNotRotateControlsAndGesturesTwice() {
        let devices: [UIDeviceOrientation] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
        for (interface, device) in zip(interfaces, devices) {
            let relative = CameraOrientationPolicy.controlsOrientation(device: device, interface: interface)
            XCTAssertEqual(relative, .portrait)
            let axes = PreviewGestureRouting.axes(for: CGSize(width: 0, height: -30), orientation: relative)
            XCTAssertEqual(axes.vertical, 30)
            XCTAssertEqual(axes.horizontal, 0)
        }
    }

    func testLockedPortraitWindowRetainsPhysicalControlCompensation() {
        for device: UIDeviceOrientation in [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown] {
            XCTAssertEqual(CameraOrientationPolicy.controlsOrientation(device: device, interface: .portrait), device)
        }
    }

    @MainActor
    func testUnknownWindowOrientationCannotResetAnAlreadyRotatedPreview() {
        let manager = CameraManager()
        manager.updatePreviewInterfaceOrientation(.landscapeLeft)
        manager.updatePreviewInterfaceOrientation(.unknown)
        XCTAssertEqual(manager.previewInterfaceOrientation, .landscapeLeft)
        XCTAssertEqual(manager.previewRotationAngle, 180)
        XCTAssertEqual(manager.previewAspectRatio, 4.0 / 3.0)
    }
}
