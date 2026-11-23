import CoreLocation
import CoreMedia
import CoreVideo
import XCTest
@testable import JustShoot

@MainActor
private final class CaptureCameraStub: CameraCaptureControlling {
    struct Callbacks {
        let still: @MainActor (CaptureStill) async -> Void
        let exposed: () -> Void
        let finalStill: (Data) -> Void
        let ready: () -> Void
        let result: (Result<CaptureResult, CameraCaptureFailure>) -> Void
    }
    let diagnostics = DiagnosticTrace(id: "coordinator-test")
    var diagnosticGeneration: UInt64 = 1
    var captureFeedbackGeneration: UInt64 = 0
    var preparationTimeout: TimeInterval = 4
    var automaticallyIssuesCapture = true
    var entryPreparation = CameraEntryPreparation()
    var readiness = CameraReadiness.ready
    var isCaptureAvailable = true
    var livePhotoCaptureState = LivePhotoCaptureState(supported: true, enabled: true)
    var automaticWhiteBalanceReading: CameraWhiteBalanceReading?
    var focalInfo = DeviceFocalInfo.placeholder
    var lensSwitchFailed = false
    var admission = CameraCaptureAdmission()
    var frame: CameraPreviewFrame?
    var callbacks: [Callbacks] = []

    init() throws {
        entryPreparation.updateLUT(expectedKey: "film", preparedKey: "film")
        entryPreparation.begin(generation: 1)
        entryPreparation.preparedDevice(generation: 1, completedAt: 0)
        entryPreparation.preparedResources(generation: 1)
        entryPreparation.preparedPhotoTemplate(generation: 1)
        entryPreparation.preparedAudio(generation: 1)
        entryPreparation.updateReadiness(generation: 1, session: true, preview: true, capture: true, pipeline: true)
        entryPreparation.rendered(generation: 1, lutKey: "film", capturedAt: 1)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        frame = CameraPreviewFrame(buffer: try XCTUnwrap(buffer), generation: 1, frameID: 1,
            capturedAt: ProcessInfo.processInfo.systemUptime, lutKey: "film", rotation: 0, crop: 1,
            outputSize: CGSize(width: 4, height: 4), grainSeed: 42, chromaticGain: SIMD3(0.9, 1, 1.1))
    }

    func captureLocation(at date: Date) -> CLLocation? { nil }
    func beginCaptureAdmission() -> CameraCaptureAdmission.Token? {
        admission.begin(sessionGeneration: diagnosticGeneration, focalSequence: 0, focalLength: 35,
            exposureBias: 0, flashEnabled: false, rotationAngle: nil,
            deadline: CameraCaptureDeadline(timeout: preparationTimeout))
    }
    func isCaptureAdmissionValid(_ token: CameraCaptureAdmission.Token) -> Bool {
        admission.permits(token, generation: diagnosticGeneration)
    }
    @discardableResult
    func cancelCaptureAdmission(_ token: CameraCaptureAdmission.Token) -> Bool {
        admission.active != token || admission.cancel(token)
    }
    func waitForCapturePreview(lutKey: String, lutIntensity: Float,
                               admission: CameraCaptureAdmission.Token) async -> CameraPreviewFrame? {
        guard let frame, frame.lutIntensity == lutIntensity else { return nil }
        return frame
    }
    func capture(admission token: CameraCaptureAdmission.Token, live: Bool, previewFrame: CameraPreviewFrame,
                 trace: DiagnosticTrace, onWillCapture: @escaping () -> Void,
                 onExposureComplete: @escaping () -> Void, onShutterReady: @escaping () -> Void,
                 onStillCaptured: @escaping @MainActor (CaptureStill) async -> Void,
                 onFinalStill: @escaping (Data) -> Void,
                 completion: @escaping (Result<CaptureResult, CameraCaptureFailure>) -> Void) {
        XCTAssertTrue(admission.beginPreparation(token, generation: diagnosticGeneration))
        if automaticallyIssuesCapture { XCTAssertTrue(admission.markIssued(token, generation: diagnosticGeneration)) }
        callbacks.append(Callbacks(still: onStillCaptured, exposed: onExposureComplete, finalStill: onFinalStill, ready: {
            self.admission.release(token)
            onShutterReady()
        }, result: completion))
    }
}

@MainActor
private final class CapturePipelineStub: CaptureProcessing {
    var pendingCount = 0
    var hasRoom = true
    var onReserve: (() async -> Void)?
    var reserved: Set<UUID> = []
    var cancelled: Set<UUID> = []
    var checkpoints: [CaptureRecipe] = []
    var completed: [CaptureRecipe] = []
    var preview: CaptureRecipe?
    var finalStills: [(data: Data, id: UUID)] = []

    func reserve(lutBytes: Int, id: UUID) async -> UUID? {
        guard hasRoom else { return nil }
        reserved.insert(id)
        await onReserve?()
        return reserved.contains(id) ? id : nil
    }
    func cancelReservation(_ id: UUID) { reserved.remove(id); cancelled.insert(id) }
    func preparePreview(_ frame: CameraPreviewFrame, recipe: CaptureRecipe, lut: CubeLUT) { preview = recipe }
    func checkpointStill(_ still: CaptureStill, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?) async {
        checkpoints.append(recipe)
    }
    func enqueue(_ result: CaptureResult, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?) { completed.append(recipe) }
    func deliverFinalStill(_ data: Data, id: UUID) { finalStills.append((data, id)) }
}

@MainActor
final class CameraCoordinatorTests: XCTestCase {
    func testExposureFailuresKeepTheirActionableReason() async throws {
        for failure in [CameraCaptureFailure.exposureFailed, .exposureTimedOut, .preparationTimedOut] {
            let camera = try CaptureCameraStub()
            let pipeline = CapturePipelineStub()
            let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
            await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
                isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
            camera.callbacks[0].ready()
            camera.callbacks[0].result(.failure(failure))
            XCTAssertEqual(coordinator.error, failure.message)
            XCTAssertFalse(coordinator.isShutterBusy)
            XCTAssertTrue(pipeline.reserved.isEmpty)
            camera.callbacks.removeAll()
        }
    }

    func testRuntimeRestartReportsFailureButLeavingAndReturningSuppressesOldFailure() async throws {
        for leavesCamera in [false, true] {
            let camera = try CaptureCameraStub()
            let pipeline = CapturePipelineStub()
            let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
            await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
                isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
            camera.diagnosticGeneration += 1
            if leavesCamera { camera.captureFeedbackGeneration += 1 }
            camera.callbacks[0].ready()
            camera.callbacks[0].result(.failure(.imageUnavailable))
            XCTAssertEqual(coordinator.error, leavesCamera ? nil : CameraCaptureFailure.interrupted.message)
            XCTAssertFalse(coordinator.isShutterBusy)
            camera.callbacks.removeAll()
        }
    }

    func testRuntimeRestartWhileReservingReportsInterruption() async throws {
        let camera = try CaptureCameraStub()
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        pipeline.onReserve = { camera.diagnosticGeneration += 1 }
        await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        XCTAssertEqual(coordinator.error, CameraCaptureFailure.interrupted.message)
        XCTAssertTrue(camera.callbacks.isEmpty)
        XCTAssertFalse(coordinator.isShutterBusy)
    }

    func testSlowStorageReleasesShutterBeforeProbeReturnsAndCannotCaptureLater() async throws {
        let camera = try CaptureCameraStub()
        camera.preparationTimeout = 0.05
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        var resumeStorage: CheckedContinuation<Void, Never>?
        pipeline.onReserve = { await withCheckedContinuation { resumeStorage = $0 } }
        let selected = try selection()
        let task = Task { await coordinator.capture(selection: selected, currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {}) }
        let limit = Date().addingTimeInterval(2)
        while coordinator.error == nil, Date() < limit { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(coordinator.error, CameraCaptureFailure.preparationTimedOut.message)
        XCTAssertFalse(coordinator.isShutterBusy)
        XCTAssertFalse(camera.admission.isBusy)
        XCTAssertTrue(pipeline.reserved.isEmpty)
        let resume = try XCTUnwrap(resumeStorage)
        resume.resume()
        await task.value
        XCTAssertTrue(camera.callbacks.isEmpty)
        XCTAssertTrue(pipeline.reserved.isEmpty)
    }

    func testDeadlineCancelsWaitingNativeInvocationButPreservesIssuedCapture() async throws {
        for issued in [false, true] {
            let camera = try CaptureCameraStub()
            camera.preparationTimeout = 0.3
            camera.automaticallyIssuesCapture = issued
            let pipeline = CapturePipelineStub()
            let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
            await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
                isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
            let callbacks = try XCTUnwrap(camera.callbacks.first)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(coordinator.isShutterBusy, issued)
            XCTAssertEqual(camera.admission.isBusy, issued)
            if issued {
                XCTAssertNil(coordinator.error)
                await callbacks.still(CaptureStill(imageData: Data([1]), pendingLivePhotoMovieURL: nil))
                callbacks.ready()
                callbacks.result(.success(CaptureResult(imageData: Data([1]), livePhotoMovieURL: nil, photoDisplayTime: .invalid)))
                XCTAssertEqual(pipeline.completed.count, 1)
            } else {
                XCTAssertEqual(coordinator.error, CameraCaptureFailure.preparationTimedOut.message)
                camera.callbacks[0].ready()
                camera.callbacks[0].result(.failure(.interrupted))
                XCTAssertEqual(coordinator.error, CameraCaptureFailure.preparationTimedOut.message,
                    "A late callback must not overwrite the timeout or resurrect the capture")
                XCTAssertTrue(pipeline.completed.isEmpty)
            }
            camera.callbacks.removeAll()
        }
    }

    func testSlowCaptureShowsProgressAndCheckpointReleaseClearsIt() async throws {
        let camera = try CaptureCameraStub()
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        XCTAssertFalse(coordinator.showsCaptureProgress)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(coordinator.showsCaptureProgress)
        camera.callbacks[0].ready()
        XCTAssertFalse(coordinator.showsCaptureProgress)
        camera.callbacks.removeAll()
    }

    private func selection(live: Bool = false, lutKey: String = "film") throws -> CameraCaptureSelection {
        let text = "LUT_3D_SIZE 2\n" + (0...1).flatMap { b in
            (0...1).flatMap { g in (0...1).map { r in "\(r) \(g) \(b)" } }
        }.joined(separator: "\n")
        let source = FilmSource.preset(.fujiC200)
        return CameraCaptureSelection(source: source, lutKey: lutKey, lut: try CubeLUT.parse(text),
            profile: source.captureRenderProfile, adjustment: nil, plan: .resolve(mode: live ? .livePhoto : .quality),
            curveFields: "curve=original", colorFields: "temperature=auto")
    }

    func testColorAdjustmentWaitsForTheSelectedLUTAndItsRenderedFrameBeforeCapture() async throws {
        let camera = try CaptureCameraStub()
        defer { camera.callbacks.removeAll() }
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        var accepted = 0
        camera.entryPreparation.updateLUT(expectedKey: "warm-film", preparedKey: "film")
        await coordinator.capture(selection: try selection(), currentLookKey: { "warm-film" },
            isSceneActive: { true }, onAccepted: { accepted += 1 }, onWillCapture: {})
        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(pipeline.reserved.isEmpty)
        XCTAssertTrue(camera.callbacks.isEmpty)

        camera.entryPreparation.updateLUT(expectedKey: "warm-film", preparedKey: "warm-film")
        let selected = try selection(lutKey: "warm-film")
        await coordinator.capture(selection: selected, currentLookKey: { "warm-film" },
            isSceneActive: { true }, onAccepted: { accepted += 1 }, onWillCapture: {})
        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(pipeline.reserved.isEmpty)
        XCTAssertTrue(camera.callbacks.isEmpty)

        camera.entryPreparation.rendered(generation: 1, lutKey: "warm-film", capturedAt: 2)
        await coordinator.capture(selection: selected, currentLookKey: { "warm-film" },
            isSceneActive: { true }, onAccepted: { accepted += 1 }, onWillCapture: {})
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(camera.callbacks.count, 1)
        camera.callbacks.first?.ready()
    }

    func testChangedLookDuringStorageReservationCancelsBeforeExposure() async throws {
        let camera = try CaptureCameraStub()
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        var key = "film"
        pipeline.onReserve = { key = "another" }
        await coordinator.capture(selection: try selection(), currentLookKey: { key },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        XCTAssertTrue(camera.callbacks.isEmpty)
        XCTAssertEqual(pipeline.cancelled.count, 1)
        XCTAssertFalse(camera.admission.isBusy)
        XCTAssertFalse(coordinator.isShutterBusy)
    }

    func testCaptureUsesThePresentedLUTIntensity() async throws {
        let camera = try CaptureCameraStub()
        defer { camera.callbacks.removeAll() }
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        var selected = try selection()
        selected.lutIntensity = CameraCapturePolicy.defaultLUTIntensity
        await coordinator.capture(selection: selected, currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        XCTAssertTrue(camera.callbacks.isEmpty)

        camera.frame?.lutIntensity = 0.88
        await coordinator.capture(selection: selected, currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        let callbacks = try XCTUnwrap(camera.callbacks.first)
        callbacks.exposed()
        XCTAssertEqual(pipeline.preview?.lutIntensity, 0.88)
        callbacks.ready()
    }

    func testBackgroundGenerationChangeRejectsWaitingShutter() async throws {
        let camera = try CaptureCameraStub()
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        pipeline.onReserve = { camera.diagnosticGeneration = 2 }
        await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
            isSceneActive: { false }, onAccepted: {}, onWillCapture: {})
        XCTAssertTrue(camera.callbacks.isEmpty)
        XCTAssertEqual(pipeline.cancelled.count, 1)
        XCTAssertFalse(coordinator.isShutterBusy)
        XCTAssertNil(coordinator.error)
    }

    func testFullStorageReleasesNativeAdmissionWithoutExposure() async throws {
        let camera = try CaptureCameraStub()
        let pipeline = CapturePipelineStub()
        pipeline.hasRoom = false
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        XCTAssertTrue(camera.callbacks.isEmpty)
        XCTAssertFalse(camera.admission.isBusy)
        XCTAssertFalse(coordinator.isShutterBusy)
    }

    func testMissingPreviewReleasesReservationAndOffersRecovery() async throws {
        let camera = try CaptureCameraStub()
        camera.frame = nil
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        XCTAssertTrue(camera.callbacks.isEmpty)
        XCTAssertEqual(pipeline.cancelled.count, 1)
        XCTAssertFalse(coordinator.isShutterBusy)
        XCTAssertNotNil(coordinator.error)
    }

    func testCheckpointAndShutterReleaseDoNotWaitForLiveMovieDelivery() async throws {
        let camera = try CaptureCameraStub()
        defer { camera.callbacks.removeAll() }
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        await coordinator.capture(selection: try selection(live: true), currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        let callbacks = try XCTUnwrap(camera.callbacks.first)
        XCTAssertNil(pipeline.preview)
        callbacks.exposed()
        XCTAssertEqual(pipeline.preview?.id, coordinator.activeShutterID)
        XCTAssertEqual(pipeline.preview?.grainSeed, 42)
        await callbacks.still(CaptureStill(imageData: Data([1]), pendingLivePhotoMovieURL: nil))
        XCTAssertEqual(pipeline.checkpoints.count, 1)
        XCTAssertTrue(coordinator.isShutterBusy)
        callbacks.ready()
        XCTAssertFalse(coordinator.isShutterBusy)
        XCTAssertTrue(pipeline.completed.isEmpty)
        callbacks.result(.success(CaptureResult(imageData: Data([1]), livePhotoMovieURL: nil,
            photoDisplayTime: CMTime(seconds: 1.25, preferredTimescale: 600))))
        let recipe = try XCTUnwrap(pipeline.completed.first)
        XCTAssertEqual(recipe.id, pipeline.checkpoints.first?.id)
        XCTAssertEqual(recipe.photoDisplayTime, 1.25)
        XCTAssertEqual(recipe.grainSeed, 42)
        XCTAssertEqual(recipe.frozenChromaticGain, SIMD3(0.9, 1, 1.1))
        XCTAssertEqual(recipe.filterName, FilmPreset.fujiC200.rawValue)
    }

    func testNativeFinalStillForwardsToPipelineWithCaptureID() async throws {
        let camera = try CaptureCameraStub()
        defer { camera.callbacks.removeAll() }
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        await coordinator.capture(selection: try selection(), currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        let callbacks = try XCTUnwrap(camera.callbacks.first)
        await callbacks.still(CaptureStill(imageData: Data([1]), pendingLivePhotoMovieURL: nil))
        let captureID = try XCTUnwrap(pipeline.checkpoints.first?.id)
        let nativeFinal = Data([7, 7, 7])
        callbacks.finalStill(nativeFinal)
        XCTAssertEqual(pipeline.finalStills.count, 1)
        XCTAssertEqual(pipeline.finalStills.first?.data, nativeFinal)
        XCTAssertEqual(pipeline.finalStills.first?.id, captureID,
            "The late 24 MP final must reach the worker under its durable capture identity")
    }

    func testLateFailureFromPreviousLiveCaptureCannotUnlockNewShutter() async throws {
        let camera = try CaptureCameraStub()
        defer { camera.callbacks.removeAll() }
        let pipeline = CapturePipelineStub()
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        let selected = try selection(live: true)
        await coordinator.capture(selection: selected, currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        camera.callbacks[0].ready()
        await coordinator.capture(selection: selected, currentLookKey: { "film" },
            isSceneActive: { true }, onAccepted: {}, onWillCapture: {})
        XCTAssertEqual(camera.callbacks.count, 2)
        camera.callbacks[0].result(.failure(.imageUnavailable))
        XCTAssertTrue(coordinator.isShutterBusy)
        camera.callbacks[1].ready()
        XCTAssertFalse(coordinator.isShutterBusy)
    }
}
