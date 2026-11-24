import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class CameraPickerLayoutTests: XCTestCase {
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
