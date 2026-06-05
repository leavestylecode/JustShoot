import SwiftUI
import UIKit

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
    @Binding var isSelecting: Bool
    @Binding var selectedPhotos: Set<UUID>
    let onOpen: (Photo) -> Void

    // 布局常量（与旧 SwiftUI 网格一致）
    static let columns: CGFloat = 4
    static let spacing: CGFloat = 6
    static let sectionInsets = UIEdgeInsets(top: 8, left: 14, bottom: 20, right: 14)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = SquareGridLayout()
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .black
        cv.alwaysBounceVertical = true
        cv.allowsSelection = true
        cv.allowsMultipleSelectionDuringEditing = true
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator
        cv.contentInsetAdjustmentBehavior = .automatic
        cv.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        context.coordinator.makeDataSource(for: cv)
        context.coordinator.apply(photos: photos, animating: false)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(photos: photos, animating: true)
        // 同步编辑模式（isSelecting）→ 刷新可见 cell 的角标 + 选中暗化
        if cv.isEditing != isSelecting {
            cv.isEditing = isSelecting
            context.coordinator.refreshEditingVisual(cv)
        }
        // 同步选中集合（Select All / 退出清空等外部变更 → 驱动 cv 选中态）
        context.coordinator.syncSelection(cv, to: selectedPhotos)
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var parent: PhotoGridView
        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
        private var photoByID: [UUID: Photo] = [:]
        private var lastIDs: [UUID] = []

        init(_ parent: PhotoGridView) { self.parent = parent }

        func makeDataSource(for cv: UICollectionView) {
            dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: cv) {
                [weak self] cv, indexPath, id in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
                guard let self, let photo = self.photoByID[id] else { return cell }
                cell.configure(photo: photo, editing: cv.isEditing, maxPixel: self.thumbPixel(for: cv))
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
            for ip in indexPaths {
                guard let id = dataSource.itemIdentifier(for: ip), let photo = photoByID[id] else { continue }
                PhotoCell.prefetch(photo: photo, maxPixel: px)
            }
        }
    }
}

// MARK: - 方形等距网格布局（4 列，自动按宽度算 cell 边长）
final class SquareGridLayout: UICollectionViewFlowLayout {
    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let cols = PhotoGridView.columns
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

    var isEditingMode = false { didSet { updateSelectionVisual() } }
    override var isSelected: Bool { didSet { updateSelectionVisual() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
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
        loadToken = UUID()
        imageView.image = nil
        isEditingMode = false
    }

    func configure(photo: Photo, editing: Bool, maxPixel: Int) {
        isEditingMode = editing
        loadThumbnail(photo: photo, maxPixel: maxPixel)
    }

    // MARK: 缩略图加载（缓存→磁盘→fault 原图，逐级降级，token 防错位）
    private func loadThumbnail(photo: Photo, maxPixel: Int) {
        let id = photo.id
        // 1. 同步 NSCache 命中 → 立即显示，零延迟、零 blob fault
        if let img = ImageLoader.shared.cachedThumbnail(for: id, maxPixel: maxPixel)
            ?? ImageLoader.shared.anyCachedThumbnail(for: id) {
            imageView.image = img
            return
        }
        let token = UUID()
        loadToken = token
        Task { @MainActor in
            // 2. 磁盘缩略图（按 id），不 fault 原图 blob
            if let img = await ImageLoader.shared.cachedOrDiskThumbnail(photoId: id, maxPixel: maxPixel) {
                if self.loadToken == token { self.imageView.image = img }
                return
            }
            // 3. 兜底：fault 原图 + 离主线程解码
            let data = photo.imageData
            if let img = await ImageLoader.shared.loadThumbnail(imageData: data, photoId: id, maxPixel: maxPixel) {
                if self.loadToken == token { self.imageView.image = img }
            }
        }
    }

    /// 预取（prefetchItemsAt）：缓存/磁盘命中即跳过，未命中才 fault + 解码——提前到 idle 时段做，
    /// 滚到屏上时 cell 直接命中缓存。ImageLoader 的 in-flight dedup 防止预取与显示重复解码。
    static func prefetch(photo: Photo, maxPixel: Int) {
        let id = photo.id
        if ImageLoader.shared.cachedThumbnail(for: id, maxPixel: maxPixel) != nil { return }
        Task { @MainActor in
            if await ImageLoader.shared.cachedOrDiskThumbnail(photoId: id, maxPixel: maxPixel) != nil { return }
            let data = photo.imageData
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
