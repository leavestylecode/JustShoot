import XCTest
import UIKit
import SwiftUI
@testable import JustShoot

@MainActor
final class CameraNavigationGestureBlockerTests: XCTestCase {
    private func makeWindow(root: UIViewController) async throws -> UIWindow {
        let scene = try await TestWindowScene.foreground()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(50))
        return window
    }

    private func cameraController() -> UIViewController {
        UIHostingController(rootView: Color.black.cameraButtonOnlyNavigation())
    }

    func testCameraDisablesBothNavigationGesturesAndExplicitBackStillWorks() async throws {
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = try await makeWindow(root: navigation)
        defer { window.isHidden = true; window.rootViewController = nil }
        let edge = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let content = try contentRecognizer(in: navigation)
        let previousEdge = edge.isEnabled, previousContent = content?.isEnabled
        let camera = cameraController()

        navigation.pushViewController(camera, animated: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(edge.isEnabled)
        if let content { XCTAssertFalse(content.isEnabled) }
        XCTAssertTrue(navigation.popViewController(animated: false) === camera)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(navigation.topViewController === root)
        XCTAssertEqual(edge.isEnabled, previousEdge)
        XCTAssertEqual(content?.isEnabled, previousContent)
    }

    func testOtherPagesRegainGesturesAndReturningToCameraBlocksThemAgain() async throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let window = try await makeWindow(root: navigation)
        defer { window.isHidden = true; window.rootViewController = nil }
        let edge = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let content = try contentRecognizer(in: navigation)
        let camera = cameraController()
        navigation.pushViewController(camera, animated: false)
        try await Task.sleep(for: .milliseconds(50))
        let detail = UIViewController()
        navigation.pushViewController(detail, animated: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(edge.isEnabled)
        if let content { XCTAssertTrue(content.isEnabled) }

        XCTAssertTrue(navigation.popViewController(animated: false) === detail)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(navigation.topViewController === camera)
        XCTAssertFalse(edge.isEnabled)
        if let content { XCTAssertFalse(content.isEnabled) }
    }

    func testSwiftUINavigationUsesStandardTransitionAndDismissActionAcrossRepeatedEntries() async throws {
        let state = NavigationState()
        let host = UIHostingController(rootView: NavigationTestRoot(state: state))
        let window = try await makeWindow(root: host)
        defer { window.isHidden = true; window.rootViewController = nil }
        let navigation = try XCTUnwrap(findNavigationController(in: host))
        let root = try XCTUnwrap(navigation.topViewController)
        let edge = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let content = try contentRecognizer(in: navigation)

        for entry in 1...2 {
            state.customBackButton = entry == 2
            state.path = [entry]
            try await waitUntil { navigation.viewControllers.count == 2 && state.dismiss != nil }
            XCTAssertEqual(navigation.isNavigationBarHidden, state.customBackButton)
            if #available(iOS 18.0, *) {
                XCTAssertNil(navigation.topViewController?.preferredTransition,
                             "Camera entry must not install zoom's independent dismissal gestures")
            }
            XCTAssertFalse(edge.isEnabled)
            if let content { XCTAssertFalse(content.isEnabled) }

            // This is the same environment action used by the camera's Back button.
            let dismiss = try XCTUnwrap(state.dismiss)
            state.dismiss = nil
            dismiss()
            try await waitUntil { state.path.isEmpty && navigation.topViewController === root }
        }
    }

    private func contentRecognizer(in navigation: UINavigationController) throws -> UIGestureRecognizer? {
        if #available(iOS 26.0, *) {
            return try XCTUnwrap(navigation.interactiveContentPopGestureRecognizer)
        }
        return nil
    }

    private func findNavigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.findNavigationController(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Navigation did not settle")
    }
}

@MainActor
private final class NavigationState: ObservableObject {
    @Published var path: [Int] = []
    var customBackButton = false
    var dismiss: DismissAction?
}

private struct NavigationTestRoot: View {
    @ObservedObject var state: NavigationState

    var body: some View {
        NavigationStack(path: $state.path) {
            Color.black
                .navigationDestination(for: Int.self) { _ in
                    NavigationTestCamera(state: state)
                }
        }
        .transaction { $0.disablesAnimations = true }
    }
}

private struct NavigationTestCamera: View {
    let state: NavigationState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.black
            .cameraButtonOnlyNavigation(customBackButton: state.customBackButton)
            .overlay {
                if state.customBackButton { IPadCameraBackButton() }
            }
            .onAppear { state.dismiss = dismiss }
    }
}
