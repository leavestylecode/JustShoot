import SwiftUI
import UIKit
import Photos

// MARK: - 网格布局选项（左上角菜单切换，@AppStorage 持久化）
enum GalleryDensity: Int, CaseIterable, Identifiable {
    case large = 3       // 3 列，大图
    case standard = 4    // 4 列（默认）
    case small = 5       // 5 列，小图
    var id: Int { rawValue }
    var columns: Int { rawValue }
    var displayName: LocalizedStringKey {
        switch self {
        case .large:    return "Large"
        case .standard: return "Standard"
        case .small:    return "Small"
        }
    }
}

enum GalleryShape: String, CaseIterable, Identifiable {
    case rounded
    case square
    var id: String { rawValue }
    var displayName: LocalizedStringKey { self == .rounded ? "Rounded" : "Square" }
    var cornerRadius: CGFloat { self == .rounded ? 8 : 0 }
}

// MARK: - 相册网格（UICollectionView，UIViewRepresentable 桥接）
//
// 为什么用 UIKit 而不是 SwiftUI LazyVGrid（调研结论，2024-2025 WWDC + Apple 论坛）：
//   1. 滚动流畅度：UICollectionView 的 cell 复用 + DataSourcePrefetching 后台预解码是十几年
//      打磨的成熟方案；LazyVGrid 在数百+ cell 时依赖图要 eager 追踪全部行，滚动掉帧。
//   2. 滚动 vs 拖动多选：苹果原生 shouldBeginMultipleSelectionInteractionAt（两指平移）由系统
//      在手势识别器层面和单指滚动区分开，零冲突；SwiftUI 自定义 DragGesture/LongPress 必然和
//      ScrollView 抢手势（要么误选、要么卡死滚动）。
//
// 与 SwiftUI 外壳的分工：网格滚动/cell/预取/原生多选在这里（UIKit）；选择状态、工具栏、tab 栏
// 隐藏、下载/删除、详情 push 仍在 GalleryView（SwiftUI），通过 @Binding 双向同步。
struct PhotoGridView: UIViewRepresentable {
    let photos: [Photo]
    let columns: Int            // 网格列数（密度）——左上角菜单切换
    let cornerRadius: CGFloat   // cell 圆角（直角 0 / 圆角 8）
    @Binding var isSelecting: Bool
    @Binding var selectedPhotos: Set<UUID>
    let onOpen: (Photo) -> Void

    static let spacing: CGFloat = 6
    static let sectionInsets = UIEdgeInsets(top: 8, left: 14, bottom: 20, right: 14)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = SquareGridLayout()
        layout.columns = CGFloat(columns)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .black
        cv.alwaysBounceVertical = true
        cv.allowsSelection = true
        cv.allowsMultipleSelectionDuringEditing = true
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator
        cv.contentInsetAdjustmentBehavior = .automatic
        cv.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        context.coordinator.cornerRadius = cornerRadius
        context.coordinator.makeDataSource(for: cv)
        context.coordinator.apply(photos: photos, animating: false)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.apply(photos: photos, animating: true)
        // 形状切换：动画更新可见 cell 圆角
        if coord.cornerRadius != cornerRadius {
            coord.cornerRadius = cornerRadius
            coord.applyCornerRadius(cv, radius: cornerRadius)
        }
        // 密度切换：改列数 → 平滑 reflow → 按新尺寸重载可见缩略图
        if let layout = cv.collectionViewLayout as? SquareGridLayout, Int(layout.columns) != columns {
            layout.columns = CGFloat(columns)
            coord.animateColumnChange(cv)
        }
        // 同步编辑模式（isSelecting）→ 刷新可见 cell 的角标 + 选中暗化
        if cv.isEditing != isSelecting {
            cv.isEditing = isSelecting
            coord.refreshEditingVisual(cv)
        }
        // 同步选中集合（Select All / 退出清空等外部变更 → 驱动 cv 选中态）
        coord.syncSelection(cv, to: selectedPhotos)
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var parent: PhotoGridView
        var cornerRadius: CGFloat = 8
        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
        private var photoByID: [UUID: Photo] = [:]
        private var lastIDs: [UUID] = []

        init(_ parent: PhotoGridView) { self.parent = parent }

        func makeDataSource(for cv: UICollectionView) {
            dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: cv) {
                [weak self] cv, indexPath, id in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
                guard let self, let photo = self.photoByID[id] else { return cell }
                cell.configure(photo: photo, editing: cv.isEditing,
                               maxPixel: self.thumbPixel(for: cv), cornerRadius: self.cornerRadius)
                return cell
            }
        }

        func apply(photos: [Photo], animating: Bool) {
            let ids = photos.map { $0.id }
            photoByID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // 选择切换会高频触发 updateUIView——id 列表没变就跳过 snapshot apply，只有真正增删才刷新。
            guard ids != lastIDs else { return }
            lastIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            dataSource.apply(snapshot, animatingDifferences: animating)
        }

        /// 把 cv 的选中态调整到与 binding 一致（外部变更驱动）。didSelect/didDeselect 反向已即时更新
        /// binding，此处对那条路径是 no-op，不会循环。
        func syncSelection(_ cv: UICollectionView, to selected: Set<UUID>) {
            let current = Set((cv.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) })
            for id in current.subtracting(selected) {
                if let ip = dataSource.indexPath(for: id) { cv.deselectItem(at: ip, animated: false) }
            }
            for id in selected.subtracting(current) {
                if let ip = dataSource.indexPath(for: id) { cv.selectItem(at: ip, animated: false, scrollPosition: []) }
            }
            // cv 不会对“通过代码 select/deselect”回调 cell 的 isSelected didSet 之外的刷新，这里兜底刷新可见 cell
            refreshEditingVisual(cv)
        }

        /// 编辑模式切换时刷新所有可见 cell 的 isEditingMode（角标显隐）。
        func refreshEditingVisual(_ cv: UICollectionView) {
            for case let cell as PhotoCell in cv.visibleCells {
                cell.isEditingMode = cv.isEditing
            }
        }

        /// 形状切换：动画更新可见 cell 圆角（新 dequeue 的 cell 由 configure 直接拿）。
        func applyCornerRadius(_ cv: UICollectionView, radius: CGFloat) {
            UIView.animate(withDuration: 0.2) {
                for case let cell as PhotoCell in cv.visibleCells {
                    cell.contentView.layer.cornerRadius = radius
                }
            }
        }

        /// 密度切换：invalidate 触发平滑 reflow，完成后按新尺寸 reconfigure 可见缩略图（放大不糊）。
        func animateColumnChange(_ cv: UICollectionView) {
            cv.performBatchUpdates({
                cv.collectionViewLayout.invalidateLayout()
            }, completion: { [weak self] _ in
                self?.reloadVisibleThumbnails(cv)
            })
        }

        private func reloadVisibleThumbnails(_ cv: UICollectionView) {
            let ids = cv.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !ids.isEmpty else { return }
            var snap = dataSource.snapshot()
            snap.reconfigureItems(ids)
            dataSource.apply(snap, animatingDifferences: false)
        }

        func thumbPixel(for cv: UICollectionView) -> Int {
            let side = (cv.collectionViewLayout as? SquareGridLayout)?.itemSize.width ?? 96
            let scale = cv.traitCollection.displayScale > 0 ? cv.traitCollection.displayScale : 2
            return max(96, Int(side * scale))
        }

        // MARK: Tap / selection
        func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
            if cv.isEditing {
                parent.selectedPhotos.insert(id)
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                cv.deselectItem(at: indexPath, animated: false)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if let photo = photoByID[id] { parent.onOpen(photo) }
            }
        }

        func collectionView(_ cv: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard cv.isEditing, let id = dataSource.itemIdentifier(for: indexPath) else { return }
            parent.selectedPhotos.remove(id)
        }

        // MARK: 原生两指拖动多选（系统自动与单指滚动区分）
        func collectionView(_ cv: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            true
        }

        func collectionView(_ cv: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            // 两指平移起手即进入编辑模式（即便此前不在选择模式）。同步设 cv.isEditing 让手势立即生效，
            // 再把 binding 推回 SwiftUI（驱动工具栏切换 + 隐藏 tab 栏）。
            if !cv.isEditing {
                cv.isEditing = true
                refreshEditingVisual(cv)
            }
            if !parent.isSelecting {
                let binding = parent.$isSelecting
                DispatchQueue.main.async { binding.wrappedValue = true }
            }
        }

        // MARK: Prefetch
        func collectionView(_ cv: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let px = thumbPixel(for: cv)
            // 资产照片批量交给 PHCachingImageManager 预取；遗留内部照片走 ImageLoader 解码预取。
            var assetIDs: [String] = []
            for ip in indexPaths {
                guard let id = dataSource.itemIdentifier(for: ip), let photo = photoByID[id] else { continue }
                if let aid = photo.assetLocalIdentifier {
                    assetIDs.append(aid)
                } else {
                    PhotoCell.prefetch(photo: photo, maxPixel: px)
                }
            }
            if !assetIDs.isEmpty { AssetImageLoader.shared.startCaching(ids: assetIDs, maxPixel: px) }
        }
    }
}

// MARK: - 方形等距网格布局（4 列，自动按宽度算 cell 边长）
final class SquareGridLayout: UICollectionViewFlowLayout {
    var columns: CGFloat = 4

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let cols = columns
        let spacing = PhotoGridView.spacing
        minimumInteritemSpacing = spacing
        minimumLineSpacing = spacing
        sectionInset = PhotoGridView.sectionInsets
        let available = cv.bounds.width - sectionInset.left - sectionInset.right - spacing * (cols - 1)
        let side = max(1, floor(available / cols))
        itemSize = CGSize(width: side, height: side)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.width != newBounds.width
    }
}

// MARK: - 缩略图 cell
final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"

    private let imageView = UIImageView()
    private let dimOverlay = UIView()
    private let badge = UIImageView()
    private var loadToken = UUID()
    private var assetRequestID: PHImageRequestID = PHInvalidImageRequestID

    var isEditingMode = false { didSet { updateSelectionVisual() } }
    override var isSelected: Bool { didSet { updateSelectionVisual() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerCurve = .continuous   // 圆角值由 configure(cornerRadius:) 设置
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        dimOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        dimOverlay.frame = contentView.bounds
        dimOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimOverlay.isHidden = true
        contentView.addSubview(dimOverlay)

        badge.contentMode = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        badge.layer.shadowColor = UIColor.black.cgColor
        badge.layer.shadowOpacity = 0.35
        badge.layer.shadowRadius = 2
        badge.layer.shadowOffset = CGSize(width: 0, height: 1)
        contentView.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        if assetRequestID != PHInvalidImageRequestID {
            AssetImageLoader.shared.cancel(assetRequestID)
            assetRequestID = PHInvalidImageRequestID
        }
        loadToken = UUID()
        imageView.image = nil
        isEditingMode = false
    }

    func configure(photo: Photo, editing: Bool, maxPixel: Int, cornerRadius: CGFloat) {
        contentView.layer.cornerRadius = cornerRadius
        isEditingMode = editing
        loadThumbnail(photo: photo, maxPixel: maxPixel)
    }

    // MARK: 缩略图加载
    private func loadThumbnail(photo: Photo, maxPixel: Int) {
        let id = photo.id

        // 资产路径（真相源在系统相册）：同步缓存命中即零延迟；否则 PHImageManager opportunistic
        // 渐进交付（先糊后清），cell 复用时用 assetRequestID 取消。
        if let aid = photo.assetLocalIdentifier {
            if let img = AssetImageLoader.shared.cachedThumbnail(id: aid, maxPixel: maxPixel) {
                imageView.image = img
                return
            }
            let token = UUID()
            loadToken = token
            assetRequestID = AssetImageLoader.shared.requestThumbnail(id: aid, maxPixel: maxPixel) { [weak self] img in
                guard let self, self.loadToken == token, let img else { return }
                self.imageView.image = img
            }
            return
        }

        // 遗留内部字节路径（迁移完成前）：缓存→磁盘→fault 原图，逐级降级，token 防错位。
        if let img = ImageLoader.shared.cachedThumbnail(for: id, maxPixel: maxPixel)
            ?? ImageLoader.shared.anyCachedThumbnail(for: id) {
            imageView.image = img
            return
        }
        guard let data = photo.imageData else { return }
        let token = UUID()
        loadToken = token
        Task { @MainActor in
            if let img = await ImageLoader.shared.cachedOrDiskThumbnail(photoId: id, maxPixel: maxPixel) {
                if self.loadToken == token { self.imageView.image = img }
                return
            }
            if let img = await ImageLoader.shared.loadThumbnail(imageData: data, photoId: id, maxPixel: maxPixel) {
                if self.loadToken == token { self.imageView.image = img }
            }
        }
    }

    /// 遗留内部照片预取（资产照片由 Coordinator 批量 PHCachingImageManager 预取）。
    static func prefetch(photo: Photo, maxPixel: Int) {
        let id = photo.id
        if ImageLoader.shared.cachedThumbnail(for: id, maxPixel: maxPixel) != nil { return }
        guard let data = photo.imageData else { return }
        Task { @MainActor in
            if await ImageLoader.shared.cachedOrDiskThumbnail(photoId: id, maxPixel: maxPixel) != nil { return }
            _ = await ImageLoader.shared.loadThumbnail(imageData: data, photoId: id, maxPixel: maxPixel)
        }
    }

    // MARK: 选中视觉（Photos.app 一致：仅角标 + 暗化，不画边框/不缩放）
    private func updateSelectionVisual() {
        badge.isHidden = !isEditingMode
        dimOverlay.isHidden = !(isEditingMode && isSelected)
        guard isEditingMode else { return }
        let base = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        if isSelected {
            let palette = base.applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue]))
            badge.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: palette)
        } else {
            badge.image = UIImage(systemName: "circle", withConfiguration: base)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
        }
    }
}
