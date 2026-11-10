import Foundation

/// Failures before/during native capture stay distinct from durable processing failures.
enum CameraCaptureFailure: String, Error, Sendable {
    case cancelled
    case interrupted
    case unavailable
    case preparationTimedOut = "preparation_timed_out"
    case exposureFailed = "exposure_failed"
    case exposureTimedOut = "exposure_timed_out"
    case previewUnavailable = "preview_unavailable"
    case lensUnavailable = "lens_unavailable"
    case livePhotoUnavailable = "live_photo_unavailable"
    case imageUnavailable = "image_unavailable"
    case deliveryTimedOut = "delivery_timed_out"

    var message: String? {
        switch self {
        case .cancelled: nil
        case .interrupted:
            String(localized: "Capture was interrupted. Please try again when the camera is ready.")
        case .unavailable:
            String(localized: "The camera is unavailable. Reopen the camera and try again.")
        case .preparationTimedOut:
            String(localized: "The camera took too long to prepare. Please try again.")
        case .exposureFailed:
            String(localized: "Exposure could not be applied. Press the shutter to retry.")
        case .exposureTimedOut:
            String(localized: "Exposure took too long to apply. Press the shutter to retry.")
        case .previewUnavailable:
            String(localized: "The camera preview could not be prepared. Please try again.")
        case .lensUnavailable:
            String(localized: "Could not switch to this focal length. Select it again to retry.")
        case .livePhotoUnavailable:
            String(localized: "Live Photo is unavailable. Turn off Live Photo or reopen the camera to try again.")
        case .imageUnavailable:
            String(localized: "Capture failed: couldn't get image data, please try again")
        case .deliveryTimedOut:
            String(localized: "The camera did not deliver a photo in time. Please try again.")
        }
    }
}

/// One monotonic budget follows admission through storage, preview and native submission.
/// Already issued captures keep their separate delivery/checkpoint lifetime.
struct CameraCaptureDeadline: Equatable, Sendable {
    static let preparationTimeout: TimeInterval = 4
    let uptime: TimeInterval

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
         timeout: TimeInterval = preparationTimeout) {
        uptime = now + timeout
    }

    func remaining(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, uptime - now)
    }

    func hasExpired(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        now >= uptime
    }
}
