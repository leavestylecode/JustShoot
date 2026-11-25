import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class CameraPickerLayoutTests: XCTestCase {
    func testSortingPreviewReturnsToFirstCurveAndCameraFindsSelection() async throws {
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        func strip(_ presentation: FilmCurvePickerStrip.Presentation) -> some View {
            FilmCurvePickerStrip(curves: CurvePreset.allCases.map(FilmCurve.builtIn),
                current: .builtIn(.crossProcess), contentRotation: .zero, orientation: .portrait,
                presentation: presentation)
                .frame(width: 180)
        }
        let host = UIHostingController(rootView: strip(.preview))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        let end = scroll.contentSize.width - scroll.bounds.width
        XCTAssertGreaterThan(end, 0)
        XCTAssertEqual(scroll.contentOffset.x, 0, accuracy: 1)
        scroll.setContentOffset(CGPoint(x: end, y: 0), animated: false)

        func waitForOffset(_ offset: CGFloat) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while abs(scroll.contentOffset.x - offset) > 1 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(scroll.contentOffset.x, offset, accuracy: 1)
        }
        host.rootView = strip(.sortingPreview)
        try await waitForOffset(0)
        host.rootView = strip(.camera)
        try await waitForOffset(end)
    }

    func testStandardPickerRowsHaveMatchingHeights() async throws {
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        let presets: [FilmPreset] = [.fujiRawVelvia, .fujiRawClassicChrome, .fujiRawACROS]
        let covers = try await FilmSourcePickerStrip.preloadCovers(presets: presets, displayScale: window.screen.scale)
        let films = FilmSourcePickerStrip(current: .preset(presets[0]), sources: presets.map(FilmSource.preset),
            contentRotation: .zero, orientation: .portrait, preparedCovers: covers) { _ in }
        let curves = FilmCurvePickerStrip(curves: CurvePreset.allCases.map(FilmCurve.builtIn),
            current: .builtIn(.filmSoft), contentRotation: .zero, orientation: .portrait,
            onManage: {}, onSelect: { _ in })

        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let proposal = CGSize(width: 390, height: 400)
            let filmHost = UIHostingController(rootView: films.environment(\.horizontalSizeClass, sizeClass))
            let curveHost = UIHostingController(rootView: curves.environment(\.horizontalSizeClass, sizeClass))
            let filmHeight = filmHost.sizeThatFits(in: proposal).height
            let curveHeight = curveHost.sizeThatFits(in: proposal).height
            XCTAssertEqual(filmHeight, curveHeight, accuracy: 0.5)
            XCTAssertEqual(filmHeight, sizeClass == .regular ? 92 : 74, accuracy: 0.5)
        }

        let host = UIHostingController(rootView: VStack(spacing: 12) {
            curves
            films
        }
        .padding(16)
        .background(.black)
        .environment(\.horizontalSizeClass, .compact)
        .preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        let height = host.sizeThatFits(in: host.view.bounds.size).height
        let size = CGSize(width: host.view.bounds.width, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: CGRect(x: 0, y: (height - host.view.bounds.height) / 2,
                width: size.width, height: host.view.bounds.height), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iphone-camera-look-picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-camera-look-picker.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("iphone_camera_look_picker path=\(url.path)")
    }
}
