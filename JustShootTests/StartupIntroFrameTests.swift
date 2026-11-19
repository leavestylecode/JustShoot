import UIKit
import XCTest
@testable import JustShoot

final class StartupIntroFrameTests: XCTestCase {
    func testReadyHomeWaitsForTraceAndHold() {
        XCTAssertEqual(StartupIntroTiming.revealStart(tracingFrom: 10, homeReadyAt: 10.1),
                       10 + StartupIntroTiming.traceDuration + StartupIntroTiming.holdDuration)
    }

    func testLateHomeOpensAsSoonAsItIsReady() {
        XCTAssertEqual(StartupIntroTiming.revealStart(tracingFrom: 10, homeReadyAt: 12), 12)
    }

    @MainActor
    func testReadyHomeStartsOnDisplayAndFinishesAfterTheBladesClear() async throws {
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let mark = StartupMarkView(frame: window.bounds)
        controller.view.addSubview(mark)
        mark.startedAt = CACurrentMediaTime() - 2
        mark.layoutIfNeeded()
        XCTAssertNil(mark.revealAt)
        let finished = expectation(description: "Aperture cleared the page")
        mark.onFinished = { finished.fulfill() }
        let readyAt = CACurrentMediaTime()
        mark.homeReady = true
        mark.setNeedsLayout()
        mark.layoutIfNeeded()
        await fulfillment(of: [finished], timeout: 4)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(mark.revealAt), readyAt)
        XCTAssertEqual(pixel(in: mark.layer, at: CGPoint(x: 8, y: 8))[3], 0)
    }

    @MainActor
    func testBladesRevealHomeAtTheCenterWhileStillCoveringTheCorners() async throws {
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let mark = StartupMarkView(frame: window.bounds)
        controller.view.addSubview(mark)
        mark.style = .light
        let now = CACurrentMediaTime()
        mark.startedAt = now - 1
        mark.revealAt = now
        mark.setNeedsLayout()
        mark.layoutIfNeeded()
        let midpoint = mark.layer.convertTime(now + StartupIntroTiming.revealDuration / 2, from: nil)
        mark.layer.speed = 0
        mark.layer.timeOffset = midpoint
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))

        let frame = try XCTUnwrap(mark.layer.presentation())
        let center = CGPoint(x: mark.bounds.midX, y: mark.bounds.midY)
        let centerAlpha = Int(pixel(in: frame, at: center)[3])
        XCTAssertEqual(centerAlpha, 0)
        for point in [CGPoint(x: 8, y: 8), CGPoint(x: mark.bounds.maxX - 8, y: mark.bounds.maxY - 8)] {
            XCTAssertEqual(pixel(in: frame, at: point)[3], 255)
        }
    }

    func testDiaphragmClosesBeforeItOpensAndClearsTheWholeWindow() throws {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 1024, height: 768)] {
            let poses = StartupAperture.poses(in: size)
            let closed = try XCTUnwrap(poses.first { $0.radius == 0 })
            let last = try XCTUnwrap(poses.last)
            XCTAssertGreaterThan(try XCTUnwrap(poses.first).radius, closed.radius)
            XCTAssertEqual(last.time, 1)
            let closedFaces = (0..<6).map { closed.outline(for: $0, in: size).face }
            let openFaces = (0..<6).map { last.outline(for: $0, in: size).face }
            for x in stride(from: 1.0, to: size.width, by: 19) {
                for y in stride(from: 1.0, to: size.height, by: 23) {
                    let p = CGPoint(x: x, y: y)
                    XCTAssertTrue(closedFaces.contains { $0.contains(p) })
                    XCTAssertFalse(openFaces.contains { $0.contains(p) })
                }
            }
        }
    }

    @MainActor
    func testFirstFrameMatchesLaunchScreenAndFinalFrameRevealsHomeInBothStyles() async throws {
        let controller = try XCTUnwrap(UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController())
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        let bounds = window.bounds
        let mark = StartupMarkView(frame: bounds)
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
            mark.style = style
            mark.setNeedsLayout()
            mark.layoutIfNeeded()
            for point in points {
                let expected = pixel(in: launch.layer, at: point)
                let actual = pixel(in: mark.layer, at: point)
                XCTAssertEqual(expected[3], 255)
                for channel in 0..<4 {
                    XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 4,
                                   "Style \(style.rawValue) at \(point), channel \(channel)")
                }
            }
        }

        mark.startedAt = CACurrentMediaTime() - 2
        mark.setNeedsLayout()
        mark.layoutIfNeeded()
        XCTAssertEqual(pixel(in: mark.layer, at: CGPoint(x: bounds.midX, y: bounds.midY))[3], 255,
                       "A closed ring must keep the loading surface covered until home is ready")

        mark.revealAt = CACurrentMediaTime() - StartupIntroTiming.revealDuration - 1
        for size in [bounds.size, CGSize(width: 1366, height: 1024), CGSize(width: 320, height: 1200)] {
            mark.frame.size = size
            mark.setNeedsLayout()
            mark.layoutIfNeeded()
            for point in points + [.zero, CGPoint(x: size.width - 1, y: size.height - 1)] {
                XCTAssertEqual(pixel(in: mark.layer, at: point)[3], 0, "The home view should be visible at \(point)")
            }
        }
    }

    @MainActor
    private func pixel(in layer: CALayer, at point: CGPoint) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -point.x, y: -point.y)
            layer.render(in: context)
        }
        return rgba
    }
}
