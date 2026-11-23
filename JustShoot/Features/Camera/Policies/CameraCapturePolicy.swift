import AVFoundation

/// One policy is used by session setup, prepared settings and actual captures.
enum CameraCapturePolicy {
    static let qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .quality
    static let defaultLUTIntensity: Float = 0.88

    /// Keep the still framing at 4:3 and request the largest size the format can deliver.
    static func automaticPhotoDimensions(from dimensions: [CMVideoDimensions], allowsDeferredDelivery: Bool) -> CMVideoDimensions? {
        dimensions.lazy.filter {
            $0.width > 0 && $0.height > 0 && abs(Double($0.width) / Double($0.height) - 4.0 / 3.0) < 0.02
                && (allowsDeferredDelivery || !requiresDeferredDelivery($0))
        }.max { pixelCount($0) < pixelCount($1) }
    }

    /// AVFoundation only delivers the 24 MP fusion size through PhotoKit's deferred path.
    static func requiresDeferredDelivery(_ dimensions: CMVideoDimensions) -> Bool {
        dimensions.width == 5712 && dimensions.height == 4284
    }

    static func photoDelivery(from dimensions: [CMVideoDimensions], deferredDeliverySupported: Bool,
                              photosAuthorized: Bool, livePhoto: Bool) -> (dimensions: CMVideoDimensions?, deferred: Bool) {
        let selected = automaticPhotoDimensions(from: dimensions,
            allowsDeferredDelivery: deferredDeliverySupported && photosAuthorized && !livePhoto)
        return (selected, selected.map(requiresDeferredDelivery) ?? false)
    }

    static func automaticPhotoFormatScore(from dimensions: [CMVideoDimensions], allowsDeferredDelivery: Bool) -> Int64 {
        automaticPhotoDimensions(from: dimensions, allowsDeferredDelivery: allowsDeferredDelivery).map(pixelCount) ?? 0
    }

    private static func pixelCount(_ dimensions: CMVideoDimensions) -> Int64 {
        Int64(dimensions.width) * Int64(dimensions.height)
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
