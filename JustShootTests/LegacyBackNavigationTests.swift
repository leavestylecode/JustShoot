import CoreImage
import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class LegacyBackNavigationTests: XCTestCase {
    func testSettingsPagesDrawOneBackIndicatorAtEachDepth() async throws {
        if #available(iOS 26, *) { throw XCTSkip("UIKit supplies the system appearance") }
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let route = Route()
        let host = UIHostingController(rootView: SettingsStack(route: route))
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let renderer = CIContext()
        for path in [[], [1], [1, 2], [1], []] {
            route.path = path
            let deadline = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < deadline {
                if let nav = navigation(in: host), nav.viewControllers.count == path.count + 1,
                   nav.transitionCoordinator == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let nav = try XCTUnwrap(navigation(in: host))
            XCTAssertEqual(nav.viewControllers.count, path.count + 1)
            guard !path.isEmpty else { continue }
            let source = try XCTUnwrap(nav.viewControllers.dropLast().last)
            XCTAssertNil(source.navigationItem.backBarButtonItem?.image)
            let bar = nav.navigationBar
            let image = UIGraphicsImageRenderer(bounds: bar.bounds).image { context in
                UIColor.white.setFill()
                context.fill(bar.bounds)
                bar.drawHierarchy(in: bar.bounds, afterScreenUpdates: true)
            }
            // Each visible chevron crosses the bar's horizontal centerline once.
            // Counting tap targets alone misses two arrows drawn in one native button.
            let bitmap = CIImage(cgImage: try XCTUnwrap(image.cgImage))
            let width = Int(80 * image.scale)
            let leading = bar.effectiveUserInterfaceLayoutDirection == .leftToRight ? 0 : bitmap.extent.maxX - CGFloat(width)
            let row = CGRect(x: leading, y: floor(bitmap.extent.midY), width: CGFloat(width), height: 1)
            var pixels = [UInt8](repeating: 0, count: width * 4)
            renderer.render(bitmap, toBitmap: &pixels, rowBytes: pixels.count, bounds: row,
                            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            var arrows = 0
            var insideGlyph = false
            for pixel in stride(from: 0, to: pixels.count, by: 4) {
                let isInk = min(pixels[pixel], pixels[pixel + 1], pixels[pixel + 2]) < 128
                if isInk && !insideGlyph { arrows += 1 }
                insideGlyph = isInk
            }
            if arrows != 1 { add(XCTAttachment(image: image)) }
            XCTAssertEqual(arrows, 1, "Expected one back indicator at path \(path)")
        }
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let nav = controller as? UINavigationController { return nav }
        return controller.children.lazy.compactMap { self.navigation(in: $0) }.first
    }

    private final class Route: ObservableObject {
        @Published var path: [Int] = []
    }

    private struct SettingsStack: View {
        @ObservedObject var route: Route
        var body: some View {
            NavigationStack(path: $route.path) {
                Color.clear.navigationTitle("Settings")
                    .navigationDestination(for: Int.self) { value in
                        if value == 1 { AppearanceSettingsView() }
                        else { GeneralBackgroundSettingsView() }
                    }
            }
        }
    }
}
