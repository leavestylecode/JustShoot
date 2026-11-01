import CoreLocation
import Foundation
import os

/// Location has its own permission and delegate lifecycle; it never owns the camera session.
@MainActor
final class CameraLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var isActive = false
    private let permissionChanged: (Bool) -> Void

    init(permissionChanged: @escaping (Bool) -> Void) {
        self.permissionChanged = permissionChanged
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 20
    }

    func location(at date: Date) -> CLLocation? {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways,
              let currentLocation, CaptureLocation.isUsable(currentLocation, at: date) else { return nil }
        return currentLocation
    }

    func start() {
        isActive = true
        updateAuthorization(manager.authorizationStatus, requestIfNeeded: true)
    }

    func stop() {
        isActive = false
        manager.stopUpdatingLocation()
    }

    private func updateAuthorization(_ status: CLAuthorizationStatus, requestIfNeeded: Bool) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            permissionChanged(false)
            if isActive { manager.startUpdatingLocation() }
        case .notDetermined:
            if isActive, requestIfNeeded { manager.requestWhenInUseAuthorization() }
        case .denied, .restricted:
            permissionChanged(true)
            currentLocation = nil
            manager.stopUpdatingLocation()
        @unknown default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let location = locations.last {
                self.currentLocation = location
                Log.gps.debug("gps_update acc=\(String(format: "%.1f", location.horizontalAccuracy))m")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Log.gps.error("gps_fail error=\(error.localizedDescription, privacy: .public)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            Log.gps.info("gps_auth_changed status=\(status.rawValue)")
            self.updateAuthorization(status, requestIfNeeded: false)
        }
    }
}
