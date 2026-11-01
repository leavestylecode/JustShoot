import Foundation

enum CameraReadiness: Equatable {
    case idle
    case requestingPermission
    case configuring
    case waitingForFirstFrame
    case ready
    case failed

    var logValue: String {
        switch self {
        case .idle: return "idle"
        case .requestingPermission: return "requesting_permission"
        case .configuring: return "configuring"
        case .waitingForFirstFrame: return "waiting_first_frame"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}
