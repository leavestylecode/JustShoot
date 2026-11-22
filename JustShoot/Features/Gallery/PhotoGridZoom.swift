import UIKit

@MainActor
final class PhotoGridZoom: NSObject, UIGestureRecognizerDelegate {
    private struct Pose {
        let side: CGFloat
        var anchor: SquareGridLayout.Anchor
    }

    private struct Pinch {
        let startSide: CGFloat
        let startScale: CGFloat
        let fingerOffsetY: CGFloat
        let returnColumns: Int
    }

    private struct Settle {
        let from: Pose
        let to: Pose
        let columns: Int
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }

    private weak var collectionView: UICollectionView?
    private weak var layout: SquareGridLayout?
    private lazy var recognizer = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged))
    private var pinch: Pinch?
    private var pose: Pose?
    private var settle: Settle?
    private var displayLink: CADisplayLink?
    private var overlay: PhotoGridZoomOverlay?
    private var leadingSlots: [Int: Int] = [:]

    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onChooseColumns: ((Int) -> Void)?
    var photoAt: ((Int) -> PhotoGridZoomOverlay.PhotoContent?)?
    var thumbnailPixels: (() -> Int)?
    var isZooming: Bool { pinch != nil || settle != nil }
    var isPresentingOverlay: Bool { overlay != nil }
    var presentedSide: CGFloat? { pose?.side }

    func install(in cv: UICollectionView, layout: SquareGridLayout) {
        collectionView = cv
        self.layout = layout
        recognizer.delegate = self
        cv.addGestureRecognizer(recognizer)
    }

    func setActive(_ active: Bool) {
        if !active { completeImmediately() }
        recognizer.isEnabled = active
    }

    func uninstall() {
        stopSettle()
        endPinch()
        removeOverlay()
        pose = nil
        collectionView?.removeGestureRecognizer(recognizer)
    }

    func syncPreferredColumns(_ columns: Int) {
        guard !isZooming, let cv = collectionView, let layout, layout.columns != columns else { return }
        let anchor = layout.anchor(at: CGPoint(x: cv.bounds.width / 2, y: cv.bounds.height / 2))
        layout.update(columns: columns, around: anchor)
        onEnd?()
    }

    func adjust(in cell: UICollectionViewCell, by delta: Int) -> Bool {
        guard let layout, let indexPath = collectionView?.indexPath(for: cell) else { return false }
        return animate(to: layout.columns + delta, around: indexPath, duration: 0.22)
    }

    func handleBrowseTap(at indexPath: IndexPath) -> Bool {
        guard let layout, layout.columns > 3 else { return false }
        _ = animate(to: 3, around: indexPath, duration: 0.34)
        return true
    }

    private func animate(to columns: Int, around indexPath: IndexPath, duration: CFTimeInterval) -> Bool {
        guard !isZooming, let cv = collectionView, let layout, SquareGridLayout.columnRange.contains(columns),
              let frame = layout.layoutAttributesForItem(at: indexPath)?.frame else { return false }
        let visible = frame.intersection(cv.bounds)
        guard !visible.isEmpty else { return false }
        let anchor = SquareGridLayout.Anchor(indexPath: indexPath, tilePoint: CGPoint(
            x: (visible.midX - frame.minX) / frame.width, y: (visible.midY - frame.minY) / frame.height),
            viewportPoint: CGPoint(x: visible.midX - cv.bounds.minX, y: visible.midY - cv.bounds.minY))
        cv.setContentOffset(cv.contentOffset, animated: false)
        pose = Pose(side: layout.tileSide, anchor: anchor)
        leadingSlots = layout.zoomLeadingSlots(for: anchor)
        onBegin?()
        snap(to: columns, duration: duration)
        onChooseColumns?(columns)
        return true
    }

    // Commit a legal layout before scrolling, resizing or applying a new catalog snapshot.
    func completeImmediately() {
        guard let columns = settle?.columns ?? pinch?.returnColumns else { return }
        finish(columns: columns, around: pose?.anchor)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let cv = collectionView, let layout else { return false }
        return pose != nil || layout.anchor(at: viewportPoint(of: gestureRecognizer, in: cv)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer === collectionView?.panGestureRecognizer
    }

    @objc func pinchChanged(_ gesture: UIPinchGestureRecognizer) {
        guard let cv = collectionView, let layout else { return }
        switch gesture.state {
        case .began:
            let point = viewportPoint(of: gesture, in: cv)
            // An interrupted animation already has a visible anchor and scale.
            if pose == nil, let anchor = layout.anchor(at: point) {
                pose = Pose(side: layout.tileSide, anchor: anchor)
                leadingSlots = layout.zoomLeadingSlots(for: anchor)
            }
            guard let pose else { return }
            let columns = settle?.columns ?? layout.columns
            stopSettle()
            pinch = Pinch(startSide: pose.side, startScale: max(0.001, gesture.scale),
                fingerOffsetY: pose.anchor.viewportPoint.y - point.y, returnColumns: columns)
            cv.panGestureRecognizer.isEnabled = false
            cv.setContentOffset(cv.contentOffset, animated: false)
            onBegin?()
        case .changed:
            guard let pinch, let pose, gesture.numberOfTouches == 2, gesture.scale.isFinite, gesture.scale > 0 else { return }
            var anchor = pose.anchor
            anchor.viewportPoint.y = viewportPoint(of: gesture, in: cv).y + pinch.fingerOffsetY
            let range = SquareGridLayout.columnRange
            let side = min(layout.geometry(for: range.lowerBound).side,
                           max(layout.geometry(for: range.upperBound).side, pinch.startSide * gesture.scale / pinch.startScale))
            show(Pose(side: side, anchor: anchor))
        case .ended, .cancelled, .failed:
            guard let pinch, let pose else { return }
            let ended = gesture.state == .ended
            let columns = ended ? nearestColumns(to: pose.side, in: layout) : pinch.returnColumns
            endPinch()
            snap(to: columns)
            if ended { onChooseColumns?(columns) }
        default:
            break
        }
    }

    private func nearestColumns(to side: CGFloat, in layout: SquareGridLayout) -> Int {
        SquareGridLayout.columnRange.min {
            abs(layout.geometry(for: $0).side - side) < abs(layout.geometry(for: $1).side - side)
        } ?? layout.columns
    }

    private func viewportPoint(of gesture: UIGestureRecognizer, in cv: UICollectionView) -> CGPoint {
        let point = gesture.location(in: cv)
        return CGPoint(x: point.x - cv.bounds.minX, y: point.y - cv.bounds.minY)
    }

    private func show(_ pose: Pose) {
        guard let cv = collectionView, let layout else { return }
        self.pose = pose
        if overlay == nil {
            var images: [Int: UIImage] = [:]
            for case let cell as PhotoCell in cv.visibleCells {
                if let path = cv.indexPath(for: cell), let image = cell.transitionImage { images[path.item] = image }
                cell.setZoomCovered(true)
            }
            let overlay = PhotoGridZoomOverlay(frame: cv.bounds, grid: layout.geometry, editing: cv.isEditing,
                leftInset: cv.adjustedContentInset.left,
                basePixels: thumbnailPixels?() ?? 256, baseImages: images, source: photoAt ?? { _ in nil })
            cv.addSubview(overlay)
            self.overlay = overlay
        }
        overlay?.show(side: pose.side, anchor: pose.anchor, leadingSlots: leadingSlots)
    }

    private func endPinch() {
        guard pinch != nil else { return }
        pinch = nil
        collectionView?.panGestureRecognizer.isEnabled = true
    }

    private func snap(to columns: Int, duration: CFTimeInterval = 0.22) {
        guard let layout, let pose else { return }
        var aligned = pose.anchor
        aligned.viewportPoint.y = layout.alignedViewportY(for: pose.anchor, columns: columns,
            leadingSlots: leadingSlots[columns, default: 0])
        let target = Pose(side: layout.geometry(for: columns).side, anchor: aligned)
        if UIAccessibility.isReduceMotionEnabled
            || (target.side == pose.side && aligned.viewportPoint.y == pose.anchor.viewportPoint.y) {
            finish(columns: columns, around: aligned)
            return
        }
        settle = Settle(from: pose, to: target, columns: columns, start: CACurrentMediaTime(), duration: duration)
        let link = CADisplayLink(target: self, selector: #selector(advanceSettle))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func advanceSettle(_ link: CADisplayLink) {
        guard let settle, collectionView != nil else {
            stopSettle()
            return
        }
        let time = min(1, max(0, (link.targetTimestamp - settle.start) / settle.duration))
        if time == 1 {
            finish(columns: settle.columns, around: settle.to.anchor)
            return
        }
        let progress = 1 - CGFloat(pow(1 - time, 3))
        let from = settle.from.anchor.viewportPoint.y
        let to = settle.to.anchor.viewportPoint.y
        var anchor = settle.from.anchor
        anchor.viewportPoint.y = from + (to - from) * progress
        show(Pose(side: settle.from.side + (settle.to.side - settle.from.side) * progress, anchor: anchor))
    }

    private func finish(columns: Int, around anchor: SquareGridLayout.Anchor?) {
        endPinch()
        stopSettle()
        UIView.performWithoutAnimation {
            layout?.update(columns: columns, leadingSlots: leadingSlots[columns, default: 0], around: anchor)
            removeOverlay()
        }
        pose = nil
        leadingSlots.removeAll()
        onEnd?()
    }

    private func removeOverlay() {
        guard let overlay else { return }
        if let cv = collectionView {
            for case let cell as PhotoCell in cv.visibleCells {
                if let path = cv.indexPath(for: cell) { cell.seedZoomThumbnail(overlay.thumbnail(at: path.item)) }
                cell.setZoomCovered(false)
            }
        }
        overlay.cancelRequests()
        overlay.removeFromSuperview()
        self.overlay = nil
    }

    private func stopSettle() {
        displayLink?.invalidate()
        displayLink = nil
        settle = nil
    }
}
