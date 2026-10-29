import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class ExposureControlPresentationTests: XCTestCase {
    func testExposureReadoutAtNormalAndAccessibleTextSizes() async throws {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return XCTFail("The hosted simulator scene must be available")
        }
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: VStack(alignment: .leading, spacing: 24) {
            ExposureCompensationControl(bias: 0.8) { _ in }
            ExposureCompensationControl(bias: -2) { _ in }
            ExposureCompensationControl(bias: 0) { _ in }
                .dynamicTypeSize(.accessibility3)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.gray).preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "exposure-controls-normal-and-accessible"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exposure-controls.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("exposure_control_snapshot path=\(url.path)")
    }
}
