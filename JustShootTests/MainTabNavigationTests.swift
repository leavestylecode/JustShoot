import SwiftUI
import SwiftData
import UIKit
import XCTest
@testable import JustShoot

@MainActor
final class MainTabNavigationTests: XCTestCase {
    func testMainTabBarKeepsAllDestinationsAvailable() async throws {
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let host = UIHostingController(rootView: MainTabView(customFilters: [], isRevealed: false)
            .modelContainer(container)
            .environmentObject(FilmCurveLibrary())
            .environment(MembershipStore()))
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let deadline = ContinuousClock.now + .seconds(3)
        if #available(iOS 26, *) {
            while tabController(in: host)?.tabBar.items?.count != MainTab.allCases.count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let tabs = try XCTUnwrap(tabController(in: host))
            XCTAssertEqual(tabs.tabBar.items?.count, MainTab.allCases.count)
            XCTAssertEqual(tabs.tabBarMinimizeBehavior, .never)
        } else {
            while legacyTabBar(in: host.view)?.selectedItem == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let bar = try XCTUnwrap(legacyTabBar(in: host.view))
            XCTAssertNotNil(bar.selectedItem)
            XCTAssertEqual(bar.items?.map(\.accessibilityLabel), MainTab.allCases.map { String(localized: $0.title) })
        }
    }

    func testLegacyTabBarFitsAContainerWithoutBottomSafeArea() async throws {
        if #available(iOS 26, *) { throw XCTSkip("The system positions the tab bar on iOS 26 and later") }
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        // Embedding away from the window edges also exercises the zero inset on home-button phones.
        let host = UIHostingController(rootView: Color.clear.mainTabRoot(.films)
            .environment(\.capsuleTabSelection, .constant(.films)))
        root.addChild(host)
        host.view.frame = root.view.bounds.insetBy(dx: 16, dy: 80)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        host.view.layoutIfNeeded()

        let deadline = ContinuousClock.now + .seconds(3)
        while legacyTabBar(in: host.view)?.bounds.isEmpty != false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let bar = try XCTUnwrap(legacyTabBar(in: host.view))
        XCTAssertEqual(host.view.safeAreaInsets.bottom, 0)
        XCTAssertTrue(host.view.bounds.contains(bar.convert(bar.bounds, to: host.view)))
    }

    func testLegacyBackButtonUsesNativeNavigationAndScopedAppearance() async throws {
        if #available(iOS 26, *) { throw XCTSkip("Back appearance is native on iOS 26 and later") }
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let root = UIViewController()
        root.title = "Settings"
        root.navigationItem.backButtonDisplayMode = .generic
        let originalButton = UIBarButtonItem(title: "Previous", style: .plain, target: nil, action: nil)
        root.navigationItem.backBarButtonItem = originalButton
        let nav = UINavigationController(rootViewController: root)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let nativeIndicator = nav.navigationBar.standardAppearance.backIndicatorImage
        let edgeGestureEnabled = nav.interactivePopGestureRecognizer?.isEnabled
        let destination = UIHostingController(rootView: Color.clear.matchingNavigationBackButton())
        let trailing = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        destination.navigationItem.rightBarButtonItem = UIBarButtonItem(customView: trailing)
        nav.pushViewController(destination, animated: false)

        let deadline = ContinuousClock.now + .seconds(3)
        while destination.navigationItem.standardAppearance == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        nav.navigationBar.layoutIfNeeded()
        // iOS 17 draws the system indicator alongside an image on backBarButtonItem.
        // Only the indicator may supply a glyph, even if SwiftUI replaces a bar appearance.
        XCTAssertNil(root.navigationItem.backBarButtonItem)
        let image = try XCTUnwrap(destination.navigationItem.standardAppearance?.backIndicatorImage)
        XCTAssertEqual(destination.navigationItem.compactAppearance?.backIndicatorImage.size, CGSize(width: 32, height: 32))
        // Measure the visible image in the live bar. UIKit can scale a 44 pt asset down
        // to its chevron slot even when the source image reports the expected size.
        let bar = nav.navigationBar
        let imageView = try XCTUnwrap(backImageView(in: bar, image: image))
        let frame = imageView.convert(imageView.bounds, to: bar)
        XCTAssertEqual(frame.width, 44, accuracy: 1)
        XCTAssertEqual(frame.height, 44, accuracy: 1)
        XCTAssertEqual(frame.midY, bar.bounds.midY, accuracy: 1)
        let trailingFrame = trailing.convert(trailing.bounds, to: bar)
        let rtl = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let backInset = rtl ? bar.bounds.maxX - frame.maxX : frame.minX
        let trailingInset = rtl ? trailingFrame.minX : bar.bounds.maxX - trailingFrame.maxX
        XCTAssertEqual(backInset, trailingInset, accuracy: 2)
        func control(at point: CGPoint) -> UIControl? {
            var view = bar.hitTest(point, with: nil)
            while let current = view {
                if let control = current as? UIControl { return control }
                view = current.superview
            }
            return nil
        }
        let hitTarget = try XCTUnwrap(control(at: CGPoint(x: frame.midX, y: frame.midY)))
        for x in [frame.minX + 1, frame.maxX - 1] {
            for y in [frame.minY + 1, frame.maxY - 1] {
                XCTAssertTrue(control(at: CGPoint(x: x, y: y)) === hitTarget)
            }
        }
        XCTAssertEqual(root.navigationItem.backButtonDisplayMode, .minimal)
        XCTAssertFalse(destination.navigationItem.hidesBackButton)
        XCTAssertNil(destination.navigationItem.leftBarButtonItem)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, edgeGestureEnabled)

        XCTAssertTrue(nav.popViewController(animated: false) === destination)
        XCTAssertTrue(nav.topViewController === root)
        // UIKit can finish forwarding disappearance to embedded controllers on the next run loop.
        let popDeadline = ContinuousClock.now + .seconds(3)
        while root.navigationItem.backButtonDisplayMode == .minimal, ContinuousClock.now < popDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(root.navigationItem.backButtonDisplayMode, .generic)
        XCTAssertTrue(root.navigationItem.backBarButtonItem === originalButton)
        XCTAssertNil(destination.navigationItem.standardAppearance)
        XCTAssertEqual(nav.navigationBar.standardAppearance.backIndicatorImage, nativeIndicator)
    }

    private func backImageView(in view: UIView, image: UIImage) -> UIImageView? {
        if let imageView = view as? UIImageView, imageView.image == image { return imageView }
        return view.subviews.lazy.compactMap { self.backImageView(in: $0, image: image) }.first
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }

    private func legacyTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar, bar.accessibilityIdentifier == "main.tabs" { return bar }
        return view.subviews.lazy.compactMap { self.legacyTabBar(in: $0) }.first
    }
}
