import UIKit

final class SquareGridLayout: UICollectionViewLayout {
    nonisolated static let columnRange = 1...9
    static let bottomPadding: CGFloat = 20
    static let cornerRadius: CGFloat = 8

    static func defaultColumns(forWidth width: CGFloat, isRegular: Bool, accessibilitySize: Bool) -> Int {
        if accessibilitySize { return 2 }
        if !isRegular { return 4 }
        return PageLayout.gridColumns(width: min(width, PageLayout.browseWidth) - PhotoGridGeometry.margin * 2,
            minimum: 144, spacing: PhotoGridGeometry.spacing, maximum: columnRange.upperBound)
    }

    struct Anchor {
        let indexPath: IndexPath
        let tilePoint: CGPoint
        var viewportPoint: CGPoint

        func point(in frame: CGRect) -> CGPoint {
            CGPoint(x: frame.minX + tilePoint.x * frame.width, y: frame.minY + tilePoint.y * frame.height)
        }
    }

    private(set) var columns: Int
    private var leadingSlots = 0
    private(set) var geometry = PhotoGridGeometry(width: 0, columns: 4, count: 0)
    var tileSide: CGFloat { geometry.side }

    init(columns: Int = 4) {
        self.columns = columns.clamped(to: Self.columnRange)
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepare() {
        super.prepare()
        geometry = geometry(for: columns)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: geometry.width, height: geometry.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.width != newBounds.width
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        geometry.items(intersecting: rect).compactMap { item in
            let attributes = attributes(for: IndexPath(item: item, section: 0))
            return attributes.frame.intersects(rect) ? attributes : nil
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item < geometry.count else { return nil }
        return attributes(for: indexPath)
    }

    func anchor(at viewportPoint: CGPoint) -> Anchor? {
        guard let cv = collectionView else { return nil }
        let point = CGPoint(x: viewportPoint.x + cv.bounds.minX, y: viewportPoint.y + cv.bounds.minY)
        let item = cv.indexPathForItem(at: point).flatMap { layoutAttributesForItem(at: $0) }
            ?? layoutAttributesForElements(in: cv.bounds)?.min { first, second in
                distance(from: point, to: first.frame) < distance(from: point, to: second.frame)
            }
        guard let item else { return nil }
        var anchor = Anchor(indexPath: item.indexPath, tilePoint: CGPoint(
            x: ((point.x - item.frame.minX) / item.frame.width).clamped(to: 0...1),
            y: ((point.y - item.frame.minY) / item.frame.height).clamped(to: 0...1)
        ), viewportPoint: .zero)
        let focalPoint = anchor.point(in: item.frame)
        anchor.viewportPoint = CGPoint(x: focalPoint.x - cv.bounds.minX, y: focalPoint.y - cv.bounds.minY)
        return anchor
    }

    func zoomLeadingSlots(for anchor: Anchor) -> [Int: Int] {
        guard let cv = collectionView else { return [:] }
        let top = -cv.adjustedContentInset.top
        // Keep the existing grid still at gesture start. At other densities, put
        // the focal photo in the column nearest the fingers, as in Photo Grid Lab.
        var slots = [columns: geometry.leadingSlots]
        guard cv.contentOffset.y > top + 1 else { return slots }
        let focalX = anchor.viewportPoint.x + cv.bounds.minX
        let item = anchor.indexPath.item
        for columns in Self.columnRange where slots[columns] == nil {
            let next = geometry(for: columns)
            guard next.height + cv.adjustedContentInset.bottom > top + cv.bounds.height else { continue }
            let x = focalX - PhotoGridGeometry.margin - anchor.tilePoint.x * next.side
            let column = Int((x / next.pitch).rounded()).clamped(to: 0...(columns - 1))
            let leading = (column - item % columns + columns) % columns
            let aligned = geometry(for: columns, leadingSlots: leading)
            if offset(for: anchor, in: aligned, cv: cv) > top { slots[columns] = leading }
        }
        return slots
    }

    func alignedViewportY(for anchor: Anchor, columns: Int, leadingSlots: Int) -> CGFloat {
        guard let cv = collectionView else { return anchor.viewportPoint.y }
        let next = geometry(for: columns, leadingSlots: leadingSlots)
        let frame = next.frame(for: anchor.indexPath.item)
        return anchor.point(in: frame).y - offset(for: anchor, in: next, cv: cv)
    }

    func update(columns: Int, leadingSlots: Int = 0, around anchor: Anchor?) {
        guard let cv = collectionView else { return }
        let next = geometry(for: columns, leadingSlots: leadingSlots)
        let context = UICollectionViewLayoutInvalidationContext()
        if let anchor, anchor.indexPath.item < next.count {
            context.contentOffsetAdjustment.y = offset(for: anchor, in: next, cv: cv) - cv.contentOffset.y
        }
        guard self.columns != columns || geometry.leadingSlots != leadingSlots
            || abs(context.contentOffsetAdjustment.y) >= 0.01 else { return }
        self.columns = columns
        self.leadingSlots = leadingSlots
        invalidateLayout(with: context)
        cv.layoutIfNeeded()
    }

    func geometry(for columns: Int, leadingSlots: Int? = nil) -> PhotoGridGeometry {
        guard let cv = collectionView else { return geometry }
        let inset = cv.adjustedContentInset
        return PhotoGridGeometry(width: max(0, cv.bounds.width - inset.left - inset.right), columns: columns,
            count: cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0,
            leadingSlots: leadingSlots ?? (columns == self.columns ? self.leadingSlots : 0))
    }

    private func offset(for anchor: Anchor, in geometry: PhotoGridGeometry, cv: UICollectionView) -> CGFloat {
        let point = anchor.point(in: geometry.frame(for: anchor.indexPath.item))
        let inset = cv.adjustedContentInset
        let top = -inset.top
        let bottom = max(top, geometry.height + inset.bottom - cv.bounds.height)
        return (point.y - anchor.viewportPoint.y).clamped(to: top...bottom)
    }

    private func attributes(for indexPath: IndexPath) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = geometry.frame(for: indexPath.item)
        return attributes
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
        let dy = max(rect.minY - point.y, point.y - rect.maxY, 0)
        return dx * dx + dy * dy
    }
}

/// One density of the gallery, with constant-time row and frame lookup.
struct PhotoGridGeometry {
    struct Slot: Hashable {
        let row: Int
        let column: Int
    }

    static let spacing: CGFloat = 6
    static let margin: CGFloat = 14
    static let top: CGFloat = 8

    let width: CGFloat
    let columns: Int
    let count: Int
    let leadingSlots: Int

    init(width: CGFloat, columns: Int, count: Int, leadingSlots: Int = 0) {
        self.width = width
        self.columns = columns
        self.count = count
        self.leadingSlots = leadingSlots
    }

    var pitch: CGFloat { max(Self.spacing + 1, (width - 2 * Self.margin + Self.spacing) / CGFloat(columns)) }
    var side: CGFloat { pitch - Self.spacing }
    var height: CGFloat { count > 0 ? frame(for: count - 1).maxY : 0 }

    func frame(for item: Int) -> CGRect {
        frame(at: slot(for: item))
    }

    func slot(for item: Int) -> Slot {
        let position = item + leadingSlots
        return Slot(row: position / columns, column: position % columns)
    }

    func frame(at slot: Slot) -> CGRect {
        CGRect(x: Self.margin + CGFloat(slot.column) * pitch, y: Self.top + CGFloat(slot.row) * pitch,
            width: side, height: side)
    }

    func item(at slot: Slot) -> Int {
        slot.row * columns + slot.column - leadingSlots
    }

    func rows(intersecting rect: CGRect) -> Range<Int> {
        let first = max(0, Int(floor((rect.minY - Self.top) / pitch)))
        let end = max(first, Int(ceil((rect.maxY - Self.top) / pitch)))
        return first..<end
    }

    func items(intersecting rect: CGRect) -> Range<Int> {
        let rows = rows(intersecting: rect)
        let first = (rows.lowerBound * columns - leadingSlots).clamped(to: 0...count)
        let end = (rows.upperBound * columns - leadingSlots).clamped(to: 0...count)
        return first..<end
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
