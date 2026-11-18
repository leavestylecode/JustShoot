import SwiftUI
import SwiftData

// MARK: - 全局启用右滑返回（即使隐藏了系统返回按钮）
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return viewControllers.count > 1
    }
}

// Every iPad page rotates with its window; iPhone retains its portrait interface.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppInterfaceOrientationPolicy.supportedOrientations(
            for: window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom)
    }
}

@main
struct OOOApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var curveLibrary = FilmCurveLibrary()
    @StateObject private var startup = AppStartupPreparation()
    @Environment(\.scenePhase) private var scenePhase

    private var isRunningUnitTests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppStartupContent(startup: startup, curveLibrary: curveLibrary, isRunningUnitTests: isRunningUnitTests)
                // Keep typography and scaled layout metrics at the design's default size.
                .dynamicTypeSize(.large)
                .onChange(of: scenePhase, initial: true) { _, phase in startup.setActive(phase == .active) }
        }
    }
}

private struct AppStartupContent: View {
    @ObservedObject var startup: AppStartupPreparation
    let curveLibrary: FilmCurveLibrary
    let isRunningUnitTests: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if isRunningUnitTests {
                Color.clear
            } else if let ready = startup.ready {
                MainTabView(home: ready.home)
                    .environmentObject(curveLibrary)
                    .modelContainer(ready.container)
            } else if !startup.hasFailed {
                AppStartupLoadingScreen()
            } else {
                PreparationErrorScreen(title: "Your library could not be prepared", message: startup.failureMessage,
                    onAction: { Task { await startup.retry(displayScale: displayScale) } })
            }
        }
        .task { if !isRunningUnitTests { await startup.prepare(displayScale: displayScale) } }
    }
}
