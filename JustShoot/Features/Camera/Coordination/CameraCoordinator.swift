import Combine
import CoreLocation
import Foundation
import os

/// Only the native operations needed by the shutter flow cross this boundary.
@MainActor
protocol CameraCaptureControlling: AnyObject {
    var diagnostics: DiagnosticTrace { get }
    var diagnosticGeneration: UInt64 { get }
    var captureFeedbackGeneration: UInt64 { get }
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
    @discardableResult func cancelCaptureAdmission(_ token: CameraCaptureAdmission.Token) -> Bool
    func waitForCapturePreview(lutKey: String, lutIntensity: Float,
                               admission: CameraCaptureAdmission.Token) async -> CameraPreviewFrame?
    func capture(admission: CameraCaptureAdmission.Token, live: Bool, hdrFormat: CameraRAWFormat?,
                 previewFrame: CameraPreviewFrame,
                 trace: DiagnosticTrace, onWillCapture: @escaping () -> Void,
                 onExposureComplete: @escaping () -> Void, onShutterReady: @escaping () -> Void,
                 onStillCaptured: @escaping @MainActor (CaptureStill) async -> Void,
                 onFinalStill: @escaping (Data) -> Void,
                 completion: @escaping (Result<CaptureResult, CameraCaptureFailure>) -> Void)
}

@MainActor
protocol CaptureProcessing: AnyObject {
    var pendingCount: Int { get }
    func reserve(lutBytes: Int, id: UUID) async -> UUID?
    func cancelReservation(_ id: UUID)
    func preparePreview(_ frame: CameraPreviewFrame, recipe: CaptureRecipe, lut: CubeLUT)
    func checkpointStill(_ still: CaptureStill, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?) async
    func enqueue(_ result: CaptureResult, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?)
    /// Native-delivered 24 MP final for a deferred capture; races the PhotoKit re-read.
    func deliverFinalStill(_ data: Data, id: UUID)
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
    var lutIntensity: Float = 1
    var hdrFormat: CameraRAWFormat? = nil
}

/// Owns one shutter admission across suspension points. Accepted native callbacks retain
/// this coordinator until their media is handed to the application-wide durable worker.
@MainActor
final class CameraCoordinator: ObservableObject {
    @Published private(set) var isShutterBusy = false
    @Published private(set) var showsCaptureProgress = false
    @Published var error: String?
    private(set) var activeShutterID: UUID?
    private var progressTask: Task<Void, Never>?
    private let camera: any CameraCaptureControlling
    private let pipeline: any CaptureProcessing

    @MainActor
    private final class Attempt {
        let feedbackGeneration: UInt64
        var expired = false
        var timeout: Task<Void, Never>?
        var reservation: Task<UUID?, Never>?

        init(feedbackGeneration: UInt64) { self.feedbackGeneration = feedbackGeneration }
    }

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
        let needsProRAW = selection.plan.format == .hdrProRAW
        let hdrFormat = needsProRAW ? selection.hdrFormat : nil
        if needsProRAW, hdrFormat?.kind != .appleProRAW {
            error = CameraCaptureFailure.hdrUnavailable.message
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
        error = nil
        let attempt = Attempt(feedbackGeneration: camera.captureFeedbackGeneration)
        progressTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.activeShutterID == admission.id else { return }
            self.showsCaptureProgress = true
        }
        attempt.timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(admission.deadline.remaining())) } catch { return }
            // The hardware commit and cancellation compete under the same admission lock.
            // Once issued, native delivery/checkpointing owns the shutter lifetime.
            guard self.camera.cancelCaptureAdmission(admission) else { return }
            attempt.expired = true
            trace.event("capture_preparation_timeout")
            self.pipeline.cancelReservation(admission.id)
            attempt.reservation?.cancel()
            self.releaseShutter(admission.id)
            self.report(self.preparationFailure(admission, fallback: .preparationTimedOut),
                attempt: attempt, isSceneActive: isSceneActive)
        }
        var handedToCamera = false
        defer { if !handedToCamera { attempt.timeout?.cancel() } }
        onAccepted()
        trace.event("shutter_acknowledged", "tap_to_ack_ms=\(Log.ms(since: tapTime))")
        let reservation = Task { await pipeline.reserve(lutBytes: selection.lut.byteCount, id: admission.id) }
        attempt.reservation = reservation
        let reservedID = await withTaskCancellationHandler {
            await reservation.value
        } onCancel: { reservation.cancel() }
        attempt.reservation = nil
        guard let captureID = reservedID else {
            camera.cancelCaptureAdmission(admission)
            releaseShutter(admission.id)
            return
        }
        let rawRecipe: RawCaptureRecipe?
        if hdrFormat != nil {
            let lut = selection.lut
            rawRecipe = await Task.detached(priority: .userInitiated) { RawCaptureRecipe(unifiedLUT: lut) }.value
        } else {
            rawRecipe = nil
        }
        guard !attempt.expired else { pipeline.cancelReservation(captureID); return }
        guard !Task.isCancelled, camera.isCaptureAdmissionValid(admission),
              camera.readiness == .ready, camera.isCaptureAvailable,
              currentLookKey() == selection.lutKey, !admission.deadline.hasExpired() else {
            if !Task.isCancelled, currentLookKey() == selection.lutKey {
                report(preparationFailure(admission, fallback: .unavailable),
                    attempt: attempt, isSceneActive: isSceneActive)
            }
            cancel(captureID, admission: admission)
            return
        }
        guard let frame = await camera.waitForCapturePreview(lutKey: selection.lutKey,
                  lutIntensity: selection.lutIntensity, admission: admission),
              !attempt.expired, !Task.isCancelled, camera.isCaptureAdmissionValid(admission),
              !admission.deadline.hasExpired(),
              currentLookKey() == selection.lutKey else {
            trace.event("capture_skip", "reason=matching_preview_unavailable")
            if !attempt.expired, !Task.isCancelled, currentLookKey() == selection.lutKey {
                report(preparationFailure(admission, fallback: .previewUnavailable),
                    attempt: attempt, isSceneActive: isSceneActive)
            }
            cancel(captureID, admission: admission)
            return
        }
        trace.event("capture_framing", "frame_id=\(frame.frameID) focal_seq=\(frame.focalSequence) source_revision=\(frame.sourceRevision) preview_crop=\(frame.crop) lut_intensity=\(frame.lutIntensity) frame_age_ms=\(Int((ProcessInfo.processInfo.systemUptime - frame.capturedAt) * 1_000)) \(frame.framingDiagnosticFields)")
        let source = selection.source
        let displayLabel: String?
        if case .custom(_, let name, _, _) = source { displayLabel = name } else { displayLabel = nil }
        let recipe = CaptureRecipe(
            id: captureID, captureDate: captureDate, filterName: source.photoFilterName,
            displayLabel: displayLabel, focalLength: admission.focalLength, outputQuality: nil,
            profile: selection.profile, grainSeed: frame.grainSeed, location: location,
            lutDimension: selection.lut.dimension, chromaticSceneCCT: sceneCCT, photoDisplayTime: nil,
            raw: rawRecipe,
            plan: selection.plan, colorAdjustment: selection.adjustment, frozenChromaticGain: frame.chromaticGain,
            preservesSourceFocalLength: camera.focalInfo.constituent(for: FocalLengthOption(admission.focalLength))?.calibrationSource == .fieldOfView,
            lutIntensity: frame.lutIntensity)
        handedToCamera = true
        let pipeline = self.pipeline
        camera.capture(admission: admission, live: wantsLive, hdrFormat: hdrFormat, previewFrame: frame, trace: trace,
            onWillCapture: {
                trace.event("shutter_feedback")
                Log.capture.info("will_capture dt_from_tap=\(Log.ms(since: tapTime))ms")
                onWillCapture()
            }, onExposureComplete: {
                pipeline.preparePreview(frame, recipe: recipe, lut: selection.lut)
                trace.event("exposure_complete_main")
                Log.capture.info("exposure_complete dt_from_tap=\(Log.ms(since: tapTime))ms")
            }, onShutterReady: {
                attempt.timeout?.cancel()
                trace.event("shutter_available")
                self.releaseShutter(captureID)
            }, onStillCaptured: { still in
                await self.pipeline.checkpointStill(still, recipe: recipe, lut: selection.lut, rawLUT: nil)
            }, onFinalStill: { data in
                // The native final bypasses the PhotoKit re-read when it wins the race.
                pipeline.deliverFinalStill(data, id: captureID)
            }, completion: { outcome in
                attempt.timeout?.cancel()
                guard !attempt.expired else { return }
                switch outcome {
                case .failure(let failure):
                    trace.event("capture_delivery_failed", "reason=\(failure.rawValue)")
                    self.releaseShutter(captureID)
                    self.pipeline.cancelReservation(captureID)
                    let reported = self.camera.diagnosticGeneration == admission.sessionGeneration ? failure : .interrupted
                    self.report(reported, attempt: attempt, isSceneActive: isSceneActive)
                    return
                case .success(let result):
                    trace.event("capture_received", "bytes=\(result.imageData.count) live=\(result.livePhotoMovieURL != nil)")
                    let time = result.photoDisplayTime
                    let completed = recipe.withPhotoDisplayTime(time.isValid && time.isNumeric ? time.seconds : nil)
                    trace.event("chromatic_response_snapshot",
                        "native_kk=\(Int(selection.profile.effectiveChromatic.nativeCCT)) strength=\(String(format: "%.2f", selection.profile.effectiveChromatic.strength)) scene_kk=\(sceneCCT.map { Int($0) }.map(String.init) ?? "unavailable") gain=\(String(format: "%.3f/%.3f/%.3f", frame.chromaticGain.x, frame.chromaticGain.y, frame.chromaticGain.z))")
                    self.pipeline.enqueue(result, recipe: completed, lut: selection.lut, rawLUT: nil)
                }
            })
    }

    private func preparationFailure(_ admission: CameraCaptureAdmission.Token,
                                    fallback: CameraCaptureFailure) -> CameraCaptureFailure {
        if camera.lensSwitchFailed { return .lensUnavailable }
        if camera.diagnosticGeneration != admission.sessionGeneration { return .interrupted }
        if admission.deadline.hasExpired() { return .preparationTimedOut }
        return fallback
    }

    private func report(_ failure: CameraCaptureFailure, attempt: Attempt, isSceneActive: () -> Bool) {
        guard camera.captureFeedbackGeneration == attempt.feedbackGeneration,
              isSceneActive(), let message = failure.message else { return }
        error = message
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
        progressTask?.cancel()
        progressTask = nil
        showsCaptureProgress = false
    }
}

extension CameraManager: CameraCaptureControlling {
    func capture(admission: CameraCaptureAdmission.Token, live: Bool, hdrFormat: CameraRAWFormat?,
                 previewFrame: CameraPreviewFrame,
                 trace: DiagnosticTrace, onWillCapture: @escaping () -> Void,
                 onExposureComplete: @escaping () -> Void, onShutterReady: @escaping () -> Void,
                 onStillCaptured: @escaping @MainActor (CaptureStill) async -> Void,
                 onFinalStill: @escaping (Data) -> Void,
                 completion: @escaping (Result<CaptureResult, CameraCaptureFailure>) -> Void) {
        capturePhoto(admission: admission, live: live, raw: hdrFormat != nil, expectedRAWFormat: hdrFormat,
            hdr: hdrFormat != nil, previewFrame: previewFrame, trace: trace,
            onWillCapture: onWillCapture, onExposureComplete: onExposureComplete,
            onShutterReady: onShutterReady, onStillCaptured: onStillCaptured,
            onFinalStill: onFinalStill, completion: completion)
    }
}

extension CapturePipeline: CaptureProcessing {}
