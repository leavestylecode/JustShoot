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

// MARK: - AppDelegate：全局锁定竖屏（iPhone + iPad）
//
// iPadOS 26 起 Apple 不再允许 app 通过 UIRequiresFullScreen 退出多任务模式，
// 也无法在 Stage Manager / Split View 下用 requestGeometryUpdate 强制旋转。
// 因为相机预览/手势/Metal pipeline 高度依赖竖屏几何，权衡后选择整个 app 仅支持
// 竖屏——iPad 自适应网格在 744pt 仍能排 6 列。
//
// 实施：Info.plist 的 UISupportedInterfaceOrientations* 仍声明全部方向（满足
// App Store ITMS-90475 对 iPad 多任务的最低要求），运行时由这里的 .portrait
// 收窄到单一方向。AppDelegate 的返回值在 fullscreen / Stage Manager / Split View
// 下都会被读取，从而把窗口约束为竖屏比例。
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
            // 数据丢失地雷防护：只有当没有真正的迁移可走时（schemas 仅 1 个版本），init 失败才
            // 必然是数据库损坏 / 不兼容，删库重建是唯一恢复手段。一旦未来新增 SchemaV2 而忘了补
            // 迁移 stage，迁移失败会落到这里——此时绝不能静默删除用户照片，改走 fatalError 强制
            // 开发者补 .lightweight/.custom 迁移步骤。
            guard JustShootMigrationPlan.schemas.count <= 1 else {
                fatalError("ModelContainer init failed with a multi-version migration plan present — add a migration stage instead of wiping user data. Underlying error: \(error)")
            }
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