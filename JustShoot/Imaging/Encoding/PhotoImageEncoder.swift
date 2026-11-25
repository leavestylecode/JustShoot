import CoreImage
import ImageIO

/// The normal path renders pixels and metadata once as 10-bit HEIC. Only an unavailable
/// encoder causes a codec fallback; file size never causes a second encoding attempt.
enum PhotoImageEncoder {
    struct Output: Sendable {
        let data: Data
        let decision: PhotoEncodingPolicy.Decision
    }

    static func encode(
        _ image: CIImage,
        context: CIContext,
        colorSpace: CGColorSpace,
        legacyQuality: CGFloat? = nil,
        mode: PhotoEncodingPolicy.Mode = .automatic,
        hdrImage: CIImage? = nil,
        cancellation: CaptureRenderCancellation? = nil
    ) -> Output? {
        guard !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        if let hdrImage {
            guard #available(iOS 18.0, *), hdrImage.extent == image.extent else { return nil }
        }
        for codec in PhotoEncodingPolicy.Codec.allCases {
            guard cancellation?.isCancelled != true else { return nil }
            let decision = PhotoEncodingPolicy.decision(for: codec, legacyQuality: legacyQuality, mode: mode)
            var options: [CIImageRepresentationOption: Any] = [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: decision.quality
            ]
            // Core Image omits the map when the rendered scene has no HDR headroom.
            if #available(iOS 18.0, *), let hdrImage { options[.hdrImage] = hdrImage }
            let data: Data?
            switch codec {
            case .heif10:
                data = try? context.heif10Representation(of: image, colorSpace: colorSpace, options: options)
            case .heif8:
                data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: options)
            case .jpeg:
                data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
            }
            guard cancellation?.isCancelled != true else { return nil }
            if let data { return Output(data: data, decision: decision) }
        }
        return nil
    }
}
