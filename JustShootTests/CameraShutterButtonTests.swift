import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class CameraShutterButtonTests: XCTestCase {
    private func render(preparing: Bool = false, capturing: Bool = false,
                        canCapture: Bool = true, enabled: Bool = true) throws -> UIImage {
        let renderer = ImageRenderer(content: CameraShutterButton(
            isCapturing: capturing, isPreparingFilm: preparing,
            canCapture: canCapture, isPressed: false, action: {})
            .disabled(!enabled)
            .frame(width: 96, height: 96)
            .background(.black)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    private func centerBrightness(_ image: UIImage) throws -> CGFloat {
        let cgImage = try XCTUnwrap(image.cgImage)
        let center = try XCTUnwrap(cgImage.cropping(to: CGRect(x: 48, y: 48, width: 1, height: 1)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return CGFloat(pixel[0]) / 255
    }

    func testFilmPreparationKeepsTheReadyShutterPixels() throws {
        let ready = try render()
        let preparing = try render(preparing: true)
        XCTAssertGreaterThan(try centerBrightness(ready), 0.95)
        XCTAssertEqual(ready.pngData(), preparing.pngData(),
            "Repeated color LUT preparation must not flash the shutter between white and gray")

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 96))
        let states = [ready, preparing, try render(capturing: true), try render(canCapture: false)]
        let image = renderer.image { _ in
            for (index, state) in states.enumerated() {
                state.draw(in: CGRect(x: index * 96, y: 0, width: 96, height: 96))
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Shutter: ready, preparing color, capturing, waiting for save"
        attachment.lifetime = .keepAlways
        add(attachment)
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("JustShoot-shutter-states.png"))
    }

    func testCaptureSaveAndParentDisabledStatesStillDimTheShutter() throws {
        for image in [try render(capturing: true), try render(canCapture: false),
                      try render(enabled: false), try render(preparing: true, canCapture: false)] {
            let brightness = try centerBrightness(image)
            XCTAssertGreaterThan(brightness, 0.3)
            XCTAssertLessThan(brightness, 0.8)
        }
    }
}
