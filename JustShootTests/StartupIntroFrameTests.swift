import UIKit
import XCTest
@testable import JustShoot

final class StartupIntroFrameTests: XCTestCase {
    func testReadyHomeWaitsForTraceAndHold() {
        XCTAssertEqual(StartupIntroTiming.expansionStart(tracingFrom: 10, homeReadyAt: 10.1),
                       10 + StartupIntroTiming.traceDuration + StartupIntroTiming.holdDuration)
    }

    func testLateHomeOpensAsSoonAsItIsReady() {
        XCTAssertEqual(StartupIntroTiming.expansionStart(tracingFrom: 10, homeReadyAt: 12), 12)
    }

    @MainActor
    func testFirstFrameMatchesLaunchScreenAndFinalFrameRevealsHomeInBothStyles() async throws {
        let controller = try XCTUnwrap(UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController())
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        let bounds = window.bounds
        let iris = StartupIrisView(frame: bounds)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let launch = try XCTUnwrap(controller.view)

        // Sample the backdrop, ring guide and starting dot inside their solid areas.
        let points = [CGPoint(x: 8, y: 8), CGPoint(x: bounds.midX - 31, y: bounds.midY),
                      CGPoint(x: bounds.midX, y: bounds.midY - 31)]
        for style in [UIUserInterfaceStyle.light, .dark] {
            controller.overrideUserInterfaceStyle = style
            launch.updateTraitsIfNeeded()
            launch.setNeedsLayout()
            launch.layoutIfNeeded()
            iris.style = style
            iris.setNeedsLayout()
            iris.layoutIfNeeded()
            for point in points {
                let expected = pixel(of: launch, at: point)
                let actual = pixel(of: iris, at: point)
                XCTAssertEqual(expected[3], 255)
                for channel in 0..<4 {
                    XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 4,
                                   "Style \(style.rawValue) at \(point), channel \(channel)")
                }
            }
        }

        iris.startedAt = CACurrentMediaTime() - 2
        iris.setNeedsLayout()
        iris.layoutIfNeeded()
        XCTAssertEqual(pixel(of: iris, at: CGPoint(x: bounds.midX, y: bounds.midY))[3], 255,
                       "A closed ring must keep the loading surface covered until home is ready")

        iris.opensAt = CACurrentMediaTime() - StartupIntroTiming.expansionDuration - 1
        for size in [bounds.size, CGSize(width: 1366, height: 1024), CGSize(width: 320, height: 1200)] {
            iris.frame.size = size
            iris.setNeedsLayout()
            iris.layoutIfNeeded()
            for point in points + [.zero, CGPoint(x: size.width - 1, y: size.height - 1)] {
                XCTAssertEqual(pixel(of: iris, at: point)[3], 0, "The home view should be visible at \(point)")
            }
        }
    }

    @MainActor
    private func pixel(of view: UIView, at point: CGPoint) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -point.x, y: -point.y)
            view.layer.render(in: context)
        }
        return rgba
    }
}
