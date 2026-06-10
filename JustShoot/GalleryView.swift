import SwiftUI
import SwiftData
import UIKit
import os
import Photos
import CoreLocation
import ImageIO

// MARK: - 相册视图（SwiftUI 外壳 + UIKit 网格）
//
// 网格本体（滚动 / cell / 预取 / 原生两指拖动多选）在 PhotoGridView.swift（UICollectionView）——
// SwiftUI LazyVGrid + 自定义手势在大网格下既卡顿、又无法与滚动共存（详见 PhotoGridView 顶部注释）。
// 本文件保留 SwiftUI 外壳：导航标题、选择模式工具栏（Select / Select All / xmark / Download /
// Delete）、tab 栏隐藏、批量保存/删除、详情 push。选择状态通过 @Binding 与 PhotoGridView 双向同步。
struct GalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.timestamp, order: .reverse) private var photos: [Photo]

    @State private var selectedDetail: DetailPayload?
    @State private var isSelecting = false
    @State private var selectedPhotos: Set<UUID> = []

    // 网格布局（左上角菜单切换，持久化）
    @AppStorage("gallery.density") private var density: GalleryDensity = .standard
    @AppStorage("gallery.shape") private var shape: GalleryShape = .rounded

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if photos.isEmpty {
                emptyState
            } else {
                PhotoGridView(
                    photos: photos,
                    columns: density.columns,
                    cornerRadius: shape.cornerRadius,
                    isSelecting: $isSelecting,
                    selectedPhotos: $selectedPhotos,
                    onOpen: { photo in
                        selectedDetail = DetailPayload(startPhoto: photo, photos: Array(photos))
                    }
                )
                // 忽略上下安全区：collection view 延伸到 nav 栏 / tab 栏之下，靠
                // contentInsetAdjustmentBehavior=.automatic 把首/末行内边距顶到安全区内，
                // 内容可以滚到顶部 nav 栏之下。
                .ignoresSafeArea()
            }
        }
        .navigationTitle(isSelecting ? Text("\(selectedPhotos.count) selected") : Text("Gallery"))
        .navigationBarTitleDisplayMode(.inline)
        // 选择模式隐藏底部 tab 栏，让位给 Download / Delete 操作栏（Photos.app 一致）。
        .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
        .toolbar {
            // 全选放左上、xmark 放右上——两端分置，不挤在一起。
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelecting {
                    Button("Select All") { toggleSelectAll() }
                } else if !photos.isEmpty {
                    layoutMenu
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button { exitSelection() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Done selecting")
                } else if !photos.isEmpty {
                    Button("Select") {
                        withAnimation(.easeInOut(duration: 0.25)) { isSelecting = true }
                    }
                }
            }
        }
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    Spacer()

                    // 照片真相源已在系统相册（JustShoot 相簿），无需再「导出」。删除走 PhotoKit，
                    // 系统会弹原生删除确认，可在「最近删除」恢复。
                    Button(action: deleteSelectedPhotos) {
                        Image(systemName: "trash")
                            .font(.system(size: 18))
                            .foregroundColor(selectedPhotos.isEmpty ? .gray : .red)
                    }
                    .disabled(selectedPhotos.isEmpty)
                    .accessibilityLabel("Delete")
                }
            }
        }
        // 冷同步：进画廊时与系统相册对账——剪掉「app 关闭期间在系统相册被删」的索引行 +
        // 回填相簿里有资产但索引缺行的孤儿（索引写入失败 / 另一台设备 iCloud 同入的照片）。
        // app 前台时的实时同步由 PhotoLibrarySync 观察者负责（见 MainTabView）。
        .task {
            await PhotoSaver(modelContainer: modelContext.container).reconcileWithLibrary()
        }
        // 详情用 fullScreenCover 呈现：**真全屏**（边到边，无 sheet 顶部留白/圆角），照片占满整屏。
        // 下滑退出由 PhotoDetailView 内的交互式 drag-to-dismiss 实现（fit 比例下拉照片跟手缩小+背景
        // 渐暗+chrome 隐藏，过阈值松手关闭）；右上 xmark 作为补充关闭入口。
        .fullScreenCover(item: $selectedDetail) { payload in
            NavigationStack {
                PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { selectedDetail = nil } label: {
                                Image(systemName: "xmark").fontWeight(.semibold)
                            }
                            .tint(.white)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    /// 左上角网格布局切换：Menu + 两个 inline Picker（密度 + 形状）。切换后 @AppStorage 落库、
    /// PhotoGridView 平滑 reflow。
    private var layoutMenu: some View {
        Menu {
            Picker("Grid size", selection: $density) {
                ForEach(GalleryDensity.allCases) { d in Text(d.displayName).tag(d) }
            }
            .pickerStyle(.inline)
            Picker("Corners", selection: $shape) {
                ForEach(GalleryShape.allCases) { s in Text(s.displayName).tag(s) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityLabel("Grid layout options")
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyState: some View {
        VStack {
            Image(systemName: "photo")
                .font(.system(size: 80))
                .foregroundColor(.gray.opacity(0.5))
            Text("No photos yet")
                .font(.title3)
                .foregroundColor(.gray)
                .padding(.top, 16)
            Text("Head to the camera to start shooting")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.6))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Actions

    /// 全选 / 取消全选：已全选则清空，否则选中全部。
    private func toggleSelectAll() {
        let allPhotoIds = Set(photos.map { $0.id })
        if selectedPhotos.count == allPhotoIds.count {
            selectedPhotos.removeAll()
        } else {
            selectedPhotos = allPhotoIds
        }
    }

    /// 退出选择模式（右上 xmark）：清空选中、恢复 tab 栏。isSelecting 切换包在 withAnimation 里——
    /// 驱动 tab 栏 ↔ 底部操作栏的过渡平滑。
    private func exitSelection() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isSelecting = false
        }
        selectedPhotos.removeAll()
    }

    /// 删除选中照片。真相源在系统相册：先 PHAsset 删除（系统弹原生确认，支持「最近删除」恢复），
    /// 确认成功后再删 SwiftData 索引行。用户在系统弹窗取消 → 抛错 → 保留所有行，UI 不变。
    /// 全部为遗留内部照片（无 assetLocalIdentifier，迁移窗口内极少见）时直接删行。
    private func deleteSelectedPhotos() {
        let ids = selectedPhotos
        let toDelete = photos.filter { ids.contains($0.id) }
        guard !toDelete.isEmpty else { return }
        let assetIDs = toDelete.compactMap { $0.assetLocalIdentifier }
        let rowIDs = toDelete.map { $0.id }
        let container = modelContext.container

        Task { @MainActor in
            do {
                if !assetIDs.isEmpty {
                    try await PhotoLibrary.delete(localIdentifiers: assetIDs)
                }
                let saver = PhotoSaver(modelContainer: container)
                try await saver.delete(ids: rowIDs)
                for id in rowIDs { ImageLoader.shared.removeDiskCache(for: id) }
                selectedPhotos.removeAll()
                withAnimation(.easeInOut(duration: 0.25)) { isSelecting = false }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Log.save.info("photos_deleted count=\(rowIDs.count)")
            } catch {
                // 用户取消系统删除确认 / 删除失败：保留索引行，不改 UI。
                Log.save.info("photos_delete_cancelled_or_failed count=\(rowIDs.count) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Detail navigation payload
private struct DetailPayload: Identifiable, Equatable, Hashable {
    var id: UUID { startPhoto.id }
    let startPhoto: Photo
    let photos: [Photo]
    static func == (lhs: DetailPayload, rhs: DetailPayload) -> Bool { lhs.startPhoto.id == rhs.startPhoto.id }
    func hash(into hasher: inout Hasher) { hasher.combine(startPhoto.id) }
}
