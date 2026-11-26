import CloudKit
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
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic
    @StateObject private var curveLibrary = FilmCurveLibrary.shared
    @StateObject private var startup = AppStartupPreparation()
    @State private var membership = MembershipStore()
    @State private var introFinished = false
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
            AppStartupContent(startup: startup, curveLibrary: curveLibrary, isRunningUnitTests: isRunningUnitTests,
                              introFinished: $introFinished)
                .environment(membership)
                .appVisualDesign()
                .preferredColorScheme(appearance.scheme)
                .onChange(of: scenePhase, initial: true) { _, phase in startup.setActive(phase == .active) }
                .task(id: scenePhase, priority: .utility) {
                    guard !isRunningUnitTests else { return }
                    membership.startTransactionListener()
                    if scenePhase == .active { await membership.refreshEntitlement() }
                }
                .task(id: scenePhase, priority: .utility) {
                    guard !isRunningUnitTests, scenePhase == .active else { return }
                    curveLibrary.refreshCloud()
                    let profile = SettingsProfileStore.shared
                    profile.refresh()
                    while (try? await Task.sleep(for: .seconds(30))) != nil {
                        profile.retryPendingChanges()
                    }
                }
                .task(id: scenePhase, priority: .utility) {
                    guard !isRunningUnitTests, scenePhase == .active else { return }
                    while (try? await Task.sleep(for: .seconds(120))) != nil {
                        curveLibrary.refreshCloud()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    if !isRunningUnitTests {
                        curveLibrary.cloudAccountChanged()
                        SettingsProfileStore.shared.accountDidChange()
                    }
                }
        }
    }
}

private struct AppStartupContent: View {
    @ObservedObject var startup: AppStartupPreparation
    let curveLibrary: FilmCurveLibrary
    let isRunningUnitTests: Bool
    @Binding var introFinished: Bool

    private var showsIntro: Bool {
        !startup.hasFailed && (!introFinished || startup.ready == nil)
    }

    var body: some View {
        if isRunningUnitTests {
            Color.clear
        } else {
            ZStack {
                if let ready = startup.ready {
                    MainTabView(customFilters: ready.customFilters, isRevealed: !showsIntro)
                        .environmentObject(curveLibrary)
                        .modelContainer(ready.container)
                        .allowsHitTesting(!showsIntro)
                        .accessibilityHidden(showsIntro)
                } else if startup.hasFailed {
                    PreparationErrorScreen(title: "Your library could not be prepared", systemImage: "photo.stack", message: startup.failureMessage,
                        onAction: { Task { await startup.retry() } })
                } else if introFinished {
                    AppPageBackground()
                        .zIndex(0.5)
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                }

                if showsIntro {
                    AppStartupIntro(homeReady: startup.ready != nil, isFinished: $introFinished)
                        .zIndex(1)
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                }
            }
            .statusBarHidden(showsIntro)
            .onChange(of: startup.hasFailed) { _, failed in
                if failed { introFinished = true }
            }
            .task { await startup.prepare() }
        }
    }
}
