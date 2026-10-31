import XCTest
import UIKit
@testable import JustShoot

final class CameraOrientationPolicyTests: XCTestCase {
    private let interfaces: [UIInterfaceOrientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]

    @MainActor
    func testIPadDeclaresAllRotationsWhileIPhoneKeepsPortrait() throws {
        // Bundle resolves platform/device qualifiers; installation may strip the
        // other family's keys. Validate the effective declaration on each device.
        let orientations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String])
        let expected = UIDevice.current.userInterfaceIdiom == .pad
            ? ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
               "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
            : ["UIInterfaceOrientationPortrait"]
        XCTAssertEqual(Set(orientations), Set(expected))
        XCTAssertEqual(AppDelegate().application(UIApplication.shared, supportedInterfaceOrientationsFor: nil),
            UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIRequiresFullScreen") as? Bool,
            UIDevice.current.userInterfaceIdiom == .pad)
    }

    @MainActor
    func testLockedPortraitPreviewStillCompensatesPhysicalControls() {
        let manager = CameraManager()
        for device: UIDeviceOrientation in [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown] {
            manager.currentDeviceOrientation = device
            XCTAssertEqual(manager.previewInterfaceOrientation, .portrait)
            XCTAssertEqual(manager.previewRotationAngle, 90)
            XCTAssertEqual(manager.previewAspectRatio, 3.0 / 4.0)
            XCTAssertEqual(manager.controlsOrientation, device)
        }
    }

    @MainActor
    func testIPadRotationsRemainEnabledAcrossNavigationAndModalPresentation() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad rotation coverage")
        let scene = try await TestWindowScene.foreground()
        let originalOrientation = scene.interfaceOrientation
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        let previousRoot = window.rootViewController
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = previousRoot
            if originalOrientation != .unknown {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask(for: originalOrientation)))
            }
        }
        let delegate = AppDelegate()
        for sceneWindow in scene.windows {
            sceneWindow.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(UIApplication.shared.supportedInterfaceOrientations(for: window), .all)
        XCTAssertEqual(navigation.supportedInterfaceOrientations, .all)
        XCTAssertEqual(root.supportedInterfaceOrientations, .all)
        for orientation: UIInterfaceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portraitUpsideDown] {
            navigation.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask(for: orientation))) { error in
                XCTFail("Scene rotation failed: \(error)")
            }
            for _ in 0..<60 {
                if scene.interfaceOrientation == orientation { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(scene.interfaceOrientation, orientation)
            XCTAssertEqual(delegate.application(UIApplication.shared, supportedInterfaceOrientationsFor: window), .all)
            navigation.pushViewController(UIViewController(), animated: false)
            let sheet = UIViewController()
            await withCheckedContinuation { continuation in
                navigation.present(sheet, animated: false) { continuation.resume() }
            }
            XCTAssertEqual(delegate.application(UIApplication.shared, supportedInterfaceOrientationsFor: window), .all)
            await withCheckedContinuation { continuation in
                sheet.dismiss(animated: false) { continuation.resume() }
            }
            navigation.popToRootViewController(animated: false)
            XCTAssertEqual(delegate.application(UIApplication.shared, supportedInterfaceOrientationsFor: window), .all)
            XCTAssertEqual(scene.interfaceOrientation, orientation)
        }
    }

    private func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    func testOnlyIPadOptsIntoEveryOrientation() {
        XCTAssertEqual(AppInterfaceOrientationPolicy.supportedOrientations(for: .pad), .all)
        for idiom: UIUserInterfaceIdiom in [.phone, .unspecified, .tv, .carPlay, .mac, .vision] {
            XCTAssertEqual(AppInterfaceOrientationPolicy.supportedOrientations(for: idiom), .portrait)
        }
    }

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

    func testSystemRotatedWindowDoesNotRotateControlsAndGesturesTwice() {
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
