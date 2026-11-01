import Foundation
import ImageIO

/// A proxy is durable input for PhotoKit, never input for the film renderer.
/// Optional journal fields keep captures from earlier releases readable.
struct DeferredPhotoState: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    var assetIdentifier: String?
    var finalized = false

    func acceptsFinalImage(_ data: Data) -> Bool {
        guard width > 0, height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let actualWidth = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let actualHeight = properties[kCGImagePropertyPixelHeight as String] as? Int else { return false }
        return (actualWidth == width && actualHeight == height) || (actualWidth == height && actualHeight == width)
    }
}
