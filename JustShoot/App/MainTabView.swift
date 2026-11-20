import SwiftUI
import SwiftData

struct MainTabView: View {
    let customFilters: [HomeCustomFilter]
    let isRevealed: Bool
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
            FilmHomeView(customFilters: customFilters)
                .mainTabItem(.films)
            NavigationStack { GalleryView(isRevealed: isRevealed) }
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
            } else if phase == .active, isRevealed {
                Task(priority: .utility) {
                    await CapturePipeline.shared.retryPending()
                    await PhotoLibrarySync.shared.reconcile(container: modelContext.container)
                }
            }
        }
        .onChange(of: isRevealed, initial: true) { _, revealed in
            if revealed { DiagnosticTrace(id: "startup").event("app_home_interactive") }
        }
        .task(id: isRevealed, priority: .utility) {
            guard isRevealed else { return }
            await CapturePipeline.shared.configure(container: modelContext.container)
            await PhotoLibrarySync.shared.bootstrap(container: modelContext.container)
        }
        .task(id: isRevealed, priority: .utility) {
            guard isRevealed else { return }
            // A fast camera entry awaits the same shared resources in its own preparation.
            try? await PreviewMetalResources.warmUp()
            guard !Task.isCancelled else { return }
            try? await FilmProcessor.shared.warmUpForCapture()
        }
    }
}
