import SwiftUI
import UIKit

struct PhotoGridItemRevision: Equatable {
    let assetID: String?
    let isLive: Bool

    static func changedIDs(from previous: [UUID: Self], to current: [UUID: Self]) -> [UUID] {
        current.keys.filter { previous[$0] != nil && previous[$0] != current[$0] }
    }
}

struct PhotoGridView: UIViewRepresentable {
    fileprivate static let thumbnailSizes = [96, 160, 256, 320, 384, 512, 768, 1024, 1536, 2048]
    let photos: [Photo]
    var defaultColumns = 4
    @Binding var zoomColumns: Int
    @Binding var isSelecting: Bool
    @Binding var selectedPhotos: Set<UUID>
    let onOpen: (Photo) -> Void
    var isActive = true
    var transitionSource: PhotoGridTransitionSource?

    private var preferredColumns: Int {
        SquareGridLayout.columnRange.contains(zoomColumns) ? zoomColumns : defaultColumns
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = SquareGridLayout(columns: preferredColumns)
        let cv = PhotoGridCollectionView(frame: .zero, collectionViewLayout: layout)
        cv.accessibilityIdentifier = "gallery.grid"
        cv.backgroundColor = .clear
        cv.alwaysBounceVertical = true
        cv.allowsSelection = true
        cv.allowsSelectionDuringEditing = true
        cv.allowsMultipleSelectionDuringEditing = true
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator
        cv.contentInsetAdjustmentBehavior = .automatic
        cv.contentInset.bottom = SquareGridLayout.bottomPadding
        if #available(iOS 26.0, *) {
            cv.topEdgeEffect.style = .soft
            cv.bottomEdgeEffect.style = .soft
        }
        transitionSource?.collectionView = cv
        cv.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        context.coordinator.installZoom(in: cv, layout: layout)
        context.coordinator.makeDataSource(for: cv)
        context.coordinator.apply(photos: photos, animating: false)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        transitionSource?.collectionView = cv
        coord.apply(photos: photos, animating: true)
        coord.setActive(isActive, in: cv)
        coord.syncPreferredColumns(preferredColumns)
        // 同步编辑模式（isSelecting）→ 刷新可见 cell 的角标 + 选中暗化
        if cv.isEditing != isSelecting {
            coord.zoom.completeImmediately()
            cv.isEditing = isSelecting
            coord.refreshEditingVisual(cv)
        }
        // 同步选中集合（Select All / 退出清空等外部变更 → 驱动 cv 选中态）
        coord.syncSelection(cv, to: selectedPhotos)
    }

    static func dismantleUIView(_ cv: UICollectionView, coordinator: Coordinator) {
        coordinator.finishPendingUpdates()
        coordinator.zoom.uninstall()
        coordinator.cancelPrefetches()
        for case let cell as PhotoCell in cv.visibleCells { cell.suspendLoading() }
        cv.prefetchDataSource = nil
        cv.delegate = nil
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var parent: PhotoGridView
        let zoom = PhotoGridZoom()
        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
        private var photoByID: [UUID: Photo] = [:]
        private var lastIDs: [UUID] = []
        private var lastRevisions: [UUID: PhotoGridItemRevision] = [:]
        private var prefetches: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
        private var isActive: Bool
        private var defersSharpThumbnails = false
        private var pendingColumns: Int?
        private var idleUpdate: Task<Void, Never>?

        init(_ parent: PhotoGridView) {
            self.parent = parent
            isActive = parent.isActive
        }

        func installZoom(in cv: PhotoGridCollectionView, layout: SquareGridLayout) {
            zoom.install(in: cv, layout: layout)
            zoom.setActive(isActive)
            zoom.onBegin = { [weak self] in
                self?.deferSharpThumbnails()
                self?.cancelPrefetches()
            }
            zoom.onEnd = { [weak self, weak cv] in
                guard let self, let cv else { return }
                refreshThumbnailSizes(in: cv)
                scheduleIdleUpdate(in: cv)
            }
            zoom.onChooseColumns = { [weak self, weak cv] columns in
                guard let self, let cv else { return }
                pendingColumns = columns
                scheduleIdleUpdate(in: cv)
            }
            zoom.photoAt = { [weak self, weak cv] index in
                guard let self, let cv,
                      let id = dataSource.itemIdentifier(for: IndexPath(item: index, section: 0)),
                      let photo = photoByID[id] else { return nil }
                return PhotoGridZoomOverlay.PhotoContent(photo: photo,
                    isSelected: cv.isEditing && parent.selectedPhotos.contains(id))
            }
            zoom.thumbnailPixels = { [weak self, weak cv] in
                guard let self, let cv else { return 256 }
                return self.thumbnailPixels(for: cv)
            }
            cv.onViewportWidthChange = { [weak self, weak cv] in
                guard let self, let cv else { return }
                if zoom.isZooming { zoom.completeImmediately() }
                else { refreshThumbnailSizes(in: cv) }
            }
        }

        func makeDataSource(for cv: UICollectionView) {
            dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: cv) {
                [weak self] cv, indexPath, id in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
                guard let self, let photo = self.photoByID[id] else { return cell }
                cell.configure(photo: photo, editing: cv.isEditing,
                               maxPixel: self.thumbnailPixels(for: cv),
                               isActive: self.isActive && !self.zoom.isPresentingOverlay,
                               retainingImage: self.parent.transitionSource?.currentPhotoID != nil)
                cell.onZoom = { [weak self] cell, delta in
                    self?.zoom.adjust(in: cell, by: delta) ?? false
                }
                return cell
            }
        }

        func apply(photos: [Photo], animating: Bool) {
            let current = photos.filter { !$0.isDeleted }
            let ids = current.map { $0.id }
            photoByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let revisions = photoByID.mapValues { PhotoGridItemRevision(assetID: $0.assetLocalIdentifier, isLive: $0.isLivePhoto) }
            let changedIDs = PhotoGridItemRevision.changedIDs(from: lastRevisions, to: revisions)
            // A retry/migration can change content without changing identity. Selection-only
            // updates still avoid a snapshot, but a newly saved asset must refresh its cell.
            guard ids != lastIDs || !changedIDs.isEmpty else { return }
            cancelPrefetches()
            lastIDs = ids
            lastRevisions = revisions
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            let existingIDs = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(changedIDs.filter { existingIDs.contains($0) })
            let wasZooming = zoom.isZooming
            zoom.completeImmediately()
            dataSource.apply(snapshot, animatingDifferences: animating && !wasZooming)
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

        func syncPreferredColumns(_ columns: Int) {
            if pendingColumns == nil { zoom.syncPreferredColumns(columns) }
        }

        private func deferSharpThumbnails() {
            idleUpdate?.cancel()
            defersSharpThumbnails = true
        }

        private func scheduleIdleUpdate(in cv: UICollectionView) {
            guard isActive, defersSharpThumbnails || pendingColumns != nil else { return }
            idleUpdate?.cancel()
            idleUpdate = Task { @MainActor [weak self, weak cv] in
                // Avoid resizing visible images and invalidating SwiftUI while the next flick starts.
                guard (try? await Task.sleep(for: .milliseconds(180))) != nil,
                      let self, let cv, !zoom.isZooming, !cv.isDragging, !cv.isDecelerating else { return }
                idleUpdate = nil
                defersSharpThumbnails = false
                cancelPrefetches()
                refreshThumbnailSizes(in: cv)
                if let columns = pendingColumns {
                    pendingColumns = nil
                    if parent.zoomColumns != columns { parent.zoomColumns = columns }
                }
            }
        }

        func finishPendingUpdates() {
            idleUpdate?.cancel()
            idleUpdate = nil
            defersSharpThumbnails = false
            guard let columns = pendingColumns else { return }
            let density = parent.$zoomColumns
            // SwiftUI may call this during a representable update or dismantle.
            DispatchQueue.main.async { [weak self] in
                if let self {
                    guard pendingColumns == columns else { return }
                    pendingColumns = nil
                }
                if density.wrappedValue != columns { density.wrappedValue = columns }
            }
        }

        private func refreshThumbnailSizes(in cv: UICollectionView) {
            guard isActive, !zoom.isZooming else { return }
            let pixels = thumbnailPixels(for: cv)
            for case let cell as PhotoCell in cv.visibleCells {
                cell.setThumbnailSize(pixels)
                cell.resumeLoading()
            }
        }

        private func thumbnailPixels(for cv: UICollectionView) -> Int {
            let side = (cv.collectionViewLayout as? SquareGridLayout)?.tileSide ?? 96
            let scale = cv.traitCollection.displayScale > 0 ? cv.traitCollection.displayScale : 2
            let pixels = Int(ceil(side * scale))
            // Keep cache keys stable across minor size and orientation changes.
            let bucket = PhotoGridView.thumbnailSizes.first { $0 >= pixels } ?? 2048
            return defersSharpThumbnails ? min(bucket, 320) : bucket
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            deferSharpThumbnails()
            if scrollView.panGestureRecognizer.numberOfTouches == 1 { zoom.completeImmediately() }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate, let cv = scrollView as? UICollectionView { scheduleIdleUpdate(in: cv) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if let cv = scrollView as? UICollectionView { scheduleIdleUpdate(in: cv) }
        }

        func setActive(_ active: Bool, in cv: UICollectionView) {
            guard isActive != active else { return }
            isActive = active
            zoom.setActive(active)
            if !active {
                cancelPrefetches()
                finishPendingUpdates()
            }
            for case let cell as PhotoCell in cv.visibleCells {
                if active {
                    cell.setThumbnailSize(thumbnailPixels(for: cv))
                    cell.resumeLoading()
                } else {
                    cell.suspendLoading(retainingImage: parent.transitionSource?.currentPhotoID != nil)
                }
            }
        }

        func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            guard let cell = cell as? PhotoCell else { return }
            cell.setZoomCovered(zoom.isPresentingOverlay)
            if isActive && !zoom.isPresentingOverlay {
                cell.setThumbnailSize(thumbnailPixels(for: cv))
                cell.resumeLoading()
            } else {
                cell.suspendLoading(retainingImage: zoom.isPresentingOverlay || parent.transitionSource?.currentPhotoID != nil)
            }
        }

        func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            (cell as? PhotoCell)?.suspendLoading()
        }

        // MARK: Tap / selection
        func collectionView(_ cv: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            !zoom.isZooming
        }

        func collectionView(_ cv: UICollectionView, shouldDeselectItemAt indexPath: IndexPath) -> Bool {
            !zoom.isZooming
        }

        func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard !zoom.isZooming, let id = dataSource.itemIdentifier(for: indexPath) else { return }
            if cv.isEditing {
                parent.selectedPhotos.insert(id)
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                cv.deselectItem(at: indexPath, animated: false)
                if zoom.handleBrowseTap(at: indexPath) { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if let photo = photoByID[id] { parent.onOpen(photo) }
            }
        }

        func collectionView(_ cv: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard cv.isEditing, let id = dataSource.itemIdentifier(for: indexPath) else { return }
            parent.selectedPhotos.remove(id)
        }

        // MARK: 两指拖动多选——已禁用
        // 只允许通过工具栏「选择」按钮进入编辑模式；返回 false 关掉系统原生的两指平移多选，
        // 避免浏览时误触。（didBeginMultipleSelectionInteractionAt 随之永不触发，故删除。）
        func collectionView(_ cv: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            false
        }

        // MARK: Prefetch
        func collectionView(_ cv: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard isActive, !zoom.isZooming else { return }
            let px = min(thumbnailPixels(for: cv), 320)
            // Bound speculative requests. Visible cells keep their own independent demand.
            for ip in indexPaths.prefix(max(0, 8 - prefetches.count)) {
                guard let id = dataSource.itemIdentifier(for: ip), let photo = photoByID[id] else { continue }
                guard prefetches[id] == nil else { continue }
                let token = UUID()
                let task = Task(priority: .utility) { @MainActor [weak self] in
                    _ = await PhotoImage.thumbnail(for: photo, maxPixel: px)
                    guard self?.prefetches[id]?.token == token else { return }
                    self?.prefetches[id] = nil
                }
                prefetches[id] = (token, task)
            }
        }

        func collectionView(_ cv: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for ip in indexPaths {
                guard let id = dataSource.itemIdentifier(for: ip) else { continue }
                prefetches.removeValue(forKey: id)?.task.cancel()
            }
        }

        func cancelPrefetches() {
            for request in prefetches.values { request.task.cancel() }
            prefetches.removeAll()
        }
    }
}

final class PhotoGridCollectionView: UICollectionView {
    var onViewportWidthChange: (() -> Void)?
    private var viewportWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - adjustedContentInset.left - adjustedContentInset.right
        guard viewportWidth != width else { return }
        viewportWidth = width
        onViewportWidthChange?()
    }

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        let width = bounds.width - adjustedContentInset.left - adjustedContentInset.right
        if viewportWidth != width { collectionViewLayout.invalidateLayout() }
    }
}

// MARK: - 缩略图 cell
final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"
    private let thumbnail = PhotoGridThumbnailView()
    var transitionImage: UIImage? { thumbnail.image }
    private var loadToken = UUID()
    private var loadTask: Task<Void, Never>?
    private var configuredPhoto: Photo?
    private var maxPixel = 96
    private var isSuspended = true

    var onZoom: ((PhotoCell, Int) -> Bool)?
    var isEditingMode = false {
        didSet {
            if oldValue != isEditingMode { updateSelectionVisual() }
        }
    }
    override var isSelected: Bool {
        didSet {
            if oldValue != isSelected { updateSelectionVisual() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerCurve = .continuous
        thumbnail.frame = contentView.bounds
        thumbnail.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(thumbnail)
    }

    private func configureAccessibility() {
        guard accessibilityCustomActions == nil else { return }
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Zoom In")) { [weak self] _ in
                guard let self else { return false }
                return onZoom?(self, -1) ?? false
            },
            UIAccessibilityCustomAction(name: String(localized: "Zoom Out")) { [weak self] _ in
                guard let self else { return false }
                return onZoom?(self, 1) ?? false
            }
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.cornerRadius = PhotoGridThumbnailView.cornerRadius(for: contentView.bounds.width)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoading()
        configuredPhoto = nil
        onZoom = nil
        setZoomCovered(false)
        isSuspended = true
        thumbnail.image = nil
        isEditingMode = false
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadToken = UUID()
    }

    func configure(photo: Photo, editing: Bool, maxPixel: Int, isActive: Bool = true,
                   retainingImage: Bool = false) {
        if configuredPhoto?.id != photo.id { thumbnail.image = nil }
        configuredPhoto = photo
        self.maxPixel = maxPixel
        configureAccessibility()
        accessibilityIdentifier = "photo.\(photo.id.uuidString)"
        accessibilityLabel = photo.timestamp.formatted(date: .abbreviated, time: .shortened)
        accessibilityValue = photo.isLivePhoto ? String(localized: "Live Photo") : nil
        isEditingMode = editing
        updateSelectionVisual()
        if isActive {
            isSuspended = false
            loadThumbnail(photo: photo, maxPixel: maxPixel)
        } else {
            suspendLoading(retainingImage: retainingImage)
        }
    }

    func seedZoomThumbnail(_ image: UIImage?) {
        if thumbnail.image == nil { thumbnail.image = image }
    }

    func seedCachedTransitionImage() {
        guard thumbnail.image == nil, let photo = configuredPhoto, !photo.isDeleted else { return }
        if let assetID = photo.assetLocalIdentifier {
            thumbnail.image = AssetImageLoader.shared.cachedThumbnail(id: assetID, maxPixel: maxPixel)
                ?? AssetImageLoader.shared.cachedThumbnail(id: assetID, maxPixel: PhotoDetailView.placeholderMaxPixel)
        } else {
            thumbnail.image = ImageLoader.shared.anyCachedThumbnail(for: photo.id)
        }
    }

    func setZoomCovered(_ covered: Bool) {
        contentView.isHidden = covered
    }

    func setThumbnailSize(_ maxPixel: Int) {
        guard self.maxPixel != maxPixel else { return }
        let enlarging = maxPixel > self.maxPixel
        self.maxPixel = maxPixel
        if !isSuspended, let photo = configuredPhoto, enlarging || thumbnail.image == nil {
            loadThumbnail(photo: photo, maxPixel: maxPixel)
        }
    }

    func suspendLoading(retainingImage: Bool = false) {
        isSuspended = true
        cancelLoading()
        if !retainingImage { thumbnail.image = nil }
    }

    func resumeLoading() {
        guard isSuspended, let photo = configuredPhoto, !photo.isDeleted else { return }
        isSuspended = false
        loadThumbnail(photo: photo, maxPixel: maxPixel)
    }

    // MARK: 缩略图加载
    private func loadThumbnail(photo: Photo, maxPixel: Int) {
        // reconfigureItems does not call prepareForReuse. Invalidate even on cache hits,
        // otherwise a callback for the previous configuration can overwrite the new image.
        cancelLoading()
        let token = loadToken
        guard !photo.isDeleted else { thumbnail.image = nil; return }
        let id = photo.id

        if let aid = photo.assetLocalIdentifier {
            let loader = AssetImageLoader.shared
            for size in PhotoGridView.thumbnailSizes where size >= maxPixel {
                if let image = loader.cachedThumbnail(id: aid, maxPixel: size) {
                    thumbnail.image = image
                    return
                }
            }
            if thumbnail.image == nil {
                for size in PhotoGridView.thumbnailSizes.reversed() where size < maxPixel {
                    if let image = loader.cachedThumbnail(id: aid, maxPixel: size) {
                        thumbnail.image = image
                        break
                    }
                }
            }
            loadTask = Task { @MainActor [weak self] in
                let image = await loader.thumbnail(id: aid, maxPixel: maxPixel, onDegraded: { [weak self] preview in
                    Task { @MainActor in
                        guard let self, self.loadToken == token, self.thumbnail.image == nil else { return }
                        self.thumbnail.image = preview
                    }
                })
                guard !Task.isCancelled, let self, self.loadToken == token, let image else { return }
                self.thumbnail.image = image
            }
            return
        }

        // 遗留内部字节路径（迁移完成前）：缓存→磁盘→fault 原图，逐级降级，token 防错位。
        if let img = ImageLoader.shared.cachedThumbnail(for: id, maxPixel: maxPixel) {
            thumbnail.image = img
            return
        }
        if thumbnail.image == nil {
            thumbnail.image = ImageLoader.shared.anyCachedThumbnail(for: id)
        }
        loadTask = Task { @MainActor [weak self] in
            let img = await PhotoImage.thumbnail(for: photo, maxPixel: maxPixel)
            guard !Task.isCancelled, let self, self.loadToken == token, let img else { return }
            self.thumbnail.image = img
        }
    }

    // MARK: 选中视觉（Photos.app 一致：仅角标 + 暗化，不画边框/不缩放）
    private func updateSelectionVisual() {
        if isSelected { accessibilityTraits.insert(.selected) }
        else { accessibilityTraits.remove(.selected) }
        thumbnail.setSelection(editing: isEditingMode, selected: isSelected)
    }
}

/// Shared by the resting cells and the zoom preview.
final class PhotoGridThumbnailView: UIView {
    private static let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    private static let unselectedSymbol = UIImage(systemName: "circle", withConfiguration: configuration)?
        .withTintColor(.white, renderingMode: .alwaysOriginal)
    private static let selectedSymbol = UIImage(systemName: "checkmark.circle.fill",
        withConfiguration: configuration.applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])))

    private let imageView = UIImageView()
    private let dimOverlay = UIView()
    private let badge = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    static func cornerRadius(for side: CGFloat) -> CGFloat {
        min(SquareGridLayout.cornerRadius, side * 0.12)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemFill

        imageView.contentMode = .scaleAspectFill
        addSubview(imageView)

        dimOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        dimOverlay.isHidden = true
        addSubview(dimOverlay)

        badge.contentMode = .scaleAspectFit
        badge.isHidden = true
        badge.layer.shadowColor = UIColor.black.cgColor
        badge.layer.shadowOpacity = 0.35
        badge.layer.shadowRadius = 2
        badge.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = bounds.width
        imageView.frame = bounds
        layer.cornerRadius = Self.cornerRadius(for: side)
        guard !badge.isHidden else { return }
        dimOverlay.frame = bounds
        let size = badge.image?.size ?? .zero
        let scale = min(1, side / 52)
        let width = size.width * scale
        let height = size.height * scale
        let padding: CGFloat = 5
        let x = effectiveUserInterfaceLayoutDirection == .rightToLeft ? padding : bounds.width - width - padding
        badge.frame = CGRect(x: x, y: padding, width: width, height: height)
    }

    func setSelection(editing: Bool, selected: Bool) {
        badge.isHidden = !editing
        dimOverlay.isHidden = !(editing && selected)
        if editing {
            badge.image = selected ? Self.selectedSymbol : Self.unselectedSymbol
            setNeedsLayout()
        }
    }
}
