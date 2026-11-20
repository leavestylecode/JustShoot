import Photos
import SwiftData

// MARK: - 反向同步观察者（library → app）
//
// 系统相册发生变化（用户在「照片」app 删图等）时，剪掉指向已删资产的本地索引行。架构（见调研）：
// 不做 changeDetails 差分 / 不用 persistent change token——统一调一个幂等的 `pruneDeletedAssets()`
// reconcile，足够简单且总是正确，适配个人相册规模。两个触发点：
//   1. 冷同步：进画廊时 GalleryView.task 调一次（覆盖「app 关闭期间被删」的情况）。
//   2. 实时：首屏打开后后台注册观察者，app 前台时系统相册一变就 reconcile（去重 400ms）。
// 规模化升级路径（如需）：改用 PHPhotoLibrary.fetchPersistentChanges(since:) 的 deletedLocalIdentifiers
// 增量，省去全量扫描；当前规模不需要。
@MainActor
final class PhotoLibrarySync: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoLibrarySync()
    private let registrationQueue = DispatchQueue(label: "com.justshoot.photos-observer", qos: .utility)
    private let register: @Sendable (PhotoLibrarySync) -> Bool
    private var container: ModelContainer?
    private var registered = false
    private var registrationTask: Task<Bool, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var didMaintain = false

    init(register: @escaping @Sendable (PhotoLibrarySync) -> Bool = PhotoLibrarySync.registerWithPhotoLibrary) {
        self.register = register
        super.init()
    }

    func start(container: ModelContainer) async {
        self.container = container
        guard !registered else { return }
        let task: Task<Bool, Never>
        if let registrationTask {
            task = registrationTask
        } else {
            task = Task(priority: .utility) {
                await withCheckedContinuation { continuation in
                    // Authorization and registration can synchronously wait for PhotoKit.
                    registrationQueue.async { [self, register] in
                        let span = DiagnosticTrace(id: "startup").span("startup_photos_observer")
                        let success = register(self)
                        span.end(success ? "ok" : "not_authorized", "main_thread=\(Thread.isMainThread)")
                        continuation.resume(returning: success)
                    }
                }
            }
            registrationTask = task
        }
        let success = await task.value
        guard registrationTask == task else { return }
        registered = success
        registrationTask = nil
    }

    nonisolated private static func registerWithPhotoLibrary(_ observer: PhotoLibrarySync) -> Bool {
        guard PhotoLibrary.isAuthorized else { return false }
        PHPhotoLibrary.shared().register(observer)
        return true
    }

    func bootstrap(container: ModelContainer) async {
        async let observer: Void = start(container: container)
        if !didMaintain {
            didMaintain = true
            let maintenance = await LibraryMaintenance.background(container: container)
            await maintenance.performLaunchMaintenance()
        }
        await observer
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.needsAnotherPass = true
            await self.reconcile()
        }
    }

    func reconcile(container: ModelContainer) async {
        await start(container: container)
        await reconcile()
    }

    private func reconcile() async {
        if let reconcileTask { await reconcileTask.value; return }
        guard let container else { return }
        let task = Task {
            let reconciliation = DiagnosticTrace(id: "library-sync").span("library_reconcile")
            defer { reconciliation.end() }
            let reconciler = await PhotoLibraryReconciler.background(container: container)
            repeat {
                self.needsAnotherPass = false
                try? await Task.sleep(for: .milliseconds(400))
                await reconciler.reconcileWithLibrary()
            } while self.needsAnotherPass
            NotificationCenter.default.post(name: .photoLibraryDidReconcile, object: nil)
        }
        reconcileTask = task
        await task.value
        reconcileTask = nil
        if needsAnotherPass { await reconcile() }
    }

}

extension Notification.Name {
    /// PhotoLibrarySync 完成一轮 reconcile（剪枝已删资产的索引行）后发出。
    static let photoLibraryDidReconcile = Notification.Name("photoLibraryDidReconcile")
}
