import CoreImage
import CoreVideo
import os

/// One immutable camera buffer retained after presentation. Holding a
/// reference at shutter time does no decoding, texture readback or disk I/O.
struct CameraPreviewFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let generation: UInt64
    let frameID: UInt64
    let capturedAt: TimeInterval
    let lutKey: String
    let rotation: UInt32
    let crop: CGFloat
    let outputSize: CGSize
    let grainSeed: UInt32
    var chromaticGain = SIMD3<Float>(repeating: 1)
    var lutIntensity: Float = 1
    var focalSequence: UInt64 = 0
    var sourceRevision: UInt64 = 0
    var presentedAt: TimeInterval? = nil

    var framingDiagnosticFields: String {
        let aperture = CVImageBufferGetCleanRect(buffer)
        let clean = String(format: "%.1f,%.1f,%.1f,%.1f", aperture.minX, aperture.minY, aperture.width, aperture.height)
        return "input=\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) output=\(Int(outputSize.width))x\(Int(outputSize.height)) rotation=\(rotation) clean_aperture=\(clean)"
    }

    func inputImage(maximumPixel: CGFloat) -> CIImage {
        // Metal samples the encoded BGRA values directly under the sRGB contract.
        var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: FilmImagePipeline.colorSpace])
        switch rotation {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        let extent = image.extent
        let aspect = outputSize.width / max(1, outputSize.height)
        let rect = CameraFraming.centeredCrop(in: extent, aspect: aspect, zoom: crop)
        let width = rect.width
        let height = rect.height
        image = image.cropped(to: rect)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, maximumPixel / max(width, height))
        // CI expands transformed fractional extents to cover whole pixels. Bound
        // the final extent explicitly so floating-point noise cannot add a row.
        let output = CGRect(x: 0, y: 0, width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded()))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: output)
    }
}

/// A drawable can outlive its presentation callback. Transfer the frame exactly
/// once so a recycled drawable cannot keep a camera-pool buffer pinned afterward.
final class CameraPreviewPresentationLease: Sendable {
    private let frame: OSAllocatedUnfairLock<CameraPreviewFrame?>

    init(_ frame: CameraPreviewFrame) {
        self.frame = OSAllocatedUnfairLock(initialState: frame)
    }

    func takeFrame() -> CameraPreviewFrame? {
        frame.withLock { stored in
            defer { stored = nil }
            return stored
        }
    }
}
