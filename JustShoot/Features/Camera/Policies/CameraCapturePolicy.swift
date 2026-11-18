import AVFoundation

/// One policy is used by session setup, prepared settings and actual captures.
enum CameraCapturePolicy {
    private static let ordinaryPhotoPixelLimit: Int64 = 26_000_000
    static let qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .quality

    /// Prefer the ordinary 24 MP class where the device exposes it, rather than HEIF Max.
    /// Nominal 24 MP dimensions can contain about 24.5 million pixels. Never invent a size
    /// that the current format does not support; older formats commonly expose only 12/48 MP.
    static func automaticPhotoDimensions(from dimensions: [CMVideoDimensions], deferredDeliveryEnabled: Bool = true) -> CMVideoDimensions? {
        let supported = dimensions.filter {
            $0.width > 0 && $0.height > 0 && abs(Double($0.width) / Double($0.height) - 4.0 / 3.0) < 0.02
                && (deferredDeliveryEnabled || !requiresDeferredDelivery($0))
        }
        func pixels(_ size: CMVideoDimensions) -> Int64 { Int64(size.width) * Int64(size.height) }
        let ordinary = supported.filter { pixels($0) <= ordinaryPhotoPixelLimit }
        return ordinary.max { pixels($0) < pixels($1) } ?? supported.min { pixels($0) < pixels($1) }
    }

    /// AVFoundation only delivers the 24 MP fusion size through PhotoKit's deferred path.
    static func requiresDeferredDelivery(_ dimensions: CMVideoDimensions) -> Bool {
        let pixels = Int64(dimensions.width) * Int64(dimensions.height)
        return dimensions.width > 0 && dimensions.height > 0 && pixels > 20_000_000 && pixels <= ordinaryPhotoPixelLimit
    }

    static func usesDeferredDelivery(supported: Bool, photosAuthorized: Bool, livePhoto: Bool) -> Bool {
        supported && photosAuthorized && !livePhoto
    }

    /// Prefer formats with an ordinary supported size. A Max-only format must not beat
    /// a real 24 MP format merely because its fallback dimensions contain more pixels.
    static func automaticPhotoFormatScore(from dimensions: [CMVideoDimensions]) -> Int64 {
        guard let selected = automaticPhotoDimensions(from: dimensions) else { return .min }
        let pixels = Int64(selected.width) * Int64(selected.height)
        return pixels <= ordinaryPhotoPixelLimit ? pixels : -pixels
    }

    static func qualityPrioritization(supportedMax: AVCapturePhotoOutput.QualityPrioritization) -> AVCapturePhotoOutput.QualityPrioritization {
        switch supportedMax {
        case .speed: return .speed
        case .balanced: return .balanced
        case .quality: return qualityPrioritization
        @unknown default: return .balanced
        }
    }

    static func exposureDurationCap(focalMm: Int, minimum: CMTime, maximum: CMTime) -> CMTime {
        let target = CMTime(value: 1, timescale: Int32(max(focalMm, 24)))
        if CMTimeCompare(target, minimum) < 0 { return minimum }
        if CMTimeCompare(target, maximum) > 0 { return maximum }
        return target
    }
}
