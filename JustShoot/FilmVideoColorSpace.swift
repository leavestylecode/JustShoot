import AVFoundation
import CoreVideo

/// Core Image renders these buffers as sRGB. Declare the same transfer function on both
/// the buffer and writer, so encoding does not invent a different interpretation of its bytes.
enum FilmVideoColorSpace {
    @available(iOS 18.0, *)
    static var writerProperties: [String: String] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }

    static func tag(_ pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
