import CoreImage
import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class LegacyToolbarBackdropTests: XCTestCase {
    func testSoftensOnlyVisibleToolbarEdges() async throws {
        if #available(iOS 26, *) { throw XCTSkip("The system draws scroll edges on iOS 26 and later") }
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let state = Bars()
        let host = UIHostingController(rootView: ToolbarPage(state: state))
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let context = CIContext()
        let deadline = ContinuousClock.now + .seconds(3)
        while navigation(in: host)?.toolbar?.window == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let nav = try XCTUnwrap(navigation(in: host))
        let toolbar = try XCTUnwrap(nav.toolbar)
        let top = nav.navigationBar.convert(nav.navigationBar.bounds, to: window)
        let bottom = toolbar.convert(toolbar.bounds, to: window)
        XCTAssertGreaterThan(bottom.minY, top.maxY)
        for edges: VerticalEdge.Set in [[.top, .bottom], .top, []] {
            state.edges = edges
            try await Task.sleep(for: .milliseconds(150))
            let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let image = CIImage(cgImage: try XCTUnwrap(snapshot.cgImage))
            // High-frequency stripes stay sharp in the page and behind a hidden
            // toolbar. A visible backdrop reduces their contrast across the bar.
            func contrast(at y: CGFloat) -> Int {
                let width = Int(32 * snapshot.scale)
                let row = CGRect(x: floor(image.extent.width / 4), y: floor(image.extent.height - y * snapshot.scale),
                                 width: CGFloat(width), height: 1)
                var pixels = [UInt8](repeating: 0, count: width * 4)
                context.render(image, toBitmap: &pixels, rowBytes: pixels.count, bounds: row,
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                let red = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) }
                return (red.max() ?? 0) - (red.min() ?? 0)
            }
            XCTAssertGreaterThan(contrast(at: window.bounds.midY), 200)
            for (edge, y) in [(VerticalEdge.Set.top, top.midY), (.bottom, bottom.midY)] {
                if edges.contains(edge) {
                    let underBar = contrast(at: y)
                    XCTAssertLessThan(underBar, 100)
                    let boundary = edge == .top ? top.maxY : bottom.minY
                    let inward: CGFloat = edge == .top ? 1 : -1
                    let halfway = contrast(at: boundary + 8 * inward)
                    let clear = contrast(at: boundary + 20 * inward)
                    XCTAssertGreaterThan(halfway, underBar + 20)
                    XCTAssertGreaterThan(clear, halfway + 20)
                } else {
                    XCTAssertGreaterThan(contrast(at: y), 200)
                }
            }
        }
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let nav = controller as? UINavigationController { return nav }
        return controller.children.lazy.compactMap { self.navigation(in: $0) }.first
    }

    private final class Bars: ObservableObject {
        @Published var edges: VerticalEdge.Set = [.top, .bottom]
    }

    private struct ToolbarPage: View {
        @ObservedObject var state: Bars

        var body: some View {
            NavigationStack {
                Color.clear
                    .background {
                        Canvas { context, size in
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                            for x in stride(from: CGFloat.zero, to: size.width, by: 8) {
                                context.fill(Path(CGRect(x: x, y: 0, width: 4, height: size.height)), with: .color(.black))
                            }
                        }
                        .ignoresSafeArea()
                    }
                    .navigationTitle("Test")
                    .navigationBarTitleDisplayMode(.inline)
                    .legacySoftToolbarEdges(state.edges)
                    .toolbar(state.edges.contains(.top) ? .visible : .hidden, for: .navigationBar)
                    .toolbar(state.edges.contains(.bottom) ? .visible : .hidden, for: .bottomBar)
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) { Button("Done") {} }
                    }
            }
        }
    }
}
