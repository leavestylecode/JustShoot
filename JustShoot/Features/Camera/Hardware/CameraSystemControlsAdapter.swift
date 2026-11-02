@preconcurrency import AVFoundation
import Foundation
import os

/// The manager never stores an iOS 18 control type on its iOS 17 path.
@MainActor
protocol CameraSystemControls: AnyObject {
    func setEnabled(_ enabled: Bool)
    func selectFocalLength(at index: Int)
    func invalidate()
}

@available(iOS 18.0, *)
@MainActor
final class CameraSystemControlsAdapter: NSObject, CameraSystemControls, AVCaptureSessionControlsDelegate {
    private let trace: DiagnosticTrace
    private var picker: AVCaptureIndexPicker?
    private var slider: AVCaptureSystemExposureBiasSlider?
    private var state = CameraSystemControlsState()

    init(session: AVCaptureSession, device: AVCaptureDevice, titles: [String], selectedIndex: Int?,
         trace: DiagnosticTrace, onFocalLength: @escaping @MainActor (Int) -> Void,
         onExposure: @escaping @MainActor (Float) -> Void) {
        self.trace = trace
        super.init()
        guard session.supportsControls else { return }
        let picker = AVCaptureIndexPicker(String(localized: "Focal length"),
            symbolName: "camera.metering.spot", localizedIndexTitles: titles)
        if let selectedIndex { picker.selectedIndex = selectedIndex }
        picker.setActionQueue(.main) { [weak self] index in
            guard self?.state.isActive == true, titles.indices.contains(index) else { return }
            onFocalLength(index)
        }
        if session.canAddControl(picker) {
            session.addControl(picker)
            self.picker = picker
        }
        let slider = AVCaptureSystemExposureBiasSlider(device: device) { [weak self] bias in
            guard self?.state.isActive == true, bias.isFinite else { return }
            onExposure(bias)
        }
        if session.canAddControl(slider) {
            session.addControl(slider)
            self.slider = slider
        }
        setEnabled(false)
        session.setControlsDelegate(self, queue: .main)
        trace.event("camera_controls_installed", "picker=\(self.picker != nil) exposure=\(self.slider != nil)")
    }

    func setEnabled(_ enabled: Bool) {
        guard state.updateEnabled(enabled) else { return }
        let update = trace.span("main_camera_controls_enabled", "enabled=\(enabled)")
        picker?.isEnabled = enabled
        slider?.isEnabled = enabled
        update.end()
    }

    func selectFocalLength(at index: Int) {
        guard state.isActive, picker?.selectedIndex != index else { return }
        picker?.selectedIndex = index
    }

    func invalidate() {
        state.invalidate()
        // The manager detaches the delegate and removes controls on its hardware queue.
    }

    nonisolated func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        trace.event("camera_controls_active")
    }

    nonisolated func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        trace.event("camera_controls_fullscreen_enter")
    }

    nonisolated func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        trace.event("camera_controls_fullscreen_exit")
    }

    nonisolated func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        trace.event("camera_controls_inactive")
    }
}
