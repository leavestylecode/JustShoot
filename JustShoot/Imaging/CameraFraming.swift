import CoreGraphics
import Foundation

/// The viewfinder, its captured preview and the full-resolution still share this
/// geometry. Device zoom is already applied to stills; proxy compensation is
/// applied only to the video frame, never a second time to the photograph.
enum CameraFraming {
    static let portraitAspect: CGFloat = 3.0 / 4.0

    static func centeredCrop(in extent: CGRect, aspect: CGFloat, zoom: CGFloat = 1) -> CGRect {
        guard extent.width > 0, extent.height > 0, aspect.isFinite, aspect > 0 else { return .zero }
        let factor = zoom.isFinite ? max(1, zoom) : 1
        let width = min(extent.width, extent.height * aspect) / factor
        let height = width / aspect
        return CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2,
            width: width, height: height)
    }

    static func photoCrop(in extent: CGRect) -> CGRect {
        centeredCrop(in: extent, aspect: extent.width > extent.height ? 1 / portraitAspect : portraitAspect)
    }

    struct Transform {
        let scale: CGFloat
        let offset: CGPoint
    }

    static func previewTransform(input: CGSize, rotation: UInt32, output: CGSize, zoom: CGFloat) -> Transform {
        let rotated = rotation == 1 || rotation == 3 ? CGSize(width: input.height, height: input.width) : input
        let rect = centeredCrop(in: CGRect(origin: .zero, size: rotated),
            aspect: output.width / max(1, output.height), zoom: zoom)
        guard rect.width > 0 else { return Transform(scale: 1, offset: .zero) }
        let scale = output.width / rect.width
        return Transform(scale: scale, offset: CGPoint(x: -rect.minX * scale, y: -rect.minY * scale))
    }
}
