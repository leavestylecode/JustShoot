import SwiftUI
import SwiftData

// MARK: - SwiftData 版本化 Schema & 迁移计划
// 迁移策略：当 Photo / CustomLUT 字段增删时，新增 SchemaV2 并在 stages 中声明
// .lightweight 或 .custom 迁移步骤，避免在存量用户端崩溃
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Photo.self, CustomLUT.self] }
}

enum JustShootMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

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

// iPad windows support system rotation and multitasking. iPhone keeps its portrait
// camera layout while the controls and capture orientation follow physical holding.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        (window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom) == .pad ? .all : .portrait
    }
}

@main
struct JustShootApp: App {
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
                PreparationScreen(title: "Preparing your library…")
            } else {
                PreparationScreen(title: "Your library could not be prepared", message: startup.failureMessage,
                    isLoading: false, onAction: { Task { await startup.retry(displayScale: displayScale) } })
            }
        }
        .task { if !isRunningUnitTests { await startup.prepare(displayScale: displayScale) } }
    }
}
