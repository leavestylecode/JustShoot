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

// MARK: - AppDelegate：全局锁定竖屏
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
}

@main
struct JustShootApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: JustShootMigrationPlan.self,
                configurations: [modelConfiguration]
            )
        } catch {
            // 数据库损坏时尝试删除旧数据库并重建
            let url = modelConfiguration.url
            try? FileManager.default.removeItem(at: url)
            // 同时清理 WAL/SHM 文件
            try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))

            do {
                return try ModelContainer(
                    for: schema,
                    migrationPlan: JustShootMigrationPlan.self,
                    configurations: [modelConfiguration]
                )
            } catch {
                fatalError("Could not create ModelContainer after recovery: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
} 