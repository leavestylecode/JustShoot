import UIKit

enum PhotoDetailImagePolicy {
    static let thumbnailMaxPixel = 160
    static let thumbnailRadius = 4

    static func previewMaxPixel(bounds: CGRect, scale: CGFloat) -> Int {
        let pixels = max(bounds.width, bounds.height) * scale
        guard pixels.isFinite, pixels > 0 else { return 2556 }
        return max(256, Int(pixels.rounded(.up)))
    }

    static func previewRange(count: Int, currentIndex: Int) -> Range<Int> {
        guard (0..<count).contains(currentIndex) else { return 0..<0 }
        return max(0, currentIndex - 1)..<min(count, currentIndex + 2)
    }
}
