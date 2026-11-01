import Combine
import CoreLocation
import Foundation
import os

/// Only the native operations needed by the shutter flow cross this boundary.
@MainActor
protocol CameraCaptureControlling: AnyObject {
    var diagnostics: DiagnosticTrace { get }
    var diagnosticGeneration: UInt64 { get }
    var entryPreparation: CameraEntryPreparation { get }
    var readiness: CameraReadiness { get }
    var isCaptureAvailable: Bool { get }
    var livePhotoCaptureState: LivePhotoCaptureState { get }
    var automaticWhiteBalanceReading: CameraWhiteBalanceReading? { get }
    var focalInfo: DeviceFocalInfo { get }
    var lensSwitchFailed: Bool { get }
    func captureLocation(at date: Date) -> CLLocation?
    func beginCaptureAdmission() -> CameraCaptureAdmission.Token?
    func isCaptureAdmissionValid(_ token: CameraCaptureAdmission.Token) -> Bool
    func cancelCaptureAdmission(_ token: CameraCaptureAdmission.Token)
    func waitForCapturePreview(lutKey: String, admission: CameraCaptureAdmission.Token) async -> CameraPreviewFrame?
    func capture(admission: CameraCaptureAdmission.Token, live: Bool, previewFrame: CameraPreviewFrame,
                 trace: DiagnosticTrace, onWillCapture: @escaping () -> Void,
                 onExposureComplete: @escaping () -> Void, onShutterReady: @escaping () -> Void,
                 onStillCaptured: @escaping @MainActor (CaptureStill) async -> Void,
                 completion: @escaping (CaptureResult?) -> Void)
}

@MainActor
protocol CaptureProcessing: AnyObject {
    var pendingCount: Int { get }
    func reserve(lutBytes: Int, id: UUID) async -> UUID?
    func cancelReservation(_ id: UUID)
    func preparePreview(_ frame: CameraPreviewFrame, recipe: CaptureRecipe, lut: CubeLUT)
    func checkpointStill(_ still: CaptureStill, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?) async
    func enqueue(_ result: CaptureResult, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?)
}

struct CameraCaptureSelection {
    let source: FilmSource
    let lutKey: String
    let lut: CubeLUT
    let profile: FilmRenderProfile
    let adjustment: ResolvedCameraColorAdjustment?
    let plan: PhotoCapturePlan
    let curveFields: String
    let colorFields: String
}

/// Owns one shutter admission across suspension points. Accepted native callbacks retain
/// this coordinator until their media is handed to the application-wide durable worker.
@MainActor
final class CameraCoordinator: ObservableObject {
    @Published private(set) var isShutterBusy = false
    @Published var error: String?
    private var activeShutterID: UUID?
    private let camera: any CameraCaptureControlling
    private let pipeline: any CaptureProcessing

    init(camera: any CameraCaptureControlling, pipeline: any CaptureProcessing) {
        self.camera = camera
        self.pipeline = pipeline
    }

    func capture(selection: CameraCaptureSelection?, currentLookKey: () -> String,
                 isSceneActive: @escaping () -> Bool, onAccepted: () -> Void,
                 onWillCapture: @escaping () -> Void) async {
        guard camera.entryPreparation.isRevealed, camera.readiness == .ready else {
            camera.diagnostics.event("shutter_ignored", "reason=camera_preparing")
            Log.capture.debug("shutter_ignored reason=camera_preparing")
            return
        }
        guard camera.isCaptureAvailable else {
            camera.diagnostics.event("shutter_ignored", "reason=not_available")
            Log.capture.debug("shutter_ignored reason=not_available")
            return
        }
        guard !isShutterBusy else {
            camera.diagnostics.event("shutter_ignored", "reason=shutter_busy")
            Log.capture.debug("shutter_ignored reason=shutter_busy")
            return
        }
        guard let selection, selection.lutKey == currentLookKey(),
              camera.entryPreparation.isCurrentLookRendered else {
            camera.diagnostics.event("shutter_ignored", "reason=lut_not_ready")
            return
        }
        guard let admission = camera.beginCaptureAdmission() else {
            camera.diagnostics.event("shutter_ignored", "reason=admission_busy")
            return
        }
        let trace = DiagnosticTrace(id: admission.id.uuidString)
        let tapTime = Log.now()
        let captureDate = Date()
        let sceneCCT = camera.automaticWhiteBalanceReading?.temperature
        let location = camera.captureLocation(at: captureDate).map(CaptureLocation.init)
        let wantsLive = selection.plan.capturesLivePhoto
        trace.event("shutter_tap", "camera=\(camera.diagnostics.id) pending=\(pipeline.pendingCount) requested_live=\(wantsLive) \(selection.curveFields) \(selection.colorFields)")
        trace.event("capture_plan", "format=\(selection.plan.format.rawValue) input=\(selection.plan.inputSpace.rawValue) approximate=\(selection.plan.approximateLook)")
        Log.capture.info("shutter_tap source=\(selection.source.photoFilterName, privacy: .public) pending_post=\(self.pipeline.pendingCount)")
        guard !wantsLive || camera.livePhotoCaptureState.canCapture else {
            trace.event("live_photo_request_unavailable", "stage=shutter supported=\(camera.livePhotoCaptureState.supported) enabled=\(camera.livePhotoCaptureState.enabled)")
            camera.cancelCaptureAdmission(admission)
            error = String(localized: "Live Photo is unavailable. Turn off Live Photo or reopen the camera to try again.")
            return
        }
        activeShutterID = admission.id
        isShutterBusy = true
        onAccepted()
        trace.event("shutter_acknowledged", "tap_to_ack_ms=\(Log.ms(since: tapTime))")
        guard let captureID = await pipeline.reserve(lutBytes: selection.lut.byteCount, id: admission.id) else {
            camera.cancelCaptureAdmission(admission)
            releaseShutter(admission.id)
            return
        }
        guard !Task.isCancelled, camera.isCaptureAdmissionValid(admission),
              camera.readiness == .ready, camera.isCaptureAvailable,
              currentLookKey() == selection.lutKey else {
            cancel(captureID, admission: admission)
            return
        }
        guard let frame = await camera.waitForCapturePreview(lutKey: selection.lutKey, admission: admission),
              !Task.isCancelled, camera.isCaptureAdmissionValid(admission),
              currentLookKey() == selection.lutKey else {
            trace.event("capture_skip", "reason=matching_preview_unavailable")
            cancel(captureID, admission: admission)
            if !Task.isCancelled, isSceneActive() {
                error = String(localized: "The camera preview could not be prepared. Please try again.")
            }
            return
        }
        trace.event("capture_framing", "frame_id=\(frame.frameID) focal_seq=\(frame.focalSequence) source_revision=\(frame.sourceRevision) preview_crop=\(frame.crop) frame_age_ms=\(Int((ProcessInfo.processInfo.systemUptime - frame.capturedAt) * 1_000)) \(frame.framingDiagnosticFields)")
        let source = selection.source
        let displayLabel: String?
        if case .custom(_, let name, _, _) = source { displayLabel = name } else { displayLabel = nil }
        let recipe = CaptureRecipe(
            id: captureID, captureDate: captureDate, filterName: source.photoFilterName,
            displayLabel: displayLabel, focalLength: admission.focalLength, outputQuality: nil,
            profile: selection.profile, grainSeed: frame.grainSeed, location: location,
            lutDimension: selection.lut.dimension, chromaticSceneCCT: sceneCCT, photoDisplayTime: nil,
            plan: selection.plan, colorAdjustment: selection.adjustment, frozenChromaticGain: frame.chromaticGain,
            preservesSourceFocalLength: camera.focalInfo.constituent(for: FocalLengthOption(admission.focalLength))?.calibrationSource == .fieldOfView)
        pipeline.preparePreview(frame, recipe: recipe, lut: selection.lut)
        camera.capture(admission: admission, live: wantsLive, previewFrame: frame, trace: trace,
            onWillCapture: {
                trace.event("shutter_feedback")
                Log.capture.info("will_capture dt_from_tap=\(Log.ms(since: tapTime))ms")
                onWillCapture()
            }, onExposureComplete: {
                trace.event("exposure_complete_main")
                Log.capture.info("exposure_complete dt_from_tap=\(Log.ms(since: tapTime))ms")
            }, onShutterReady: {
                trace.event("shutter_available")
                self.releaseShutter(captureID)
            }, onStillCaptured: { still in
                await self.pipeline.checkpointStill(still, recipe: recipe, lut: selection.lut, rawLUT: nil)
            }, completion: { result in
                guard let result else {
                    trace.event("capture_delivery_failed")
                    self.releaseShutter(captureID)
                    self.pipeline.cancelReservation(captureID)
                    guard self.camera.diagnosticGeneration == admission.sessionGeneration else { return }
                    self.error = self.camera.lensSwitchFailed
                        ? String(localized: "Could not switch to this focal length. Select it again to retry.")
                        : wantsLive && !self.camera.livePhotoCaptureState.canCapture
                        ? String(localized: "Live Photo is unavailable. Turn off Live Photo or reopen the camera to try again.")
                        : String(localized: "Capture failed: couldn't get image data, please try again")
                    return
                }
                trace.event("capture_received", "bytes=\(result.imageData.count) live=\(result.livePhotoMovieURL != nil)")
                let time = result.photoDisplayTime
                let completed = recipe.withPhotoDisplayTime(time.isValid && time.isNumeric ? time.seconds : nil)
                trace.event("chromatic_response_snapshot",
                    "native_kk=\(Int(selection.profile.effectiveChromatic.nativeCCT)) strength=\(String(format: "%.2f", selection.profile.effectiveChromatic.strength)) scene_kk=\(sceneCCT.map { Int($0) }.map(String.init) ?? "unavailable") gain=\(String(format: "%.3f/%.3f/%.3f", frame.chromaticGain.x, frame.chromaticGain.y, frame.chromaticGain.z))")
                self.pipeline.enqueue(result, recipe: completed, lut: selection.lut, rawLUT: nil)
            })
    }

    private func cancel(_ id: UUID, admission: CameraCaptureAdmission.Token) {
        pipeline.cancelReservation(id)
        camera.cancelCaptureAdmission(admission)
        releaseShutter(id)
    }

    private func releaseShutter(_ id: UUID) {
        guard activeShutterID == id else { return }
        activeShutterID = nil
        isShutterBusy = false
    }
}

extension CameraManager: CameraCaptureControlling {
    func capture(admission: CameraCaptureAdmission.Token, live: Bool, previewFrame: CameraPreviewFrame,
                 trace: DiagnosticTrace, onWillCapture: @escaping () -> Void,
                 onExposureComplete: @escaping () -> Void, onShutterReady: @escaping () -> Void,
                 onStillCaptured: @escaping @MainActor (CaptureStill) async -> Void,
                 completion: @escaping (CaptureResult?) -> Void) {
        capturePhoto(admission: admission, live: live, previewFrame: previewFrame, trace: trace,
            onWillCapture: onWillCapture, onExposureComplete: onExposureComplete,
            onShutterReady: onShutterReady, onStillCaptured: onStillCaptured, completion: completion)
    }
}

extension CapturePipeline: CaptureProcessing {}
