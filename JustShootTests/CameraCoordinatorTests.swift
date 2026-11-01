import CoreLocation
import CoreMedia
import CoreVideo
import XCTest
@testable import JustShoot

@MainActor
private final class CaptureCameraStub: CameraCaptureControlling {
    struct Callbacks {
        let still: @MainActor (CaptureStill) async -> Void
        let ready: () -> Void
        let result: (CaptureResult?) -> Void
    }
    let diagnostics = DiagnosticTrace(id: "coordinator-test")
    var diagnosticGeneration: UInt64 = 1
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
            exposureBias: 0, flashEnabled: false, rotationAngle: nil)
    }
    func isCaptureAdmissionValid(_ token: CameraCaptureAdmission.Token) -> Bool {
        admission.permits(token, generation: diagnosticGeneration)
    }
    func cancelCaptureAdmission(_ token: CameraCaptureAdmission.Token) { admission.cancel(token) }
    func waitForCapturePreview(lutKey: String, admission: CameraCaptureAdmission.Token) async -> CameraPreviewFrame? { frame }
    func capture(admission token: CameraCaptureAdmission.Token, live: Bool, previewFrame: CameraPreviewFrame,
                 trace: DiagnosticTrace, onWillCapture: @escaping () -> Void,
                 onExposureComplete: @escaping () -> Void, onShutterReady: @escaping () -> Void,
                 onStillCaptured: @escaping @MainActor (CaptureStill) async -> Void,
                 completion: @escaping (CaptureResult?) -> Void) {
        callbacks.append(Callbacks(still: onStillCaptured, ready: {
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

    func reserve(lutBytes: Int, id: UUID) async -> UUID? {
        await onReserve?()
        if hasRoom { reserved.insert(id); return id }
        return nil
    }
    func cancelReservation(_ id: UUID) { reserved.remove(id); cancelled.insert(id) }
    func preparePreview(_ frame: CameraPreviewFrame, recipe: CaptureRecipe, lut: CubeLUT) { preview = recipe }
    func checkpointStill(_ still: CaptureStill, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?) async {
        checkpoints.append(recipe)
    }
    func enqueue(_ result: CaptureResult, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT?) { completed.append(recipe) }
}

@MainActor
final class CameraCoordinatorTests: XCTestCase {
    private func selection(live: Bool = false) throws -> CameraCaptureSelection {
        let text = "LUT_3D_SIZE 2\n" + (0...1).flatMap { b in
            (0...1).flatMap { g in (0...1).map { r in "\(r) \(g) \(b)" } }
        }.joined(separator: "\n")
        let source = FilmSource.preset(.fujiC200)
        return CameraCaptureSelection(source: source, lutKey: "film", lut: try CubeLUT.parse(text),
            profile: source.captureRenderProfile, adjustment: nil, plan: .resolve(mode: live ? .livePhoto : .quality),
            curveFields: "curve=original", colorFields: "temperature=auto")
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
        await callbacks.still(CaptureStill(imageData: Data([1]), pendingLivePhotoMovieURL: nil))
        XCTAssertEqual(pipeline.checkpoints.count, 1)
        XCTAssertTrue(coordinator.isShutterBusy)
        callbacks.ready()
        XCTAssertFalse(coordinator.isShutterBusy)
        XCTAssertTrue(pipeline.completed.isEmpty)
        callbacks.result(CaptureResult(imageData: Data([1]), livePhotoMovieURL: nil,
            photoDisplayTime: CMTime(seconds: 1.25, preferredTimescale: 600)))
        let recipe = try XCTUnwrap(pipeline.completed.first)
        XCTAssertEqual(recipe.id, pipeline.checkpoints.first?.id)
        XCTAssertEqual(recipe.photoDisplayTime, 1.25)
        XCTAssertEqual(recipe.grainSeed, 42)
        XCTAssertEqual(recipe.frozenChromaticGain, SIMD3(0.9, 1, 1.1))
        XCTAssertEqual(recipe.filterName, FilmPreset.fujiC200.rawValue)
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
        camera.callbacks[0].result(nil)
        XCTAssertTrue(coordinator.isShutterBusy)
        camera.callbacks[1].ready()
        XCTAssertFalse(coordinator.isShutterBusy)
    }
}
