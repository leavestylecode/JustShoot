import XCTest
import MetalKit
@testable import JustShoot

@MainActor
final class CameraPreviewLifecycleTests: XCTestCase {
    private func makeWindow() async throws -> UIWindow {
        let scene = try await TestWindowScene.foreground()
        return UIWindow(windowScene: scene)
    }

    func testInactiveNotificationPausesImmediatelyAndForegroundResumes() async throws {
        let window = try await makeWindow()
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

    func testDetachedViewCannotBeRestartedByForegroundNotification() async throws {
        let window = try await makeWindow()
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

    func testSceneMustAlsoBeActiveBeforeResuming() async throws {
        let window = try await makeWindow()
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

    func testDismantleStopsDrawingAndDisconnectsDelegate() async throws {
        let window = try await makeWindow()
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

    func testAnimatedRasterScaleCannotBypassControlledDrawableSizing() async throws {
        let window = try await makeWindow()
        let view = CameraPreviewMetalView(frame: CGRect(x: 0, y: 0, width: 408, height: 544), device: nil)
        defer { view.removeFromSuperview() }
        view.configurePreviewScale(2)
        window.addSubview(view)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        view.layoutSubviews()
        let initial = CGSize(width: 816, height: 1088)
        XCTAssertFalse(view.autoResizeDrawable)
        XCTAssertEqual(view.drawableSize, initial)
        for scale in [1.997, 1.99, 1.98, 1.973] {
            view.contentScaleFactor = scale
            view.layoutSubviews()
            XCTAssertEqual(view.contentScaleFactor, 2)
            XCTAssertEqual(view.drawableSize, initial)
        }
    }

    func testPendingResizeCannotFireWhileInactiveAndResumeAppliesItSynchronously() async throws {
        let window = try await makeWindow()
        let view = CameraPreviewMetalView(frame: CGRect(x: 0, y: 0, width: 408, height: 544), device: nil)
        defer { view.removeFromSuperview() }
        view.configurePreviewScale(2)
        window.addSubview(view)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        view.layoutSubviews()
        let initial = view.drawableSize
        view.bounds.size = CGSize(width: 372, height: 496)
        view.layoutSubviews()
        XCTAssertEqual(view.drawableSize, initial)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(view.drawableSize, initial)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(view.isPaused)
        XCTAssertEqual(view.drawableSize, CGSize(width: 744, height: 992))
    }

    func testDetachedLayoutKeepsTheDrawableAndReattachmentAppliesTheLatestSizeWithoutDelay() async throws {
        let window = try await makeWindow()
        let view = CameraPreviewMetalView(frame: CGRect(x: 0, y: 0, width: 408, height: 544), device: nil)
        defer { view.removeFromSuperview() }
        view.configurePreviewScale(2)
        window.addSubview(view)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        view.layoutSubviews()
        let initial = view.drawableSize
        view.removeFromSuperview()
        view.bounds.size = CGSize(width: 372, height: 496)
        view.layoutSubviews()
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(view.drawableSize, initial)
        window.addSubview(view)
        XCTAssertFalse(view.isPaused)
        XCTAssertEqual(view.drawableSize, CGSize(width: 744, height: 992))
    }

    func testAnAttachedResizeBurstKeepsOneDrawableUntilTheFinalGeometrySettles() async throws {
        let window = try await makeWindow()
        let view = CameraPreviewMetalView(frame: CGRect(x: 0, y: 0, width: 408, height: 544), device: nil)
        defer { view.removeFromSuperview() }
        view.configurePreviewScale(2)
        window.addSubview(view)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        view.layoutSubviews()
        let initial = view.drawableSize
        for sample in 1...34 {
            let height = CGFloat(544 - sample)
            view.bounds.size = CGSize(width: height * 0.75, height: height)
            view.layoutSubviews()
            XCTAssertEqual(view.drawableSize, initial)
        }
        let final = CameraPerformancePolicy.drawableSize(bounds: view.bounds.size, scale: 2)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(view.drawableSize, final)
    }
}
