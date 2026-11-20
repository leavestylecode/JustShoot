import SwiftUI
import SwiftData
import UIKit
import XCTest
@testable import JustShoot

@MainActor
final class MainTabNavigationTests: XCTestCase {
    func testNativeTabBarKeepsAllDestinationsAvailableDuringScrolling() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Native tab bar minimization requires iOS 26") }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let host = UIHostingController(rootView: MainTabView(customFilters: [], isRevealed: false)
            .modelContainer(container)
            .environmentObject(FilmCurveLibrary()))
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
        while tabController(in: host)?.tabBar.items?.count != MainTab.allCases.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let tabs = try XCTUnwrap(tabController(in: host))
        XCTAssertEqual(tabs.tabBar.items?.count, MainTab.allCases.count)
        XCTAssertEqual(tabs.tabBarMinimizeBehavior, .never)
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }
}
