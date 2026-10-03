import AVFoundation

protocol LivePhotoCaptureConfiguring: AnyObject {
    var isLivePhotoCaptureSupported: Bool { get }
    var isLivePhotoCaptureEnabled: Bool { get set }
}

extension AVCapturePhotoOutput: LivePhotoCaptureConfiguring {}

/// Hardware support, session enablement and the user's saved preference are separate states.
struct LivePhotoCaptureState: Equatable, Sendable {
    let supported: Bool
    let enabled: Bool

    var canCapture: Bool { supported && enabled }

    init(supported: Bool, enabled: Bool) {
        self.supported = supported
        self.enabled = enabled
    }

    init(_ output: some LivePhotoCaptureConfiguring) {
        supported = output.isLivePhotoCaptureSupported
        enabled = output.isLivePhotoCaptureEnabled
    }

    /// Call after all outputs and formats are configured, before startRunning. AVFoundation
    /// can reset enablement when a configuration temporarily loses Live Photo support.
    @discardableResult
    static func prepare(_ output: some LivePhotoCaptureConfiguring) -> Self {
        if output.isLivePhotoCaptureSupported && !output.isLivePhotoCaptureEnabled {
            output.isLivePhotoCaptureEnabled = true
        }
        return Self(output)
    }
}
