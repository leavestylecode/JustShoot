import CoreImage
import SwiftData
import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class RecentPhotoBadgeTests: XCTestCase {
    func testOnlySavingDarkensTheCenterOfTheThumbnailInEveryOrientation() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        let size = CGSize(width: 46, height: 46)
        let thumbnail = UIGraphicsImageRenderer(size: size).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
        }
        let preview = CapturePreview(id: UUID(), filterName: "test", image: thumbnail)
        let context = CIContext()
        let states: [(angle: Double, orientation: UIDeviceOrientation, saving: Bool)] = [
            (0, .portrait, false), (0, .portrait, true),
            (90, .landscapeLeft, true), (-90, .landscapeRight, true), (180, .portraitUpsideDown, true)
        ]
        for state in states {
            let host = UIHostingController(rootView: RecentPhotosBadge(
                lastThumbnailHint: .constant(nil), pendingPreview: preview,
                isShutterBusy: !state.saving, isProcessing: state.saving,
                controlRotationAngle: .degrees(state.angle), orientation: state.orientation)
                .buttonStyle(.plain)
                .environment(\.horizontalSizeClass, .compact)
                .modelContainer(container)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .ignoresSafeArea())
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let bounds = host.view.bounds
                host.view.drawHierarchy(in: bounds.offsetBy(dx: size.width / 2 - bounds.midX,
                    dy: size.height / 2 - bounds.midY), afterScreenUpdates: true)
            }
            let pixels = CIImage(cgImage: try XCTUnwrap(image.cgImage))
            func brightness(x: Int, y: Int) -> Int {
                var rgba = [UInt8](repeating: 0, count: 4)
                context.render(pixels, toBitmap: &rgba, rowBytes: 4,
                    bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB())
                return Int(rgba[0])
            }
            let edge = brightness(x: 6, y: 23)
            let center = brightness(x: 23, y: 23)
            XCTAssertGreaterThan(edge, 80, "The thumbnail must be visible")
            if state.saving {
                XCTAssertGreaterThan(edge - center, 70, "Saving at \(state.angle)°")
            } else {
                XCTAssertEqual(edge, center, accuracy: 8, "A busy shutter must leave the previous photo clear")
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Recent photo · \(state.saving ? "saving" : "capturing") · \(state.angle)°"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
