import AVFoundation

protocol CameraConstituentSwitching: AnyObject {
    var primaryConstituentDeviceSwitchingBehavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior { get }
    var primaryConstituentDeviceRestrictedSwitchingBehaviorConditions: AVCaptureDevice.PrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions { get }
    func setPrimaryConstituentDeviceSwitchingBehavior(_ behavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior,
        restrictedSwitchingBehaviorConditions: AVCaptureDevice.PrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions)
}

extension AVCaptureDevice: CameraConstituentSwitching {}

/// The caller already holds the device configuration lock. Reasserting an unchanged
/// switching policy can reconfigure the streaming pipeline, so only write real changes.
enum CameraConstituentSwitchingPolicy {
    nonisolated static func applyRestricted(to device: some CameraConstituentSwitching) -> String {
        let behavior = device.primaryConstituentDeviceSwitchingBehavior
        guard behavior != .unsupported else { return "unsupported" }
        let conditions: AVCaptureDevice.PrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions = [.videoZoomChanged]
        if behavior == .restricted && device.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions == conditions {
            return "unchanged_restricted_zoom_changed"
        }
        // The iOS 27 per-device lock API explicitly requires .auto to unlock. Set the
        // restricted policy again within the same configuration lock before changing zoom.
        if behavior == .locked {
            device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
        }
        device.setPrimaryConstituentDeviceSwitchingBehavior(.restricted, restrictedSwitchingBehaviorConditions: conditions)
        return behavior == .locked ? "unlocked_then_restricted" : "restricted_zoom_changed"
    }
}
