import CoreImage
import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class AppAppearanceTests: XCTestCase {
    func testSettingsIconKeepsItsRoundShapeInEverySavedStyle() throws {
        let suite = "settings-icon-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = CIContext()
        for style in SettingsIconStyle.allCases {
            defaults.set(style.rawValue, forKey: SettingsIconStyle.key)
            let renderer = ImageRenderer(content: SettingsIcon("star.circle.fill", color: .red)
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = CIImage(cgImage: try XCTUnwrap(renderer.cgImage))
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                var rgba = [UInt8](repeating: 0, count: 4)
                context.render(image, toBitmap: &rgba, rowBytes: 4,
                               bounds: CGRect(x: x, y: y, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                return rgba
            }
            XCTAssertEqual(pixel(0, 0)[3], 0)
            let rim = pixel(13, 5)
            switch style {
            case .standard:
                XCTAssertGreaterThan(rim[0], rim[1])
                XCTAssertEqual(rim[3], 255)
            case .monochrome:
                XCTAssertEqual(rim[0], rim[1])
                XCTAssertEqual(rim[3], 255)
            case .subtle:
                XCTAssertEqual(rim[0], rim[1])
                XCTAssertGreaterThan(rim[3], 0)
                XCTAssertLessThan(rim[3], 255)
            }
        }
    }

    func testAutomaticLeavesTheSystemInControl() {
        XCTAssertNil(AppAppearance.automatic.scheme)
        XCTAssertEqual(AppAppearance.light.scheme, .light)
        XCTAssertEqual(AppAppearance.dark.scheme, .dark)
    }

    func testCustomPhotoSurvivesRelaunchAndRejectedReplacementUntilRemoved() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = BackgroundPhotoFile(url: directory.appending(path: "background.jpg"))
        let store = BackgroundPhotoStore(file: file)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 500))
        let jpeg = renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 500))
        }
        try await store.replace(with: jpeg)
        XCTAssertEqual(store.image?.cgImage?.width, 768)
        XCTAssertEqual(store.image?.cgImage?.height, 384)
        do {
            try await store.replace(with: Data([0]))
            XCTFail("An invalid selection must preserve the saved background")
        } catch {
            XCTAssertNotNil(store.image)
        }
        let relaunched = BackgroundPhotoStore(file: file)
        await relaunched.loadIfNeeded()
        XCTAssertEqual(relaunched.image?.cgImage?.width, 768)
        let mild = BackgroundPhotoEffect(blur: 6, saturation: 0.65)
        await relaunched.prepare(mild)
        let first = try XCTUnwrap(relaunched.filteredImage)
        await relaunched.prepare(mild)
        XCTAssertTrue(relaunched.filteredImage === first, "Tabs must reuse the prepared background")
        await relaunched.prepare(BackgroundPhotoEffect(blur: 40, saturation: 1.4))
        XCTAssertNotNil(relaunched.filteredImage)
        XCTAssertFalse(relaunched.filteredImage === first)
        try await relaunched.remove()
        XCTAssertNil(relaunched.filteredImage)
        XCTAssertNil(relaunched.image)
        let nextLaunch = BackgroundPhotoStore(file: file)
        await nextLaunch.loadIfNeeded()
        XCTAssertNil(nextLaunch.image)
    }
}
