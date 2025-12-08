import SwiftUI
import SwiftData

// MARK: - 方向锁定管理器
class OrientationManager: ObservableObject {
    static let shared = OrientationManager()

    @Published var orientationLock: UIInterfaceOrientationMask = .all

    func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        orientationLock = orientation
    }

    func unlockOrientation() {
        orientationLock = .all
    }
}

// MARK: - AppDelegate 用于控制方向
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return OrientationManager.shared.orientationLock
    }
}

@main
struct JustShootApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Photo.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
} 