import XCTest
import MetalKit
@testable import JustShoot

@MainActor
final class CameraPreviewLifecycleTests: XCTestCase {
    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        return UIWindow(windowScene: scene)
    }

    func testInactiveNotificationPausesImmediatelyAndForegroundResumes() throws {
        let window = try makeWindow()
        let view = CameraPreviewMetalView(frame: window.bounds, device: nil)
        defer { view.removeFromSuperview() }
        window.addSubview(view)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(view.isPaused)

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        // Must be synchronous, before any queued draw or SwiftUI scenePhase update.
        XCTAssertTrue(view.isPaused)
        view.layoutSubviews()
        XCTAssertTrue(view.isPaused)

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(view.isPaused)
    }

    func testDetachedViewCannotBeRestartedByForegroundNotification() throws {
        let window = try makeWindow()
        let view = CameraPreviewMetalView(frame: window.bounds, device: nil)
        XCTAssertTrue(view.isPaused)
        window.addSubview(view)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(view.isPaused)
        view.removeFromSuperview()
        XCTAssertTrue(view.isPaused)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(view.isPaused)
        window.addSubview(view)
        XCTAssertFalse(view.isPaused)
        view.removeFromSuperview()
    }

    func testSceneMustAlsoBeActiveBeforeResuming() throws {
        let window = try makeWindow()
        let scene = try XCTUnwrap(window.windowScene)
        let view = CameraPreviewMetalView(frame: window.bounds, device: nil)
        defer { view.removeFromSuperview() }
        window.addSubview(view)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(view.isPaused)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        XCTAssertTrue(view.isPaused)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(view.isPaused)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        XCTAssertFalse(view.isPaused)
    }

    func testDismantleStopsDrawingAndDisconnectsDelegate() throws {
        let window = try makeWindow()
        let view = CameraPreviewMetalView(frame: .zero, device: nil)
        defer { view.removeFromSuperview() }
        window.addSubview(view)
        let coordinator = RealtimePreviewView.Coordinator()
        view.delegate = coordinator
        view.isPaused = false
        RealtimePreviewView.dismantleUIView(view, coordinator: coordinator)
        XCTAssertTrue(view.isPaused)
        XCTAssertNil(view.delegate)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(view.isPaused)
    }
}
