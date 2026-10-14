import AVFoundation
import Foundation

/// One policy is used by session setup, prepared settings and actual captures.
struct CameraCapturePolicy: Sendable, Equatable {
    let photoQuality: PhotoQuality
    let safeShutterEnabled: Bool

    static var current: Self { Self(defaults: .standard) }

    init(photoQuality: PhotoQuality, safeShutterEnabled: Bool) {
        self.photoQuality = photoQuality
        self.safeShutterEnabled = safeShutterEnabled
    }

    init(defaults: UserDefaults) {
        photoQuality = defaults.string(forKey: "photoOutputQuality")
            .flatMap(PhotoQuality.init(rawValue:)) ?? .default
        safeShutterEnabled = defaults.object(forKey: "safeShutterLimitEnabled") as? Bool ?? true
    }

    var qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization {
        photoQuality == .maximum ? .quality : .balanced
    }

    func qualityPrioritization(supportedMax: AVCapturePhotoOutput.QualityPrioritization) -> AVCapturePhotoOutput.QualityPrioritization {
        switch supportedMax {
        case .speed: return .speed
        case .balanced: return .balanced
        case .quality: return qualityPrioritization
        @unknown default: return .balanced
        }
    }

    func exposureDurationCap(focalMm: Int, minimum: CMTime, maximum: CMTime) -> CMTime {
        guard safeShutterEnabled else { return maximum }
        let target = CMTime(value: 1, timescale: Int32(max(focalMm, 24)))
        if CMTimeCompare(target, minimum) < 0 { return minimum }
        if CMTimeCompare(target, maximum) > 0 { return maximum }
        return target
    }
}
