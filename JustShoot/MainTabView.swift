import SwiftUI
import SwiftData

// MARK: - 底部 Tab 栏（iOS 17+ 原生 TabView）
//
// 4 个固定 tab：
//   Films    首页胶片网格 + 拍摄（ContentView 本体——其内部已含 NavigationStack，承载
//            tile→CameraView 的 destination，所以不再额外包一层）
//   Photos   相册（GalleryView）
//   Library  胶片卡片库（FilmCardLibraryView）
//   Settings 设置
//
// 原来 Gallery / FilmCardLibrary 是首页工具栏按钮 push 进去的，它们的 body 自身不带
// NavigationStack（靠父级提供）。提升为顶层 tab 后，各自补一层 NavigationStack，让它们的
// navigationTitle / navigationDestination 仍然成立。
//
// 选中态用 @SceneStorage 持久化——场景恢复后回到上次停留的 tab。
struct MainTabView: View {
    let home: HomePreparationSnapshot
    @SceneStorage("selectedTab") private var selectedTab = 0
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var capturePipeline = CapturePipeline.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            ContentView(preparedHome: home)
                .tabItem { Image(systemName: "camera.filters").accessibilityLabel("Films") }
                .tag(0)
            NavigationStack { GalleryView(onStartShooting: { selectedTab = 0 }) }
                .tabItem { Image(systemName: "photo.stack").accessibilityLabel("Photos") }
                .tag(1)
            NavigationStack { FilmCardLibraryView() }
                .tabItem { Image(systemName: "books.vertical").accessibilityLabel("Library") }
                .tag(2)
            SettingsView()
                .tabItem { Image(systemName: "gearshape").accessibilityLabel("Settings") }
                .tag(3)
        }
        // 向下滚动时自动收起成 mini tab 栏（iOS 26），上滑恢复——给内容腾出更多竖向空间。
        .scrollingTabBar()
        .tint(.white)
        .preferredColorScheme(.dark)
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
