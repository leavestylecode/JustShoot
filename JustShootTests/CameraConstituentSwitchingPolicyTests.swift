import AVFoundation
import XCTest
@testable import JustShoot

final class CameraConstituentSwitchingPolicyTests: XCTestCase {
    private final class Device: CameraConstituentSwitching {
        var primaryConstituentDeviceSwitchingBehavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior = .auto
        var primaryConstituentDeviceRestrictedSwitchingBehaviorConditions: AVCaptureDevice.PrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions = []
        var writes: [AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior] = []

        func setPrimaryConstituentDeviceSwitchingBehavior(_ behavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior,
            restrictedSwitchingBehaviorConditions: AVCaptureDevice.PrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions) {
            writes.append(behavior)
            primaryConstituentDeviceSwitchingBehavior = behavior
            primaryConstituentDeviceRestrictedSwitchingBehaviorConditions = restrictedSwitchingBehaviorConditions
        }
    }

    func testAnAdoptedZoomPolicyDoesNotReconfigureOnLaterFocalChanges() {
        let device = Device()
        _ = CameraConstituentSwitchingPolicy.applyRestricted(to: device)
        XCTAssertEqual(device.writes, [.restricted])
        for _ in 0..<5 { _ = CameraConstituentSwitchingPolicy.applyRestricted(to: device) }
        XCTAssertEqual(device.writes, [.restricted])
    }

    func testLeavingAPerDeviceLockExplicitlyUnlocksBeforeRestricting() {
        let device = Device()
        device.primaryConstituentDeviceSwitchingBehavior = .locked
        _ = CameraConstituentSwitchingPolicy.applyRestricted(to: device)
        XCTAssertEqual(device.writes, [.auto, .restricted])
        XCTAssertEqual(device.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions, [.videoZoomChanged])
    }

    func testUnsupportedDeviceNeverReceivesAConfigurationWrite() {
        let device = Device()
        device.primaryConstituentDeviceSwitchingBehavior = .unsupported
        _ = CameraConstituentSwitchingPolicy.applyRestricted(to: device)
        XCTAssertTrue(device.writes.isEmpty)
    }
}
