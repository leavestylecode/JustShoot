import XCTest
import SwiftData
import SwiftUI
import CoreImage
import ImageIO
import AVFoundation
@preconcurrency import Photos
@testable import JustShoot

/// Explicitly opt in on a connected, unlocked device. Configuration checks take no
/// photos; framing checks retain temporary attachments without a Photos import.
/// Only testRealCaptureThroughDurablePipelineAndPhotos imports assets into Photos.
/// Ordinary test runs never capture. Use a stationary, textured subject for framing.
final class PhysicalCameraPipelineTests: XCTestCase {
    /// Opt-in same-scene framing evidence. Keeps test attachments, never Photos assets.
    @MainActor
    func testLivePhotoShutterFramingWithoutSavingToPhotos() async throws {
        guard ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_LIVE_FRAMING"] == "1" else {
            throw XCTSkip("Fix the phone on a textured subject and opt in to framing capture")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical device required")
        #else
        if ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_AUDIO"] == "1" {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw XCTSkip("Microphone permission is required for audio validation") }
        }
        let camera = CameraManager()
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { camera.stopSession(); UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        let source = FilmSource.preset(.fujiProvia100F)
        let lut = try await FilmCapturePreparation.shared.displayLUT(source: source, curve: .builtIn(.none))
        let key = "live-framing-validation"
        try await PreviewMetalResources.warmUpForRenderer()
        let texture = try await PreviewLUTTextureCache.shared.prepare(key: key, lut: lut)
        let scene = try await TestWindowScene.foreground()
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ValidationViewfinder(camera: camera,
            key: key, texture: texture, profile: source.captureRenderProfile))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        camera.setEntrySceneActive(true)
        camera.updateEntryPipelineReady(true)
        camera.updateEntryLUT(expectedKey: key, preparedKey: key)
        camera.setLivePhotoAudio(live: false, sound: false)
        camera.requestCameraPermission()
        var deadline = Date().addingTimeInterval(30)
        while camera.capturePreview(lutKey: key) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, .portrait)
        XCTAssertEqual(camera.previewInterfaceOrientation, .portrait)
        XCTAssertEqual(camera.controlsOrientation, camera.currentDeviceOrientation)
        let selectedFocals = ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_FOCALS"]?
            .split(separator: ",").compactMap { Int($0) }
        var focals = camera.focalInfo.options.filter { selectedFocals?.contains($0.value) ?? true }
            .sorted { abs($0.value - 35) < abs($1.value - 35) }
        let waitForRotation = ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_WAIT_FOR_ROTATION"] == "1"
        let requestedOrientations = Set(ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_ORIENTATIONS"]?
            .split(separator: ",").compactMap { Int($0) } ?? [1, 2, 3, 4])
        var observedOrientations = Set<Int>()
        if waitForRotation {
            guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Physical iPad rotation required") }
            XCTAssertFalse(requestedOrientations.isEmpty)
            XCTAssertTrue(requestedOrientations.isSubset(of: [1, 2, 3, 4]))
            focals = Array(repeating: try XCTUnwrap(focals.first), count: requestedOrientations.count)
        }
        var completedFocals = 0
        while completedFocals < focals.count {
            let focal = focals[completedFocals]
            var expectedOrientation: UIDeviceOrientation?
            if waitForRotation {
                // Observe physical holding while the interface stays portrait.
                // Never override the user's system rotation-lock setting.
                deadline = Date().addingTimeInterval(300)
                while (!requestedOrientations.contains(camera.currentDeviceOrientation.rawValue)
                       || observedOrientations.contains(camera.currentDeviceOrientation.rawValue)), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let orientation = camera.currentDeviceOrientation
                guard requestedOrientations.contains(orientation.rawValue), !observedOrientations.contains(orientation.rawValue) else {
                    throw XCTSkip("No new physical holding orientation observed within five minutes")
                }
                XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, .portrait)
                XCTAssertEqual(camera.previewInterfaceOrientation, .portrait)
                expectedOrientation = orientation
            }
            camera.setLivePhotoAudio(live: false, sound: false)
            camera.setFocalLength(focal, animated: false)
            deadline = Date().addingTimeInterval(20)
            while camera.capturePreview(lutKey: key) == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            camera.setFocusAndExposure(normalizedPoint: CGPoint(x: 0.2, y: 0.5))
            try await Task.sleep(for: .seconds(1))
            let ordinaryFrame = try XCTUnwrap(camera.capturePreview(lutKey: key))
            camera.setLivePhotoAudio(live: true, sound: ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_AUDIO"] == "1")
            deadline = Date().addingTimeInterval(20)
            while (!camera.livePhotoCaptureState.canCapture || camera.capturePreview(lutKey: key) == nil), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(camera.livePhotoCaptureState.canCapture)
            try await Task.sleep(for: .seconds(1))
            if let expectedOrientation {
                // Mode setup can span a physical turn. Retry that pose rather than
                // counting an orientation that was never actually photographed.
                guard camera.currentDeviceOrientation == expectedOrientation else { continue }
                XCTAssertEqual(camera.controlsOrientation, expectedOrientation)
                XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, .portrait)
            }
            let captureOrientation = camera.previewInterfaceOrientation
            let captureDeviceOrientation = camera.currentDeviceOrientation
            let evidencePrefix = "\(focal.value)mm-window-\(captureOrientation.rawValue)-device-\(captureDeviceOrientation.rawValue)"
            let admission = try XCTUnwrap(camera.beginCaptureAdmission())
            let presentedFrame = await camera.waitForCapturePreview(lutKey: key, admission: admission)
            let frame = try XCTUnwrap(presentedFrame)
            XCTAssertEqual(frame.rotation, CameraOrientationPolicy.previewRotation(for: camera.previewInterfaceOrientation))
            // When the interface follows the physical device, the preview and native
            // capture must agree on upright orientation, not just agree with our policy.
            if camera.controlsOrientation == .portrait, let captureAngle = admission.rotationAngle {
                let nativeRotation = UInt32((Int((captureAngle / 90).rounded()) % 4 + 4) % 4)
                XCTAssertEqual(frame.rotation, nativeRotation, "Window and native camera disagree on upright")
            }
            XCTAssertEqual(frame.outputSize.width / frame.outputSize.height, camera.previewAspectRatio, accuracy: 0.01)
            if waitForRotation {
                let expectedAngle: Double
                switch captureDeviceOrientation {
                case .landscapeLeft: expectedAngle = 0
                case .landscapeRight: expectedAngle = 180
                case .portraitUpsideDown: expectedAngle = 270
                default: expectedAngle = 90
                }
                XCTAssertEqual(try XCTUnwrap(admission.rotationAngle), expectedAngle, accuracy: 0.01)
            }
            print("live_window_rotation interface=\(camera.previewInterfaceOrientation.rawValue) device=\(captureDeviceOrientation.rawValue) controls=\(camera.controlsOrientation.rawValue) native_deg=\(admission.rotationAngle ?? -1) \(frame.framingDiagnosticFields)")
            let result: Result<CaptureResult, CameraCaptureFailure> = await withCheckedContinuation { continuation in
                camera.capturePhoto(admission: admission, live: true, previewFrame: frame) {
                    continuation.resume(returning: $0)
                }
            }
            let captured = try result.get()
            let movie = try XCTUnwrap(captured.livePhotoMovieURL)
            defer { try? FileManager.default.removeItem(at: movie) }
            if let expectedOrientation {
                guard camera.currentDeviceOrientation == expectedOrientation else { continue }
                XCTAssertEqual(camera.previewInterfaceOrientation, .portrait)
                XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, .portrait)
                observedOrientations.insert(captureDeviceOrientation.rawValue)
            }
            XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? Int) ?? 0, 0)
            if focal.value == 35 {
                try await verifyLivePairWithoutSaving(captured, lut: lut)
            }
            let stats = camera.livePhotoBufferStatistics
            XCTAssertLessThanOrEqual(stats.maximumPendingFrames, 2)
            print("live_buffer_probe focal_mm=\(focal.value) encoded=\(stats.encodedFrames) dropped=\(stats.droppedFrames) max_pending=\(stats.maximumPendingFrames) max_encode_ms=\(stats.maximumEncodeMilliseconds)")
            let diagnostics = try await Task.detached {
                let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace, .cacheIntermediates: false])
                let photo = try XCTUnwrap(CIImage(data: captured.imageData, options: [.applyOrientationProperty: true]))
                let scale = 1200 / max(photo.extent.width, photo.extent.height)
                let scaledPhoto = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let preview = frame.inputImage(maximumPixel: 1200)
                let ordinary = ordinaryFrame.inputImage(maximumPixel: 1200)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
                generator.appliesPreferredTrackTransform = true
                let videoImage = try await generator.image(at: captured.photoDisplayTime).image
                let video = CIImage(cgImage: videoImage)
                let videoScale = 1200 / max(video.extent.width, video.extent.height)
                var result: [(String, Data)] = []
                for (name, image) in [("ordinary-preview", ordinary), ("live-shutter-preview", preview), ("live-native-still", scaledPhoto),
                                      ("live-video-frame", video.transformed(by: CGAffineTransform(scaleX: videoScale, y: videoScale)))] {
                    let png = try XCTUnwrap(context.pngRepresentation(of: image, format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace))
                    result.append((name, png))
                }
                print("live_framing_preview focal_mm=\(focal.value) \(frame.framingDiagnosticFields)")
                print("live_framing_native focal_mm=\(focal.value) \(CameraPhotoDiagnostics.fields(imageData: captured.imageData, resolvedDimensions: .init(width: 0, height: 0)))")
                return result
            }.value
            for (name, png) in diagnostics {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "\(evidencePrefix)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            completedFocals += 1
            if ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_SKIP_ROUNDTRIP"] == "1" { continue }
            // Distinguish a mode-switch initialization error from steady-state proxy zoom.
            let alternate = camera.focalInfo.options.first { $0 != focal } ?? focal
            for target in [alternate, focal] {
                camera.setFocalLength(target, animated: false)
                deadline = Date().addingTimeInterval(20)
                while camera.capturePreview(lutKey: key) == nil, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            let returnedFrame = try XCTUnwrap(camera.capturePreview(lutKey: key))
            print("live_framing_returned focal_mm=\(focal.value) \(returnedFrame.framingDiagnosticFields)")
            let returnedPNG = try await Task.detached {
                let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace, .cacheIntermediates: false])
                return try XCTUnwrap(context.pngRepresentation(of: returnedFrame.inputImage(maximumPixel: 1200),
                    format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace))
            }.value
            let returnedAttachment = XCTAttachment(data: returnedPNG, uniformTypeIdentifier: "public.png")
            returnedAttachment.name = "\(evidencePrefix)-live-after-zoom-roundtrip"
            returnedAttachment.lifetime = .keepAlways
            add(returnedAttachment)
        }
        if waitForRotation { XCTAssertEqual(observedOrientations, requestedOrientations) }
        if ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_CHECK_LIFECYCLE"] == "1" {
            try await verifyOverlappingCapturesAndImmediateClose(camera, key: key, lut: lut)
        }
        #endif
    }

    @MainActor
    private func verifyOverlappingCapturesAndImmediateClose(_ camera: CameraManager, key: String, lut: CubeLUT) async throws {
        let released = AsyncStream<Void>.makeStream()
        let firstAdmission = try XCTUnwrap(camera.beginCaptureAdmission())
        let firstPreview = await camera.waitForCapturePreview(lutKey: key, admission: firstAdmission)
        let firstFrame = try XCTUnwrap(firstPreview)
        let first = Task { @MainActor in
            await withCheckedContinuation { continuation in
                camera.capturePhoto(admission: firstAdmission, live: true, previewFrame: firstFrame,
                    onShutterReady: { released.continuation.yield(()); released.continuation.finish() }) {
                        continuation.resume(returning: $0)
                    }
            }
        }
        for await _ in released.stream { break }
        let deadline = Date().addingTimeInterval(5)
        while !camera.isReadyToCapture, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        let secondAdmission = try XCTUnwrap(camera.beginCaptureAdmission())
        let secondPreview = await camera.waitForCapturePreview(lutKey: key, admission: secondAdmission)
        let secondFrame = try XCTUnwrap(secondPreview)
        let second = Task { @MainActor in
            await withCheckedContinuation { continuation in
                camera.capturePhoto(admission: secondAdmission, live: true, previewFrame: secondFrame) {
                    continuation.resume(returning: $0)
                }
            }
        }
        let firstValue = await first.value
        let secondValue = await second.value
        let results = [try firstValue.get(), try secondValue.get()]
        let firstURL = try XCTUnwrap(results[0].livePhotoMovieURL)
        let secondURL = try XCTUnwrap(results[1].livePhotoMovieURL)
        defer { try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: secondURL) }
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertNil(results[0].warning)
        XCTAssertNil(results[1].warning)
        let closing = AsyncStream<Void>.makeStream()
        let closeAdmission = try XCTUnwrap(camera.beginCaptureAdmission())
        let closePreview = await camera.waitForCapturePreview(lutKey: key, admission: closeAdmission)
        let closeFrame = try XCTUnwrap(closePreview)
        let closeResult = Task { @MainActor in
            await withCheckedContinuation { continuation in
                camera.capturePhoto(admission: closeAdmission, live: true, previewFrame: closeFrame,
                    onShutterReady: { closing.continuation.yield(()); closing.continuation.finish() }) {
                        continuation.resume(returning: $0)
                    }
            }
        }
        for await _ in closing.stream { break }
        camera.stopSession()
        let closedValue = await closeResult.value
        let closed = try closedValue.get()
        let closedURL = try XCTUnwrap(closed.livePhotoMovieURL)
        defer { try? FileManager.default.removeItem(at: closedURL) }
        XCTAssertNil(closed.warning)
        try await verifyLivePairWithoutSaving(closed, lut: lut)
        print("live_lifecycle_probe overlapping=true close_pair_playable=true")
    }

    /// Runs the existing production grade/pairing stages without importing anything into Photos.
    @MainActor
    private func verifyLivePairWithoutSaving(_ captured: CaptureResult, lut: CubeLUT) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-pair-validation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(captured.livePhotoMovieURL)
        let movie = root.appendingPathComponent("paired.mov")
        let photo = root.appendingPathComponent("paired.heic")
        let bytes = try await Task.detached {
            let result = try await LivePhotoProcessor.process(sourceURL: source,
                lutCacheKey: "live-framing-validation", capturedLUT: lut, grain: .disabled,
                grainBaseSeed: 1, photoDisplayTime: captured.photoDisplayTime, outputURL: movie)
            return try XCTUnwrap(FilmProcessor.shared.applyLUTPreservingMetadata(imageData: captured.imageData,
                lutCacheKey: "live-framing-validation", capturedLUT: lut,
                contentIdentifier: result.contentIdentifier))
        }.value
        try bytes.write(to: photo)
        let canPlay: Bool = await withCheckedContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [photo, movie], placeholderImage: nil,
                targetSize: CGSize(width: 240, height: 320), contentMode: .aspectFit) { live, info in
                    guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true else { return }
                    print("live_pair_probe playable=\(live != nil) error=\(String(describing: info[PHLivePhotoInfoErrorKey]))")
                    continuation.resume(returning: live != nil)
                }
        }
        XCTAssertTrue(canPlay, "The graded resources must load as a Live Photo without a Photos import")
        let tracks = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        let wantsAudio = ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_AUDIO"] == "1"
        XCTAssertEqual(tracks.count, wantsAudio ? 1 : 0)
    }

    /// Exercises production cold-start and mode switching without taking photos.
    @MainActor
    func testLivePhotoPreviewConfigurationSurvivesColdStartAndRoundTrips() async throws {
        guard ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_CAMERA_CONFIGURATION"] == "1" else {
            throw XCTSkip("Set JUSTSHOOT_VALIDATE_CAMERA_CONFIGURATION=1 on a physical device")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A physical camera is required")
        #else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("Camera permission must already be authorized")
        }
        for startsLive in [false, true] {
            let camera = CameraManager()
            defer { camera.stopSession() }
            camera.setEntrySceneActive(true)
            camera.setLivePhotoAudio(live: startsLive, sound: false)
            camera.requestCameraPermission()
            for live in [startsLive, !startsLive, startsLive] {
                camera.setLivePhotoAudio(live: live, sound: false)
                let deadline = Date().addingTimeInterval(20)
                var configured = false
                while Date() < deadline {
                    if camera.isCaptureAvailable,
                       let video = camera.session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first,
                       !video.automaticallyConfiguresOutputBufferDimensions,
                       !live || camera.livePhotoCaptureState.canCapture {
                        configured = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(configured, "cold_live=\(startsLive) requested_live=\(live) state=\(camera.livePhotoCaptureState)")
                let video = try XCTUnwrap(camera.session.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }.first)
                XCTAssertFalse(video.deliversPreviewSizedOutputBuffers)
                XCTAssertFalse(live && camera.usesDeferredPhotoDelivery)
                if live { XCTAssertTrue(camera.livePhotoCaptureState.canCapture) }
                print("configuration_probe cold_live=\(startsLive) requested_live=\(live) proxy=\(video.deliversPreviewSizedOutputBuffers) live=\(camera.livePhotoCaptureState.canCapture)")
            }
            camera.stopSession()
        }
        #endif
    }

    @MainActor
    func testRealCaptureThroughDurablePipelineAndPhotos() async throws {
        guard ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_CAMERA"] == "1" else {
            throw XCTSkip("Set JUSTSHOOT_VALIDATE_CAMERA=1 on a physical device")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A physical camera is required")
        #else
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-validation-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let schema = Schema([Photo.self, CustomLUT.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let pipeline = CapturePipeline(journal: journal)
        await pipeline.configure(container: container)
        let camera = CameraManager()
        defer { camera.stopSession() }
        let preview = try await FilmCapturePreparation.shared.displayLUT(source: .preset(.fujiProvia100F), curve: .builtIn(.none))
        let renderContext = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace, .cacheIntermediates: false])
        try await PreviewMetalResources.warmUpForRenderer()
        let previewKey = "physical-validation-entry"
        let initialTexture = try await PreviewLUTTextureCache.shared.prepare(key: previewKey, lut: preview)
        let scene = try await TestWindowScene.foreground()
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ValidationViewfinder(camera: camera, key: previewKey,
            texture: initialTexture, profile: FilmSource.preset(.fujiProvia100F).captureRenderProfile))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }
        camera.setEntrySceneActive(true)
        camera.updateEntryPipelineReady(pipeline.isPrepared)
        camera.updateEntryLUT(expectedKey: previewKey, preparedKey: previewKey)
        camera.setLivePhotoAudio(live: false, sound: false)
        camera.requestCameraPermission()
        let entryDeadline = Date().addingTimeInterval(45)
        while !camera.entryPreparation.isRevealed && Date() < entryDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(camera.entryPreparation.isRevealed,
            "entry=\(camera.entryPreparation.phase) pending=\(camera.entryPreparation.pendingRequirements)")
        let format = camera.rawCaptureFormat

        // Exercise the real import normalizer and persisted index, then shoot with it.
        let customID = UUID()
        let customName = "validation-\(customID).jslut"
        let customURL = CustomLUT.storageDirectory.appendingPathComponent(customName)
        defer { try? FileManager.default.removeItem(at: customURL) }
        let imported = try await LUTImportPreparation.shared.read(try XCTUnwrap(Bundle.main.url(forResource: "KodakPortra400", withExtension: "cube")))
        let dimension = try await LUTImportPreparation.shared.save(imported, encoding: .rec709Gamma24, to: customURL)
        let custom = CustomLUT(displayName: "Imported Rec709 validation", fileName: customName, iso: 400, dimension: dimension)
        container.mainContext.insert(custom)
        try container.mainContext.save()
        let customSource = FilmSource.from(custom)
        let initialFocal = camera.currentFocalLength
        let captures: [(FocalLengthOption, FilmSource, PhotoCaptureMode)] = camera.focalInfo.options.map {
            ($0, .preset(.fujiProvia100F), .quality)
        } + [(initialFocal, .preset(.kodakPortra400), .quality),
            (initialFocal, customSource, .quality), (initialFocal, customSource, .livePhoto)]
        for (focal, source, mode) in captures {
            camera.setFocalLength(focal, animated: false)
            let reading = camera.automaticWhiteBalanceReading ?? .neutral
            let cube = try await ColorTemperatureLUT.shared.prepare(source: source, curve: .builtIn(.none),
                selection: .temperature(5_100), tint: .value(8), reference: reading)
            let key = "physical-validation-\(UUID().uuidString)"
            let texture = try await PreviewLUTTextureCache.shared.prepare(key: key, lut: cube)
            camera.updateEntryLUT(expectedKey: key, preparedKey: key)
            host.rootView = ValidationViewfinder(camera: camera, key: key, texture: texture,
                profile: source.captureRenderProfile)
            camera.setLivePhotoAudio(live: mode == .livePhoto, sound: false)
            let modeDeadline = Date().addingTimeInterval(10)
            while !camera.isReadyToCapture && Date() < modeDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let native24MP = camera.usesDeferredPhotoDelivery
            let plan = PhotoCapturePlan.resolve(mode: mode)
            if plan.capturesLivePhoto {
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertTrue(camera.livePhotoCaptureState.canCapture)
            }
            let rawLUT: RawFilmLUT? = nil
            let rawRecipe = plan.capturesRAW ? RawCaptureRecipe(unifiedLUT: cube) : nil
            XCTAssertEqual(plan.version, 2)
            XCTAssertEqual(plan.inputSpace, .displaySRGB)
            let renderDeadline = Date().addingTimeInterval(15)
            while (!camera.entryPreparation.isCurrentLookRendered || camera.capturePreview(lutKey: key) == nil),
                  Date() < renderDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(camera.entryPreparation.isCurrentLookRendered, "The real Metal view must present the selected look")
            let admission = try XCTUnwrap(camera.beginCaptureAdmission())
            let presentedFrame = await camera.waitForCapturePreview(lutKey: key, admission: admission)
            let previewFrame = try XCTUnwrap(presentedFrame)
            if !plan.capturesLivePhoto {
                XCTAssertLessThanOrEqual(max(CVPixelBufferGetWidth(previewFrame.buffer), CVPixelBufferGetHeight(previewFrame.buffer)),
                    Int(CameraPerformancePolicy.maximumCaptureBufferLongEdge))
                XCTAssertEqual(previewFrame.crop, 1, "Scaled video must not receive the proxy's extra digital zoom")
            }
            let reservation = await pipeline.reserve(lutBytes: cube.data.count + (rawLUT?.data.count ?? 0))
            let id = try XCTUnwrap(reservation)
            let recipe = CaptureRecipe(id: id, captureDate: Date(), filterName: source.photoFilterName,
                displayLabel: nil, focalLength: admission.focalLength, outputQuality: nil, profile: source.captureRenderProfile,
                grainSeed: previewFrame.grainSeed, location: nil, lutDimension: cube.dimension, chromaticSceneCCT: nil,
                photoDisplayTime: nil, raw: rawRecipe, plan: plan,
                colorAdjustment: ResolvedCameraColorAdjustment.resolve(temperature: .temperature(5_100),
                    tint: .value(8), reading: reading), frozenChromaticGain: previewFrame.chromaticGain)
            let previewImage = await CapturePreviewRenderer.image(frame: previewFrame, lut: cube, recipe: recipe)
            let renderedPreview = try XCTUnwrap(previewImage)
            let previewAttachment = XCTAttachment(image: renderedPreview)
            previewAttachment.name = "viewfinder-\(focal.rawValue)mm-\(source.photoFilterName)-\(plan.format.rawValue)"
            previewAttachment.lifetime = .keepAlways
            add(previewAttachment)
            pipeline.preparePreview(previewFrame, recipe: recipe, lut: cube)
            let start = ProcessInfo.processInfo.systemUptime
            let result: Result<CaptureResult, CameraCaptureFailure> = await withCheckedContinuation { continuation in
                camera.capturePhoto(admission: admission, live: plan.capturesLivePhoto, raw: plan.capturesRAW,
                    expectedRAWFormat: plan.capturesRAW ? format : nil, previewFrame: previewFrame, onStillCaptured: { still in
                    await pipeline.checkpointStill(still, recipe: recipe, lut: cube, rawLUT: rawLUT)
                }) { continuation.resume(returning: $0) }
            }
            let captured = try result.get()
            let deliveryMs = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            let original = try XCTUnwrap(CGImageSourceCreateWithData(captured.imageData as CFData, nil))
            XCTAssertEqual(RawFilmRenderer.isDNG(original), plan.capturesRAW)
            XCTAssertEqual(captured.livePhotoMovieURL != nil, plan.capturesLivePhoto)
            if plan.capturesRAW, source == .preset(.fujiProvia100F),
               ProcessInfo.processInfo.environment["JUSTSHOOT_RAW_DIAGNOSTICS"] == "1" {
                try await attachUnifiedDiagnostics(captured.imageData)
            }
            let props = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [String: Any]
            if native24MP, mode == .quality, let deferred = captured.deferredPhoto {
                XCTAssertFalse(plan.capturesRAW)
                XCTAssertGreaterThan(deferred.width * deferred.height, 20_000_000)
            }
            let model = (props?[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFModel as String]
            let completedRecipe = recipe.withPhotoDisplayTime(captured.photoDisplayTime.isValid && captured.photoDisplayTime.isNumeric
                ? captured.photoDisplayTime.seconds : nil)
            pipeline.enqueue(captured, recipe: completedRecipe, lut: cube, rawLUT: rawLUT)
            let saveDeadline = Date().addingTimeInterval(60)
            while pipeline.lastCompletion?.id != id && Date() < saveDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(pipeline.lastCompletion?.id, id, pipeline.lastError ?? "No completion")
            let context = ModelContext(container)
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<Photo>()).first { $0.id == id })
            let assetID = try XCTUnwrap(row.assetLocalIdentifier)
            let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
            XCTAssertEqual(asset.mediaSubtypes.contains(.photoLive), plan.capturesLivePhoto)
            XCTAssertGreaterThan(asset.pixelWidth * asset.pixelHeight, 10_000_000)
            if let deferred = captured.deferredPhoto {
                XCTAssertEqual(asset.pixelWidth * asset.pixelHeight, deferred.width * deferred.height)
            }
            let imageData: Data? = await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.version = .current
                options.isNetworkAccessAllowed = false
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }
            let output = try XCTUnwrap(imageData)
            let outputSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            let outputProps = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [String: Any])
            XCTAssertEqual(outputProps[kCGImagePropertyProfileName as String] as? String, "sRGB IEC61966-2.1")
            XCTAssertEqual(outputProps[kCGImagePropertyOrientation as String] as? Int, 1)
            XCTAssertNil(outputProps[kCGImagePropertyDNGDictionary as String])
            XCTAssertTrue(try journal.jobs().isEmpty)
            let attachment = XCTAttachment(data: output, uniformTypeIdentifier: CGImageSourceGetType(outputSource)! as String)
            attachment.name = "\(focal.rawValue)mm-\(source.photoFilterName)-\(plan.format.rawValue)-sRGB"
            attachment.lifetime = .keepAlways
            add(attachment)
            let libraryImage = try XCTUnwrap(FilmImagePipeline.decodePhoto(output, applyOrientation: true))
            let comparison = ["preview": CaptureComparisonDiagnostics.statistics(
                CIImage(cgImage: try XCTUnwrap(renderedPreview.cgImage)), context: renderContext),
                "library": CaptureComparisonDiagnostics.statistics(libraryImage, context: renderContext)]
            let metrics = XCTAttachment(data: try JSONEncoder().encode(comparison), uniformTypeIdentifier: "public.json")
            metrics.name = "paired-brightness-color-\(focal.rawValue)mm-\(source.photoFilterName)-\(plan.format.rawValue)"
            metrics.lifetime = .keepAlways
            add(metrics)
            print("physical_capture_validated model=\(model ?? "unknown") os=\(UIDevice.current.systemVersion) focal_mm=\(focal.rawValue) preview_crop=\(previewFrame.crop) frame_id=\(previewFrame.frameID) source_revision=\(previewFrame.sourceRevision) film=\(source.photoFilterName) format=\(plan.format.rawValue) input=\(plan.inputSpace.rawValue) raw_bytes=\(captured.imageData.count) output_bytes=\(output.count) size=\(asset.pixelWidth)x\(asset.pixelHeight) delivery_ms=\(Int(deliveryMs)) total_ms=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1_000))")
        }
        #endif
    }

    /// Replay one native exposure through every built-in look at full resolution.
    /// Render work stays off MainActor while the physical camera continues streaming.
    @MainActor
    private func attachUnifiedDiagnostics(_ data: Data) async throws {
        let original = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.raw-image")
        original.name = "unified-original-proraw"
        original.lifetime = .keepAlways
        add(original)
        for preset in FilmPreset.allCases {
            let cube = try await FilmCapturePreparation.shared.displayLUT(source: .preset(preset), curve: .builtIn(.none))
            let result = try await Task.detached(priority: .userInitiated) {
                try autoreleasepool {
                    let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace,
                        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
                    let recipe = RawCaptureRecipe(unifiedLUT: cube)
                    let decoder = try XCTUnwrap(CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image"))
                    let baseline = decoder.baselineExposure, boost = decoder.boostAmount, local = decoder.localToneMapAmount
                    RawFilmRenderer.configure(decoder, recipe: recipe)
                    XCTAssertEqual(decoder.baselineExposure, baseline)
                    XCTAssertEqual(decoder.boostAmount, boost)
                    XCTAssertEqual(decoder.localToneMapAmount, local)
                    let capture = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: preset.rawValue,
                        displayLabel: nil, focalLength: 35, outputQuality: nil,
                        profile: FilmSource.preset(preset).captureRenderProfile, grainSeed: 1,
                        location: nil, lutDimension: cube.dimension, chromaticSceneCCT: nil,
                        photoDisplayTime: nil, raw: recipe,
                        plan: PhotoCapturePlan(version: 2, format: .appleProRAW, inputSpace: .displaySRGB, approximateLook: false))
                    let encoded = try XCTUnwrap(CapturePhotoRenderer.render(source: data, recipe: capture,
                        lut: cube, rawLUT: nil, grainSeed: 1))
                    let image = try XCTUnwrap(CIImage(data: encoded))
                    let scale = 512 / max(image.extent.width, image.extent.height)
                    let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    let png = try XCTUnwrap(context.pngRepresentation(of: small, format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace))
                    let width = Int(small.extent.width), height = Int(small.extent.height)
                    var pixels = [Float](repeating: 0, count: width * height * 4)
                    context.render(small, toBitmap: &pixels, rowBytes: width * 16,
                        bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                        colorSpace: FilmImagePipeline.colorSpace)
                    let luma = stride(from: 0, to: pixels.count, by: 4).map {
                        pixels[$0] * 0.2126 + pixels[$0 + 1] * 0.7152 + pixels[$0 + 2] * 0.0722
                    }.sorted()
                    XCTAssertTrue(luma.allSatisfy(\.isFinite))
                    print("unified_look_validated film=\(preset.rawValue) baseline=\(baseline) median=\(luma[luma.count / 2]) p90=\(luma[luma.count * 9 / 10]) output_bytes=\(encoded.count)")
                    return png
                }
            }.value
            let attachment = XCTAttachment(data: result, uniformTypeIdentifier: "public.png")
            attachment.name = "unified-sRGB-\(preset.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

private struct ValidationViewfinder: View {
    @ObservedObject var camera: CameraManager
    let key: String
    let texture: PreviewLUTTexture
    let profile: FilmRenderProfile

    var body: some View {
        ZStack {
            CameraPreviewUnderlayView(manager: camera)
            RealtimePreviewView(manager: camera, lutCacheKey: key, preparedLUT: texture,
                grain: profile.grain, optics: profile.optics, chromatic: profile.effectiveChromatic)
        }
            .aspectRatio(camera.previewAspectRatio, contentMode: .fit)
            .background(.black)
    }
}
