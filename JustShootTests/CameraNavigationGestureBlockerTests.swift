import XCTest
import UIKit
import SwiftUI
@testable import JustShoot

@MainActor
final class CameraNavigationGestureBlockerTests: XCTestCase {
    private func makeWindow(navigation: UINavigationController) async throws -> UIWindow {
        let scene = try await TestWindowScene.foreground()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(50))
        return window
    }

    private func cameraController() -> UIViewController {
        UIHostingController(rootView: Color.black.background(CameraNavigationGestureBlocker()))
    }

    func testCameraDisablesBothNavigationGesturesAndExplicitBackStillWorks() async throws {
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = try await makeWindow(navigation: navigation)
        defer { window.isHidden = true; window.rootViewController = nil }
        let edge = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let content = try XCTUnwrap(navigation.interactiveContentPopGestureRecognizer)
        let previousEdge = edge.isEnabled, previousContent = content.isEnabled
        let camera = cameraController()

        navigation.pushViewController(camera, animated: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(edge.isEnabled)
        XCTAssertFalse(content.isEnabled)
        XCTAssertTrue(navigation.popViewController(animated: false) === camera)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(navigation.topViewController === root)
        XCTAssertEqual(edge.isEnabled, previousEdge)
        XCTAssertEqual(content.isEnabled, previousContent)
    }

    func testOtherPagesRegainGesturesAndReturningToCameraBlocksThemAgain() async throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let window = try await makeWindow(navigation: navigation)
        defer { window.isHidden = true; window.rootViewController = nil }
        let edge = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let content = try XCTUnwrap(navigation.interactiveContentPopGestureRecognizer)
        let camera = cameraController()
        navigation.pushViewController(camera, animated: false)
        try await Task.sleep(for: .milliseconds(50))
        let detail = UIViewController()
        navigation.pushViewController(detail, animated: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(edge.isEnabled)
        XCTAssertTrue(content.isEnabled)

        XCTAssertTrue(navigation.popViewController(animated: false) === detail)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(navigation.topViewController === camera)
        XCTAssertFalse(edge.isEnabled)
        XCTAssertFalse(content.isEnabled)
    }
}
