import XCTest
import MetalKit
import SwiftUI
@testable import JustShoot

@MainActor
final class CameraPreviewLifecycleTests: XCTestCase {
    @MainActor
    private final class Preparation: ObservableObject {
        @Published var resourcesReady = false
    }

    private struct PreviewHost: View {
        @ObservedObject var preparation: Preparation
        let manager: CameraManager
        let lut: PreviewLUTTexture

        var body: some View {
            RealtimePreviewView(manager: manager, resourcesReady: preparation.resourcesReady,
                lutCacheKey: lut.key, preparedLUT: lut, grain: .disabled,
                optics: .disabled, chromatic: .neutral)
                .frame(width: 160, height: 200)
        }
    }

    private func preview(in view: UIView) -> CameraPreviewMetalView? {
        if let view = view as? CameraPreviewMetalView { return view }
        return view.subviews.lazy.compactMap { self.preview(in: $0) }.first
    }

    func testMountedPreviewInstallsRendererWhenResourcesFinishAfterLUT() async throws {
        // The LUT is already published. Resource readiness must update the same mounted
        // representable by itself, without a film change, navigation or another UI event.
        try await checkRendererInstallation(initiallyReady: false)
    }

    func testPreparedRendererIsInstalledOnInitialMount() async throws {
        try await checkRendererInstallation(initiallyReady: true)
    }

    private func checkRendererInstallation(initiallyReady: Bool) async throws {
        try await PreviewMetalResources.warmUpForRenderer()
        var values: [Float] = []
        for index in 0..<8 {
            values.append(Float(index % 2))
            values.append(Float((index / 2) % 2))
            values.append(Float(index / 4))
            values.append(1)
        }
        let cube = CubeLUT(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: 2)
        let lut = try await PreviewLUTTextureCache.shared.prepare(key: "preview-mount-test", lut: cube)
        let preparation = Preparation()
        preparation.resourcesReady = initiallyReady
        let manager = CameraManager()
        let window = try await makeWindow()
        let host = UIHostingController(rootView: PreviewHost(preparation: preparation, manager: manager, lut: lut))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        let view = try XCTUnwrap(preview(in: host.view))
        if !initiallyReady {
            XCTAssertNil(view.delegate)
            preparation.resourcesReady = true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while view.delegate == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(preview(in: host.view) === view, "Resource readiness must not recreate the view")
        let renderer = try XCTUnwrap(view.delegate as? RealtimePreviewView.Coordinator)
        XCTAssertTrue(renderer.manager === manager)
        XCTAssertTrue(renderer.preparedLUT?.texture === lut.texture)
        XCTAssertEqual(renderer.lutCacheKey, lut.key)
        XCTAssertFalse(view.isPaused)
        XCTAssertGreaterThan(view.drawableSize.width, 0)
    }

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

    func testPhotoReviewPausesDrawingUntilDismissedAndForegroundCannotRestartIt() async throws {
        let window = try await makeWindow()
        let view = CameraPreviewMetalView(frame: window.bounds, device: nil)
        defer { view.removeFromSuperview() }
        window.addSubview(view)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(view.isPaused)
        view.setContentVisible(false)
        XCTAssertTrue(view.isPaused)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        view.layoutSubviews()
        XCTAssertTrue(view.isPaused)
        view.setContentVisible(true)
        XCTAssertFalse(view.isPaused)
    }

    func testDismissingPhotoReviewWhileInactiveWaitsForForegroundBeforeDrawing() async throws {
        let window = try await makeWindow()
        let view = CameraPreviewMetalView(frame: window.bounds, device: nil)
        defer { view.removeFromSuperview() }
        window.addSubview(view)
        view.setContentVisible(false)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        view.setContentVisible(true)
        XCTAssertTrue(view.isPaused)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(view.isPaused)
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
