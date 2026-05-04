import Foundation
@preconcurrency import AVFoundation
import UIKit
import CoreMotion
import ImageIO
import os

// MARK: - 方向监控（CoreMotion 直读重力向量，绕过系统旋转锁）

extension CameraManager {

    func setupOrientationMonitoring() {
        bootstrapInitialOrientationIfNeeded()
        startAccelerometerOrientationUpdates()
    }

    /// 启动加速度计读取并转换为 UIDeviceOrientation。5 Hz 足够流畅，CPU/电池开销忽略不计。
    /// 重力向量约定（Apple）：accel 报"重力方向"，portrait 时 -y_d 朝下 → accel.y ≈ -1；
    /// upsideDown ≈ +1；landscapeLeft（home 在右、设备 +x 朝天）重力沿 -x → accel.x ≈ -1；
    /// landscapeRight（home 在左、设备 +x 朝地）重力沿 +x → accel.x ≈ +1。
    func startAccelerometerOrientationUpdates() {
        guard motionManager.isAccelerometerAvailable, !motionManager.isAccelerometerActive else { return }
        motionManager.accelerometerUpdateInterval = 0.2
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.updateOrientationFromAcceleration(data.acceleration)
        }
    }

    /// 把重力向量映射成 UIDeviceOrientation。带阈值过滤：设备过于水平（|z| 占优）保留当前方向，
    /// 避免桌面/俯视摆放时方向乱跳。仅在判定值与当前不同时写入，触发的 @Published 通知最少。
    func updateOrientationFromAcceleration(_ a: CMAcceleration) {
        let absX = abs(a.x)
        let absY = abs(a.y)
        let absZ = abs(a.z)

        // 主轴必须显著大于 z 轴（设备不能太平），且至少 0.5g 量级才算"明确指向"
        guard max(absX, absY) > 0.5, max(absX, absY) > absZ else { return }

        let candidate: UIDeviceOrientation
        if absY > absX {
            candidate = a.y < 0 ? .portrait : .portraitUpsideDown
        } else {
            // landscapeLeft（home 在右）：accel.x ≈ -1；landscapeRight（home 在左）：accel.x ≈ +1
            candidate = a.x > 0 ? .landscapeRight : .landscapeLeft
        }

        guard candidate != currentDeviceOrientation else { return }
        currentDeviceOrientation = candidate
        previewDeviceOrientation = candidate
        applyVideoOrientationToOutputs()
    }

    /// 停止加速度计（页面退出时调用）
    func stopAccelerometerOrientationUpdates() {
        if motionManager.isAccelerometerActive {
            motionManager.stopAccelerometerUpdates()
        }
    }

    func bootstrapInitialOrientationIfNeeded() {
        if previewDeviceOrientation == nil || previewDeviceOrientation == .unknown {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let io = scene.effectiveGeometry.interfaceOrientation
                let dev: UIDeviceOrientation
                switch io {
                case .portrait: dev = .portrait
                case .portraitUpsideDown: dev = .portraitUpsideDown
                case .landscapeLeft: dev = .landscapeRight
                case .landscapeRight: dev = .landscapeLeft
                default: dev = .portrait
                }
                previewDeviceOrientation = dev
                currentDeviceOrientation = dev
                applyVideoOrientationToOutputs()
            }
        }
    }

    /// 监听 RotationCoordinator 的 horizon-level capture 角度。该值依赖 motion sensor 异步收敛——
    /// 如果用户横屏入页，光在 configureAndStartSession 末尾同步读一次会读到尚未收敛的默认值,
    /// 把 photoOutput.connection.videoRotationAngle 钉死成错向，导致出片永远是错角度。KVO 联动后,
    /// motion 数据一到位就 reapply，与 Apple 在 RotationCoordinator 文档里推荐的做法一致。
    func observeCaptureRotationAngle() {
        captureRotationObservation?.invalidate()
        guard let coordinator = rotationCoordinator else { return }
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyVideoOrientationToOutputs()
            }
        }
    }

    func applyVideoOrientationToOutputs() {
        // 预览旋转 vs 出片旋转必须解耦——对齐 iPhone 系统相机的体验：
        //
        // 1) **预览（MTKView）**：UI 在 AppDelegate 锁死竖屏，viewport 永远 3:4 portrait。
        //    无论用户竖握还是横握，预览框都不旋转，所以这里固定 90°（sensor landscape → portrait viewport
        //    的 CW 旋转）。
        //
        // 2) **出片（photoOutput.connection）**：跟随物理设备朝向，让 JPEG 的"上"方向与用户当时的"上"方向
        //    一致。横握 → 出 4:3 横片，竖握 → 出 3:4 竖片。相册/详情靠 EXIF orientation 渲染，横片在竖屏
        //    UI 里就上下留黑边横向展示，与系统 Photos 一致。
        //    使用 RotationCoordinator.videoRotationAngleForHorizonLevelCapture：portrait→90, landscapeRight→0,
        //    landscapeLeft→180, upsideDown→270。
        previewRotationAngle = 90

        guard let coordinator = rotationCoordinator else { return }
        let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let pconn = photoOutput.connection(with: .video),
           pconn.isVideoRotationAngleSupported(captureAngle) {
            pconn.videoRotationAngle = captureAngle
        }
        Log.orientation.info("rotation_applied preview=90° capture=\(Int(captureAngle))° device=\(self.currentDeviceOrientation.rawValue)")
    }

    // MARK: - EXIF 方向

    func exifOrientationFromRotationAngle(_ rotationAngle: CGFloat) -> Int {
        let normalizedAngle = Int(rotationAngle) % 360
        switch normalizedAngle {
        case 0: return 1
        case 90, -270: return 6
        case 180, -180: return 3
        case 270, -90: return 8
        default: return 1
        }
    }

    func orientationFromRotationAngle(_ rotationAngle: CGFloat) -> CGImagePropertyOrientation {
        let normalizedAngle = Int(rotationAngle) % 360
        switch normalizedAngle {
        case 0: return .up
        case 90, -270: return .right
        case 180, -180: return .down
        case 270, -90: return .left
        default: return .up
        }
    }
}
