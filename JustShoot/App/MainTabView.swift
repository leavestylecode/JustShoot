import SwiftUI
import SwiftData

struct MainTabView: View {
    let home: HomePreparationSnapshot
    @SceneStorage("selectedTab") private var selectedTab = MainTab.films
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var capturePipeline = CapturePipeline.shared
    @Environment(\.scenePhase) private var scenePhase

    private var capsuleSelection: Binding<MainTab>? {
        if #available(iOS 26, *) { return nil }
        return $selectedTab
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            FilmHomeView(preparedHome: home)
                .mainTabItem(.films)
            NavigationStack { GalleryView() }
                .mainTabItem(.photos)
            NavigationStack { FilmCardLibraryView() }
                .mainTabItem(.library)
            SettingsView()
                .mainTabItem(.settings)
        }
        .environment(\.capsuleTabSelection, capsuleSelection)
        // 向下滚动时自动收起成 mini tab 栏（iOS 26），上滑恢复——给内容腾出更多竖向空间。
        .scrollingTabBar()
        .tint(.primary)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            ImageLoader.shared.clearCache()
            AssetImageLoader.shared.clearCache()
        }
        // 启动时注册系统相册变化观察者：app 前台时在「照片」里删图会实时同步剪掉本地索引。
        // 随后跑一次启动维护（@ModelActor 后台执行，不占主线程）：清 tmp 残留视频/分享导出、
        // 磁盘缓存与 CustomLUTs 目录的孤儿文件对账。
        .alert("Photo saving", isPresented: Binding(
            get: { capturePipeline.lastError != nil },
            set: { if !$0 { capturePipeline.lastError = nil } }
        )) {
            Button("OK") { capturePipeline.lastError = nil }
        } message: {
            Text(capturePipeline.lastError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await capturePipeline.enterBackground() }
            } else if phase == .active {
                Task {
                    await CapturePipeline.shared.retryPending()
                    await PhotoLibrarySync.shared.reconcile()
                }
            }
        }
        .task {
            await CapturePipeline.shared.configure(container: modelContext.container)
            await PhotoLibrarySync.shared.bootstrap(container: modelContext.container)
        }
        .task {
            // Start the shared CIContext after home appears, without extending launch readiness.
            // A fast camera entry joins the same protected initialization in the background.
            try? await FilmProcessor.shared.warmUpForCapture()
        }
    }
}
