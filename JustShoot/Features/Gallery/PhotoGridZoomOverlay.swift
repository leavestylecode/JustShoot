import UIKit

/// Columns grow from the fixed leading margin while rows track the focal
/// photo vertically. Adjacent densities reassign rows on the same lattice.
struct PhotoGridZoomFrame {
    private let leadingX: CGFloat
    private let focalTop: CGFloat
    private let side: CGFloat
    private let pitch: CGFloat
    private let focalItem: Int
    private let sparse: PhotoGridGeometry
    private let dense: PhotoGridGeometry
    private let mix: CGFloat

    init(grid: PhotoGridGeometry, side: CGFloat, anchor: SquareGridLayout.Anchor, leadingSlots: [Int: Int],
         leadingX: CGFloat) {
        self.leadingX = leadingX
        self.side = side
        let range = SquareGridLayout.columnRange
        let available = grid.width - 2 * PhotoGridGeometry.margin + PhotoGridGeometry.spacing
        pitch = side + PhotoGridGeometry.spacing
        let density = min(CGFloat(range.upperBound), max(CGFloat(range.lowerBound), available / pitch))
        let sparseColumns = Int(floor(density + 0.00001))
        let denseColumns = Int(ceil(density - 0.00001))
        sparse = PhotoGridGeometry(width: grid.width, columns: sparseColumns, count: grid.count,
            leadingSlots: leadingSlots[sparseColumns, default: 0])
        dense = PhotoGridGeometry(width: grid.width, columns: denseColumns, count: grid.count,
            leadingSlots: leadingSlots[denseColumns, default: 0])
        mix = sparseColumns == denseColumns ? 0 : (sparse.side - side) / (sparse.side - dense.side)
        focalItem = anchor.indexPath.item
        focalTop = anchor.viewportPoint.y - anchor.tilePoint.y * side
    }

    var focalSlot: PhotoGridGeometry.Slot {
        let column = geometry(forRow: 0).slot(for: focalItem).column
        return .init(row: 0, column: column)
    }

    func frame(at slot: PhotoGridGeometry.Slot) -> CGRect {
        CGRect(x: leadingX + CGFloat(slot.column) * pitch, y: focalTop + CGFloat(slot.row) * pitch,
               width: side, height: side)
    }

    func items(in viewport: CGRect) -> [PhotoGridGeometry.Slot: Int] {
        guard !viewport.isEmpty else { return [:] }
        let rows = Int(floor((viewport.minY - focalTop) / pitch))..<Int(ceil((viewport.maxY - focalTop) / pitch))
        let columnStart = max(0, Int(floor((viewport.minX - leadingX) / pitch)))
        let columnEnd = max(columnStart, Int(ceil((viewport.maxX - leadingX) / pitch)))
        let focus = focalSlot
        var items: [PhotoGridGeometry.Slot: Int] = [:]
        for row in rows {
            let geometry = geometry(forRow: row)
            let anchor = geometry.slot(for: focalItem)
            let absoluteRow = anchor.row + row
            guard absoluteRow >= 0 else { continue }
            // A partial column can enter or leave through the trailing edge as tiles resize.
            for column in columnStart..<columnEnd {
                let slot = PhotoGridGeometry.Slot(row: row, column: column)
                let item = geometry.item(at: .init(row: absoluteRow, column: column))
                guard (0..<geometry.count).contains(item), item != focalItem || slot == focus,
                      frame(at: slot).intersects(viewport) else { continue }
                items[slot] = item
            }
        }
        return items
    }

    private func geometry(forRow row: Int) -> PhotoGridGeometry {
        let threshold = 0.38 + min(CGFloat(abs(row)) * 0.04, 0.24)
        return mix >= threshold ? dense : sparse
    }
}

final class PhotoGridZoomOverlay: UIView {
    struct PhotoContent {
        let photo: Photo
        let isSelected: Bool
    }

    private struct Tile {
        let item: Int
        let view: PhotoGridThumbnailView
    }

    private let grid: PhotoGridGeometry
    private let isEditing: Bool
    private let source: (Int) -> PhotoContent?
    private let basePixels: Int
    private let previewPixels: Int
    private let baseImages: [Int: UIImage]
    private let canvas = UIView()
    private var tiles: [PhotoGridGeometry.Slot: Tile] = [:]
    private var spareTiles: [PhotoGridThumbnailView] = []
    private var contents: [Int: PhotoContent] = [:]
    private var images: [Int: UIImage] = [:]
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var attempted: Set<Int> = []
    private var visible: Set<Int> = []
    private var focalItem: Int?
    private static let maxRequests = 8

    init(frame: CGRect, grid: PhotoGridGeometry, editing: Bool, leftInset: CGFloat, basePixels: Int,
         baseImages: [Int: UIImage], source: @escaping (Int) -> PhotoContent?) {
        self.grid = grid
        isEditing = editing
        self.basePixels = basePixels
        previewPixels = min(basePixels, 320)
        self.baseImages = baseImages
        self.source = source
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.zPosition = 100

        let margin = PhotoGridGeometry.margin
        canvas.frame = CGRect(x: leftInset + margin, y: 0,
                              width: max(0, grid.width - 2 * margin), height: bounds.height)
        // Match the overlay's coordinates while clipping to the resting grid's margins.
        canvas.bounds = canvas.frame
        canvas.clipsToBounds = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(side: CGFloat, anchor: SquareGridLayout.Anchor, leadingSlots: [Int: Int]) {
        let presentation = PhotoGridZoomFrame(grid: grid, side: side, anchor: anchor,
            leadingSlots: leadingSlots, leadingX: canvas.bounds.minX)
        let focus = anchor.indexPath.item
        focalItem = focus
        let sourceAnchor = grid.slot(for: focus)
        let items = presentation.items(in: canvas.bounds.insetBy(dx: 0, dy: -24))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in tiles.keys.filter({ items[$0] == nil }) {
            guard let tile = tiles.removeValue(forKey: slot) else { continue }
            tile.view.removeFromSuperview()
            tile.view.image = nil
            if spareTiles.count < 64 { spareTiles.append(tile.view) }
        }

        for (slot, item) in items {
            let existing = tiles[slot]
            let view = existing?.view ?? spareTiles.popLast() ?? PhotoGridThumbnailView()
            view.frame = presentation.frame(at: slot)
            guard existing?.item != item else { continue }

            let startSlot = PhotoGridGeometry.Slot(row: sourceAnchor.row + slot.row, column: slot.column)
            let fallback = view.image ?? baseImages[grid.item(at: startSlot)]
            configure(view, item: item, fallback: fallback)
            if existing == nil { canvas.addSubview(view) }
            tiles[slot] = Tile(item: item, view: view)
        }
        CATransaction.commit()

        let visibleItems = Set(items.values)
        guard visibleItems != visible else { return }
        visible = visibleItems
        for old in inFlight.keys.filter({ !visible.contains($0) }) {
            inFlight.removeValue(forKey: old)?.cancel()
        }
        images = images.filter { visible.contains($0.key) }
        contents = contents.filter { visible.contains($0.key) }
        attempted.formIntersection(visible)
        requestThumbnails()
    }

    func thumbnail(at item: Int) -> UIImage? { baseImages[item] ?? images[item] }

    func cancelRequests() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private func configure(_ view: PhotoGridThumbnailView, item: Int, fallback: UIImage?) {
        let content = contents[item] ?? source(item)
        contents[item] = content
        if thumbnail(at: item) == nil, let photo = content?.photo {
            if let asset = photo.assetLocalIdentifier {
                let loader = AssetImageLoader.shared
                images[item] = loader.cachedThumbnail(id: asset, maxPixel: basePixels)
                    ?? loader.cachedThumbnail(id: asset, maxPixel: previewPixels)
            } else {
                let loader = ImageLoader.shared
                images[item] = loader.cachedThumbnail(for: photo.id, maxPixel: basePixels)
                    ?? loader.cachedThumbnail(for: photo.id, maxPixel: previewPixels)
                    ?? loader.anyCachedThumbnail(for: photo.id)
            }
        }
        // An already-painted tile can stay visible while its new thumbnail loads.
        // Only the actual item thumbnail is used when handing back to the grid.
        view.image = thumbnail(at: item) ?? fallback
        view.setSelection(editing: isEditing, selected: content?.isSelected ?? false)
    }

    private func requestThumbnails() {
        guard let focalItem, inFlight.count < Self.maxRequests else { return }
        let missing = visible.filter { thumbnail(at: $0) == nil && !attempted.contains($0) && contents[$0] != nil }
        for item in missing.sorted(by: { abs($0 - focalItem) < abs($1 - focalItem) }).prefix(Self.maxRequests - inFlight.count) {
            guard let photo = contents[item]?.photo else { continue }
            attempted.insert(item)
            inFlight[item] = Task { @MainActor [weak self, previewPixels] in
                let image = await PhotoImage.thumbnail(for: photo, maxPixel: previewPixels)
                guard !Task.isCancelled, let self else { return }
                inFlight[item] = nil
                if let image {
                    images[item] = image
                    for tile in tiles.values where tile.item == item {
                        tile.view.image = image
                    }
                }
                requestThumbnails()
            }
        }
    }
}
