import CoreImage
import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class AppAppearanceTests: XCTestCase {
    func testPageContainersScrollWithTheirIndicatorsHidden() async throws {
        let window = UIWindow(windowScene: try await TestWindowScene.foreground())
        let rows = ForEach(0..<50) { index in Text(verbatim: String(index)) }
        let page = VStack {
            List { rows }.frame(height: 120)
            Form { rows }.frame(height: 120)
            ScrollView { Color.clear.frame(height: 900) }.frame(height: 80)
            ScrollView(.horizontal) { Color.clear.frame(width: 900, height: 50) }
                .frame(width: 140, height: 50)
        }
        let host = UIHostingController(rootView: page.appVisualDesign())
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        func scrollViews(in view: UIView) -> [UIScrollView] {
            let subviews = view.subviews.flatMap { scrollViews(in: $0) }
            return (view as? UIScrollView).map { [$0] + subviews } ?? subviews
        }
        let containers = scrollViews(in: host.view)
        let vertical = containers.filter { $0.contentSize.height > $0.bounds.height }
        let horizontal = containers.filter { $0.contentSize.width > $0.bounds.width }
        XCTAssertEqual(vertical.count, 3)
        XCTAssertEqual(horizontal.count, 1)
        for scroll in vertical {
            XCTAssertTrue(scroll.isScrollEnabled)
            XCTAssertFalse(scroll.showsVerticalScrollIndicator)
        }
        for scroll in horizontal {
            XCTAssertTrue(scroll.isScrollEnabled)
            XCTAssertFalse(scroll.showsHorizontalScrollIndicator)
        }
    }

    func testNativeControlsInheritDesignTraitsFromTheAppScene() async throws {
        let scene = try await TestWindowScene.foreground()
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        XCTAssertTrue(scene.traitOverrides.contains(UITraitPreferredContentSizeCategory.self))
        XCTAssertTrue(scene.traitOverrides.contains(UITraitLegibilityWeight.self))
        XCTAssertTrue(scene.traitOverrides.contains(UITraitAccessibilityContrast.self))
        XCTAssertEqual(navigation.navigationBar.traitCollection.preferredContentSizeCategory, .large)
        XCTAssertEqual(navigation.navigationBar.traitCollection.legibilityWeight, .regular)
        XCTAssertEqual(navigation.navigationBar.traitCollection.accessibilityContrast, .normal)
    }

    func testHostedTypographyRendersIdenticallyAtBothTextSizeExtremes() throws {
        struct Sample: View {
            @ScaledMetric(relativeTo: .body) var inset = 12.0
            var body: some View {
                Text(verbatim: "Portra 400").font(.body).padding(inset)
            }
        }
        func render(_ size: DynamicTypeSize, _ weight: LegibilityWeight) throws -> Data {
            let renderer = ImageRenderer(content: Sample().appVisualDesign()
                .dynamicTypeSize(size).environment(\.legibilityWeight, weight))
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        let baseline = try render(.large, .regular)
        XCTAssertEqual(try render(.xSmall, .regular), baseline)
        XCTAssertEqual(try render(.accessibility5, .bold), baseline)
    }

    func testControlAndCardSurfacesPreserveBackdropColorsInsideAndOutsideTheirEdges() async throws {
        let scene = try await TestWindowScene.foreground()
        let window = UIWindow(windowScene: scene)
        let content = HStack(spacing: 0) {
            Color(red: 1, green: 0, blue: 0)
            Color(red: 0, green: 0, blue: 1)
        }
        .overlay {
            VStack(spacing: 0) {
                Rectangle().fill(AppSurfaceMaterial.regular)
                Color.clear.settingsGlassCard()
                Color.clear.cameraControlSurface()
            }
            .padding(.horizontal, 32)
        }
        .ignoresSafeArea()
        window.rootViewController = UIHostingController(rootView: content)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        // Snapshot the entire window so the compositor can sample both sides of the backdrop.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let bitmap = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let image = CIImage(cgImage: try XCTUnwrap(bitmap.cgImage))
        let context = CIContext()
        func pixel(x: CGFloat, y: CGFloat) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            let point = CGRect(x: floor(image.extent.width * x), y: floor(image.extent.height * y), width: 1, height: 1)
            context.render(image, toBitmap: &rgba, rowBytes: 4, bounds: point,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return rgba
        }
        let rowCenters: [CGFloat] = [1.0 / 6, 0.5, 5.0 / 6]
        for y in rowCenters {
            let left = pixel(x: 0.2, y: y)
            let right = pixel(x: 0.8, y: y)
            XCTAssertGreaterThan(Int(left[0]) - Int(right[0]), 15)
            XCTAssertGreaterThan(Int(right[2]) - Int(left[2]), 15)
            // Four points outside either edge, the original background should be untouched.
            let inset = 28 / image.extent.width
            XCTAssertEqual(pixel(x: inset, y: y), pixel(x: 0.01, y: y))
            XCTAssertEqual(pixel(x: 1 - inset, y: y), pixel(x: 0.99, y: y))
        }
    }

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
