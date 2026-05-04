import Foundation
import CoreLocation
import os

// MARK: - GPS / 定位服务
//
// 30s 缓存 + 零阻塞策略：每次 capturePhoto 取最近一次 fix（缓存或当前），
// 无 fix 时返回 nil（拍照本身不应该被定位等待阻塞）。
// CLLocationManagerDelegate 回调把 currentLocation 不断刷新，使下一张拍照大概率命中 fresh。

extension CameraManager: CLLocationManagerDelegate {

    /// 获取缓存或当前位置（无阻塞等待，30s 缓存策略）
    func cachedOrFreshLocation() async -> CLLocation? {
        let now = Date()

        // 1. 检查 30s 内的缓存
        if let cached = locationCache,
           now.timeIntervalSince(locationCacheTime) < locationCacheExpiry {
            return cached
        }

        // 2. 使用当前位置并更新缓存
        if let fresh = currentLocation {
            locationCache = fresh
            locationCacheTime = now
            return fresh
        }

        // startUpdatingLocation 已在持续更新，无需额外请求
        return nil
    }

    func startLocationServices() {
        locationManager.delegate = self
        // 相片地标 ±100m 足够，`Best` 会触发系统更严格的隐私审查并增加功耗
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 20

        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            setLocationDenied(false)
            startLocationUpdates()
        case .notDetermined:
            // 请求授权后等待 delegate 回调 didChangeAuthorization 再启动
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            setLocationDenied(true)
        default:
            break
        }
    }

    func startLocationUpdates() {
        locationManager.startUpdatingLocation()
    }

    func stopLocationServices() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

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

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            Log.gps.info("gps_auth_changed status=\(status.rawValue)")
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.setLocationDenied(false)
                self.startLocationUpdates()
            case .denied, .restricted:
                self.setLocationDenied(true)
                self.stopLocationServices()
            default:
                break
            }
        }
    }
}
