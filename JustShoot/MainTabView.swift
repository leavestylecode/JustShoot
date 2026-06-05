import SwiftUI

// MARK: - 底部 Tab 栏（iOS 26 原生 TabView）
//
// 4 个固定 tab：
//   Films    首页胶片网格 + 拍摄（ContentView 本体——其内部已含 NavigationStack，承载
//            tile→CameraView 的 zoom 过渡 destination，所以不再额外包一层）
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
    @SceneStorage("selectedTab") private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: 0) {
                ContentView()
            } label: {
                Label("Films", systemImage: "camera.filters")
            }

            Tab(value: 1) {
                NavigationStack { GalleryView() }
            } label: {
                Label("Photos", systemImage: "photo.stack")
            }

            Tab(value: 2) {
                NavigationStack { FilmCardLibraryView() }
            } label: {
                Label("Library", systemImage: "books.vertical")
            }

            Tab(value: 3) {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }
}
