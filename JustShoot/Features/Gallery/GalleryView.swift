import SwiftUI
import SwiftData
import UIKit
import os
import Photos
import CoreLocation
import ImageIO

// MARK: - 相册视图（SwiftUI 外壳 + UIKit 网格）
//
// SwiftUI 管理导航、批量操作和详情呈现，UIKit 网格管理滚动、缩放和缩略图复用。
struct GalleryView: View {
    var isRevealed = true

    @Environment(\.modelContext) private var modelContext
    @Environment(\.capsuleTabSelection) private var capsuleTabSelection
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \Photo.timestamp, order: .reverse) private var photos: [Photo]

    @State private var selectedDetail: PhotoDetailSelection?
    @State private var transitionSource = PhotoGridTransitionSource()
    @State private var isSelecting = false
    @State private var selectedPhotos: Set<UUID> = []
    @State private var isPreparingShare = false
    @State private var isVisible = false

    @AppStorage("gallery.density") private var zoomColumns = 0

    var body: some View {
        ZStack {
            AppPageBackground(lightBase: photos.isEmpty ? AppBrand.paper : Color(uiColor: .systemBackground))
            if photos.isEmpty {
                GalleryEmptyState()
            } else {
                GeometryReader { geometry in
                    PhotoGridView(
                        photos: photos,
                        defaultColumns: SquareGridLayout.defaultColumns(forWidth: geometry.size.width,
                            isRegular: sizeClass == .regular, accessibilitySize: dynamicTypeSize.isAccessibilitySize),
                        zoomColumns: $zoomColumns,
                        isSelecting: $isSelecting,
                        selectedPhotos: $selectedPhotos,
                        onOpen: { photo in
                            guard selectedDetail == nil else { return }
                            transitionSource.currentPhotoID = photo.id
                            selectedDetail = PhotoDetailSelection(startPhoto: photo, photos: photos)
                        },
                        isActive: isVisible && selectedDetail == nil,
                        transitionSource: transitionSource
                    )
                    // UIKit adjusts for system bars, but only SwiftUI knows the capsule's inset.
                    .ignoresSafeArea(edges: capsuleTabSelection != nil && !isSelecting ? .top : .all)
                }
                .pageContentWidth(PageLayout.browseWidth)
            }
        }
        .navigationTitle(isSelecting ? Text("\(selectedPhotos.count) selected") : Text("Gallery"))
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .navigationBarTitleDisplayMode(.inline)
        .softScrollEdges()
        // 选择模式隐藏底部 tab 栏，让位给 Download / Delete 操作栏（Photos.app 一致）。
        .mainTabRoot(.photos, isHidden: isSelecting)
        .toolbar {
            // 全选放左上、xmark 放右上——两端分置，不挤在一起。
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelecting {
                    Button(action: toggleSelectAll) {
                        Image(systemName: selectedPhotos.count == photos.count ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .accessibilityLabel("Select All")
                    .accessibilityValue(Text("\(selectedPhotos.count) selected"))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button { exitSelection() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Done selecting")
                } else if !photos.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { isSelecting = true }
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .accessibilityLabel("Select")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                GallerySaveIndicator()
            }
        }
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    // 一键分享选中照片到其他 app：导出全分辨率原图临时文件 → 系统分享面板。
                    // 导出期间显示 spinner 并禁用，防连点。
                    Button(action: shareSelectedPhotos) {
                        if isPreparingShare {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18))
                                .foregroundColor(selectedPhotos.isEmpty ? .gray : .primary)
                        }
                    }
                    .disabled(selectedPhotos.isEmpty || isPreparingShare)
                    .accessibilityLabel("Share")

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
        .task(id: isRevealed, priority: .utility) {
            guard isRevealed else { return }
            await CapturePipeline.shared.retryPending()
            await PhotoLibrarySync.shared.reconcile(container: modelContext.container)
        }
        .background {
            PhotoDetailPresentation(selection: $selectedDetail, source: transitionSource,
                container: modelContext.container)
        }
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

    /// 分享选中照片到其他 app：按时间正序导出全分辨率原图临时文件，再 present 系统分享面板。
    /// 导出可能涉及 iCloud 回源（异步），期间显示 spinner。导出后保留选择模式（用户可能想继续操作）。
    private func shareSelectedPhotos() {
        let ids = selectedPhotos
        guard !ids.isEmpty, !isPreparingShare else { return }
        // 按相册显示顺序（时间倒序）选出，再反成正序——分享出去的多图顺序符合直觉。
        let toShare = photos.filter { ids.contains($0.id) }.reversed().map { $0 }
        isPreparingShare = true
        Task { @MainActor in
            defer { isPreparingShare = false }
            let urls = await PhotoShareExporter.export(toShare)
            guard !urls.isEmpty else { return }
            SharePresenter.present(urls)
            Log.gallery.info("photos_shared count=\(urls.count)")
        }
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
        let pipeline = CapturePipeline.shared
        Task { @MainActor in
            do {
                guard let _ = try await PhotoDeletionService(container: container, pipeline: pipeline)
                    .delete(rowIDs: rowIDs, assetIDs: assetIDs) else { return }
                selectedPhotos.removeAll()
                withAnimation(.easeInOut(duration: 0.25)) { isSelecting = false }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Log.save.info("photos_deleted count=\(rowIDs.count)")
            } catch {
                // 用户取消系统删除确认 / 删除失败：保留索引行，不改 UI。
                Log.save.info("photos_delete_cancelled_or_failed count=\(rowIDs.count) error=\(error.localizedDescription, privacy: .public)")
                let photosError = error as NSError
                if photosError.domain != PHPhotosErrorDomain || photosError.code != PHPhotosError.Code.userCancelled.rawValue {
                    pipeline.lastError = error.localizedDescription
                }
            }
        }
    }
}

/// Queue updates invalidate only this small status view, rather than rebuilding the grid.
private struct GallerySaveIndicator: View {
    @ObservedObject private var pipeline = CapturePipeline.shared

    var body: some View {
        if pipeline.pendingCount > 0 {
            HStack(spacing: 5) {
                ProgressView().tint(.primary).controlSize(.small)
                    .accessibilityHidden(true)
                Text(pipeline.pendingCount, format: .number)
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel("Saving…")
                    .accessibilityValue(Text(pipeline.pendingCount, format: .number))
            }
        }
    }
}
