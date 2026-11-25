import XCTest
import SwiftData
import SwiftUI
import CoreImage
import CoreLocation
import ImageIO
import AVFoundation
@preconcurrency import Photos
@testable import JustShoot

/// Explicitly opt in on a connected, unlocked device. Configuration checks take no
/// photos; framing checks retain temporary attachments without a Photos import.
/// Delivery and process-recovery checks explicitly opt in to importing assets into Photos.
/// Ordinary test runs never capture. Use a stationary, textured subject for framing.
final class PhysicalCameraPipelineTests: XCTestCase {
    @MainActor
    func testHDRShutterRendersProRAWWithoutSavingToPhotos() async throws {
        guard ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_HDR_CAPTURE"] == "1" else {
            throw XCTSkip("Enable HDR capture validation on a physical device")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A physical camera is required")
        #else
        try XCTSkipUnless(PhotoCaptureMode.supportsHDR, "HDR capture requires iOS 18")
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            "Camera permission must already be authorized")
        let camera = CameraManager()
        defer { camera.stopSession() }
        let source = FilmSource.preset(.fujiProvia100F)
        let lut = try await FilmCapturePreparation.shared.displayLUT(source: source, curve: .builtIn(.none))
        let key = "hdr-capture-validation"
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
        camera.requestCameraPermission()
        let deadline = ContinuousClock.now + .seconds(30)
        while !(camera.entryPreparation.isRevealed && camera.isReadyToCapture), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(camera.isReadyToCapture)
        guard let format = camera.rawCaptureFormat, format.kind == .appleProRAW else {
            throw XCTSkip("An Apple ProRAW camera is required")
        }
        let ordinaryStillUsesDeferredDelivery = camera.usesDeferredPhotoDelivery
        // Configure an output that supports direct still delivery even on 24 MP devices.
        camera.setPhotoCaptureMode(.livePhoto, sound: false)
        let switchDeadline = ContinuousClock.now + .seconds(10)
        while (!camera.isReadyToCapture || camera.usesDeferredPhotoDelivery), ContinuousClock.now < switchDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(camera.usesDeferredPhotoDelivery)
        XCTAssertEqual(camera.directHDRCaptureFormat, format)
        let admission = try XCTUnwrap(camera.beginCaptureAdmission())
        defer { camera.cancelCaptureAdmission(admission) }
        let preview = await camera.waitForCapturePreview(lutKey: key, admission: admission)
        let frame = try XCTUnwrap(preview)
        let result: Result<CaptureResult, CameraCaptureFailure> = await withCheckedContinuation { continuation in
            camera.capturePhoto(admission: admission, raw: true, expectedRAWFormat: format,
                hdr: true, previewFrame: frame) { continuation.resume(returning: $0) }
        }
        let capture = try result.get()
        XCTAssertNil(capture.deferredPhoto)
        let raw = try XCTUnwrap(CGImageSourceCreateWithData(capture.imageData as CFData, nil))
        XCTAssertTrue(RawFilmRenderer.isDNG(raw))
        XCTAssertNil(capture.livePhotoMovieURL)
        let recipe = CaptureRecipe(id: admission.id, captureDate: .now, filterName: source.photoFilterName,
            displayLabel: nil, focalLength: admission.focalLength, outputQuality: nil, profile: source.captureRenderProfile,
            grainSeed: frame.grainSeed, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil,
            photoDisplayTime: nil, raw: RawCaptureRecipe(unifiedLUT: lut), plan: .resolve(mode: .hdr, directHDRAvailable: true),
            frozenChromaticGain: frame.chromaticGain, lutIntensity: frame.lutIntensity)
        let rendered = await Task.detached {
            CapturePhotoRenderer.render(source: capture.imageData, recipe: recipe, lut: lut,
                rawLUT: nil, grainSeed: recipe.grainSeed)
        }.value
        let bytes = try XCTUnwrap(rendered)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(image) as String?, "public.heic")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight as String] as? Int)
        XCTAssertGreaterThan(width * height, 10_000_000)
        XCTAssertLessThanOrEqual(width * height, 12_600_000)
        camera.setPhotoCaptureMode(.quality)
        let restoreDeadline = ContinuousClock.now + .seconds(10)
        while !camera.isReadyToCapture, ContinuousClock.now < restoreDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(camera.isReadyToCapture)
        XCTAssertEqual(camera.usesDeferredPhotoDelivery, ordinaryStillUsesDeferredDelivery)
        #endif
    }

    @MainActor
    func testStationaryCameraKeepsAFreshLocationForTheShutter() async throws {
        guard ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_LOCATION"] == "1" else {
            throw XCTSkip("Enable location validation on a stationary, authorized physical device")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical location updates required")
        #else
        let status = CLLocationManager().authorizationStatus
        try XCTSkipUnless(status == .authorizedWhenInUse || status == .authorizedAlways)
        let provider = CameraLocationProvider { _ in }
        provider.start()
        defer { provider.stop() }
        let deadline = ContinuousClock.now + .seconds(45)
        while provider.location(at: .now) == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        let first = try XCTUnwrap(provider.location(at: .now), "No usable initial location")
        try await Task.sleep(for: .seconds(38))
        let latest = try XCTUnwrap(provider.location(at: .now), "Location expired while the camera was stationary")
        XCTAssertGreaterThan(latest.timestamp, first.timestamp)
        #endif
    }

    /// Opt-in same-scene framing evidence. Keeps test attachments, never Photos assets.
    @MainActor
    func testLivePhotoShutterFramingWithoutSavingToPhotos() async throws {
        guard ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_LIVE_FRAMING"] == "1" else {
            throw XCTSkip("Fix the phone on a textured subject and opt in to framing capture")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical device required")
        #else
        try XCTSkipUnless(LivePhotoEncoderConfiguration.isSupported, "Live Photo capture requires iOS 18")
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
        camera.setPhotoCaptureMode(.quality, sound: false)
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
            camera.setPhotoCaptureMode(.quality, sound: false)
            camera.setFocalLength(focal, animated: false)
            deadline = Date().addingTimeInterval(20)
            while camera.capturePreview(lutKey: key) == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            camera.setFocusAndExposure(normalizedPoint: CGPoint(x: 0.2, y: 0.5))
            try await Task.sleep(for: .seconds(1))
            let ordinaryFrame = try XCTUnwrap(camera.capturePreview(lutKey: key))
            camera.setPhotoCaptureMode(.livePhoto, sound: ProcessInfo.processInfo.environment["JUSTSHOOT_FRAMING_AUDIO"] == "1")
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
            let hdrEnabled = PhotoCaptureMode.hdrEnabledByDefault
            camera.setEntrySceneActive(true)
            camera.setPhotoCaptureMode(.preferred(livePhoto: startsLive, hdrEnabled: hdrEnabled), sound: false)
            camera.requestCameraPermission()
            for live in [startsLive, !startsLive, startsLive] {
                let expectsLive = live && LivePhotoEncoderConfiguration.isSupported
                camera.setPhotoCaptureMode(.preferred(livePhoto: expectsLive, hdrEnabled: hdrEnabled), sound: false)
                let deadline = Date().addingTimeInterval(20)
                var configured = false
                while Date() < deadline {
                    if camera.isCaptureAvailable,
                       let video = camera.session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first,
                       !video.automaticallyConfiguresOutputBufferDimensions,
                       camera.livePhotoCaptureState.canCapture == expectsLive {
                        configured = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(configured, "cold_live=\(startsLive) requested_live=\(live) state=\(camera.livePhotoCaptureState)")
                let video = try XCTUnwrap(camera.session.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }.first)
                XCTAssertFalse(video.deliversPreviewSizedOutputBuffers)
                XCTAssertFalse(expectsLive && camera.usesDeferredPhotoDelivery)
                XCTAssertEqual(camera.livePhotoCaptureState.canCapture, expectsLive)
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
        let producesRestart = ProcessInfo.processInfo.environment["JUSTSHOOT_RESTART_STAGE"] == "write"
        let verifyBurst = ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_BURST"] == "1"
        let verifyDelivery = ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_FILM_DELIVERY"] == "1"
        let verifyDeferredHDR = ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_DEFERRED_HDR"] == "1"
        let verifyDeferred = verifyDeferredHDR || ProcessInfo.processInfo.environment["JUSTSHOOT_VALIDATE_DEFERRED"] == "1"
        if verifyDeferredHDR { try XCTSkipUnless(PhotoCaptureMode.supportsHDR, "HDR requires iOS 18") }
        let switchToPhotos = ProcessInfo.processInfo.environment["JUSTSHOOT_SWITCH_TO_PHOTOS"] == "1"
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        // Exercise shipping behavior without changing the device's persisted diagnostic preferences.
        let diagnosticExports = ProcessInfo.processInfo.environment["JUSTSHOOT_STAGE_EXPORTS"] == "1"
        defaults.setVolatileDomain(arguments.merging(["processingStageDiagnostics": diagnosticExports]) { _, new in new },
            forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let journal = CaptureJournal(root: producesRestart ? Self.restartDirectory.appendingPathComponent("jobs")
            : FileManager.default.temporaryDirectory.appendingPathComponent("camera-validation-\(UUID().uuidString)"))
        if producesRestart, FileManager.default.fileExists(atPath: Self.restartDirectory.path) {
            // Only this opt-in test owns this directory. A fresh producer starts a new validation pair.
            try FileManager.default.removeItem(at: Self.restartDirectory)
        }
        defer { if !producesRestart { try? FileManager.default.removeItem(at: journal.root) } }
        let schema = Schema([Photo.self, CustomLUT.self])
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let pipeline = CapturePipeline(journal: journal)
        await pipeline.configure(container: container)
        let camera = CameraManager()
        defer { camera.stopSession() }
        let entrySource = FilmSource.preset(verifyBurst ? .kodakPortra400 : .fujiProvia100F)
        let preview = try await FilmCapturePreparation.shared.displayLUT(source: entrySource, curve: .builtIn(.none))
        let renderContext = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace, .cacheIntermediates: false])
        try await PreviewMetalResources.warmUpForRenderer()
        let previewKey = "physical-validation-entry"
        let initialTexture = try await PreviewLUTTextureCache.shared.prepare(key: previewKey, lut: preview)
        let scene = try await TestWindowScene.foreground()
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ValidationViewfinder(camera: camera, key: previewKey,
            texture: initialTexture, profile: entrySource.captureRenderProfile, pipeline: pipeline, container: container))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }
        camera.setEntrySceneActive(true)
        camera.updateEntryPipelineReady(pipeline.isPrepared)
        camera.updateEntryLUT(expectedKey: previewKey, preparedKey: previewKey)
        camera.setPhotoCaptureMode(.quality, sound: false)
        camera.requestCameraPermission()
        let entryDeadline = Date().addingTimeInterval(45)
        while !camera.entryPreparation.isRevealed && Date() < entryDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(camera.entryPreparation.isRevealed,
            "entry=\(camera.entryPreparation.phase) pending=\(camera.entryPreparation.pendingRequirements)")
        if verifyBurst {
            try await verifyBurstDelivery(camera: camera, pipeline: pipeline, journal: journal, container: container,
                source: entrySource, key: previewKey, lut: preview)
            return
        }
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
        let captures: [(FocalLengthOption, FilmSource, PhotoCaptureMode)]
        if verifyDeferred {
            let wide = camera.focalInfo.options.first { $0.rawValue == 24 } ?? initialFocal
            captures = [(wide, .preset(.kodakPortra400), verifyDeferredHDR ? .hdr : .quality)]
        } else if switchToPhotos || producesRestart {
            let live = switchToPhotos && ProcessInfo.processInfo.environment["JUSTSHOOT_BACKGROUND_LIVE"] == "1"
            captures = [(initialFocal, .preset(.kodakPortra400), live ? .livePhoto : .quality)]
        } else if verifyDelivery {
            captures = [FilmPreset.kodakPortra400, .kodakPortra400, .kodakGold200, .kodakTriX400, .kodakPortra400]
                .map { (initialFocal, .preset($0), .quality) }
        } else {
            captures = camera.focalInfo.options.map { ($0, .preset(.fujiProvia100F), .quality) }
                + [(initialFocal, .preset(.kodakPortra400), .quality), (initialFocal, customSource, .quality)]
                + (LivePhotoEncoderConfiguration.isSupported ? [(initialFocal, customSource, .livePhoto)] : [])
        }
        for (index, capture) in captures.enumerated() {
            let (focal, source, mode) = capture
            camera.setFocalLength(focal, animated: false)
            let reading = camera.automaticWhiteBalanceReading ?? .neutral
            let adjusted = try await ColorTemperatureLUT.shared.prepare(source: source, curve: .builtIn(.none),
                selection: .temperature(5_100), tint: .value(8), reference: reading)
            let cube = try await FilmCapturePreparation.shared.prepareRendering(for: adjusted)
            let key = "physical-validation-\(UUID().uuidString)"
            let texture = try await PreviewLUTTextureCache.shared.prepare(key: key, lut: cube)
            camera.updateEntryLUT(expectedKey: key, preparedKey: key)
            host.rootView = ValidationViewfinder(camera: camera, key: key, texture: texture,
                profile: source.captureRenderProfile, pipeline: pipeline, container: container)
            camera.setPhotoCaptureMode(mode, sound: false)
            let modeDeadline = Date().addingTimeInterval(10)
            while !camera.isReadyToCapture && Date() < modeDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let usesDeferredDelivery = camera.usesDeferredPhotoDelivery
            if verifyDeferred && !usesDeferredDelivery {
                throw XCTSkip("This camera configuration does not select deferred delivery at its maximum resolution")
            }
            if verifyDelivery && !verifyDeferred && usesDeferredDelivery {
                throw XCTSkip("The direct delivery audit requires a camera configuration that selects direct delivery")
            }
            let plan = PhotoCapturePlan.resolve(mode: mode, deferredDelivery: usesDeferredDelivery,
                directHDRAvailable: camera.directHDRCaptureFormat != nil)
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
            let trace = DiagnosticTrace(id: id.uuidString)
            var proxyPlaceholder: String?
            var checkpointFile: FileHandle?
            var didEnterBackground = false
            var delayedExit: Task<Void, Never>?
            let requestBackground = verifyDelivery && switchToPhotos && index == captures.count - 1
            let exitDelayMs = Int(ProcessInfo.processInfo.environment["JUSTSHOOT_SWITCH_DELAY_MS"] ?? "") ?? 0
            let background = NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { _ in
                    didEnterBackground = true
                    camera.pauseSessionForBackground()
                    Task { await pipeline.enterBackground() }
                }
            let foreground = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { _ in
                    guard requestBackground && didEnterBackground else { return }
                    trace.event("test_returned_to_camera")
                    Task { await pipeline.retryPending() }
                }
            let phase = pipeline.$phases.sink { phases in
                if verifyDeferred, phases[id] == .saving { proxyPlaceholder = try? journal.proxyPlaceholder(for: id) }
                if verifyDelivery, phases[id] == .saving, checkpointFile == nil {
                    checkpointFile = try? FileHandle(forReadingFrom: journal.file("rendered.image", for: id))
                }
            }
            defer {
                delayedExit?.cancel()
                phase.cancel()
                background.cancel()
                foreground.cancel()
                try? checkpointFile?.close()
            }
            let start = ProcessInfo.processInfo.systemUptime
            let result: Result<CaptureResult, CameraCaptureFailure> = await withCheckedContinuation { continuation in
                camera.capturePhoto(admission: admission, live: plan.capturesLivePhoto, raw: plan.capturesRAW,
                    expectedRAWFormat: plan.capturesRAW ? format : nil, previewFrame: previewFrame, trace: trace,
                    onExposureComplete: {
                        trace.event("exposure_complete_main")
                        pipeline.preparePreview(previewFrame, recipe: recipe, lut: cube)
                        if requestBackground {
                            let openPhotos = {
                                trace.event("test_open_photos", "delay_ms=\(exitDelayMs)")
                                UIApplication.shared.open(URL(string: "photos-redirect://")!) { XCTAssertTrue($0) }
                            }
                            if exitDelayMs == 0 { openPhotos() }
                            else {
                                delayedExit = Task {
                                    try? await Task.sleep(for: .milliseconds(exitDelayMs))
                                    if !Task.isCancelled { openPhotos() }
                                }
                            }
                        }
                    }, onStillCaptured: { still in
                    await pipeline.checkpointStill(still, recipe: recipe, lut: cube, rawLUT: rawLUT)
                }, onFinalStill: { pipeline.deliverFinalStill($0, id: id) }) { continuation.resume(returning: $0) }
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
            if usesDeferredDelivery, let deferred = captured.deferredPhoto {
                XCTAssertFalse(plan.capturesRAW)
                XCTAssertGreaterThan(deferred.width * deferred.height, 20_000_000)
            }
            let model = (props?[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFModel as String]
            let completedRecipe = recipe.withPhotoDisplayTime(captured.photoDisplayTime.isValid && captured.photoDisplayTime.isNumeric
                ? captured.photoDisplayTime.seconds : nil)
            if producesRestart {
                XCTAssertEqual(try journal.job(for: id).awaitingCaptureCompletion, true)
                let second = CaptureRecipe(id: UUID(), captureDate: recipe.captureDate.addingTimeInterval(0.1),
                    filterName: recipe.filterName, displayLabel: nil, focalLength: recipe.focalLength, outputQuality: nil,
                    profile: recipe.profile, grainSeed: recipe.grainSeed, location: nil, lutDimension: cube.dimension,
                    chromaticSceneCCT: nil, photoDisplayTime: nil, plan: recipe.plan, frozenChromaticGain: recipe.frozenChromaticGain)
                let rendered = await Task.detached {
                    CapturePhotoRenderer.render(source: captured.imageData, recipe: second, lut: cube, rawLUT: nil, grainSeed: second.grainSeed)
                }.value
                let bytes = try XCTUnwrap(rendered)
                var job = try journal.stage(recipe: second, imageData: captured.imageData, movieURL: nil, lut: cube)
                try journal.writeRenderedImage(bytes, for: job.id)
                job.rendered = true
                try journal.update(job)
                let asset = try await PhotoLibrary.save(imageData: bytes, creationDate: second.captureDate,
                    latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil, captureID: second.id)
                let state = RestartState(pid: ProcessInfo.processInfo.processIdentifier, original: id, saved: second.id, asset: asset)
                try JSONEncoder().encode(state).write(to: Self.restartDirectory.appendingPathComponent("state.json"), options: .atomic)
                print("physical_restart_staged jobs=2 original_checkpoint=true photos_committed=true")
                return
            }
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
            if plan.capturesLivePhoto {
                let playable = await AssetImageLoader.shared.livePhoto(id: assetID,
                    targetSize: CGSize(width: 320, height: 320), trace: trace) != nil
                XCTAssertTrue(playable, "The saved Photos asset must load for Live Photo playback")
                print("physical_live_library playable=\(playable)")
            }
            if verifyDeferred {
                if requestBackground { XCTAssertTrue(didEnterBackground) }
                let deferred = try XCTUnwrap(captured.deferredPhoto)
                XCTAssertGreaterThan(deferred.width * deferred.height, 20_000_000)
                let resources = PHAssetResource.assetResources(for: asset)
                XCTAssertTrue(resources.contains { $0.type == .adjustmentData })
                let preserved = await AssetImageLoader.shared.imageData(id: assetID, original: true)
                let original = try XCTUnwrap(preserved)
                if verifyDeferredHDR, #available(iOS 18.0, *) {
                    XCTAssertEqual(plan.format, .processedHDR)
                    XCTAssertNotNil(pipeline.lastCompletion?.thumbnail)
                    XCTAssertEqual(CGImageSourceGetType(outputSource) as String?, "public.heic")
                    XCTAssertEqual(outputProps[kCGImagePropertyPixelWidth as String] as? Int, asset.pixelWidth)
                    XCTAssertEqual(outputProps[kCGImagePropertyPixelHeight as String] as? Int, asset.pixelHeight)
                    let sourceHDR = try XCTUnwrap(CIImage(data: original, options: [.expandToHDR: true]))
                    let filmHDR = try XCTUnwrap(CIImage(data: output, options: [.expandToHDR: true]))
                    XCTAssertGreaterThan(sourceHDR.contentHeadroom, 1, "Aim the camera at a scene with bright highlights")
                    XCTAssertGreaterThan(filmHDR.contentHeadroom, 1)
                    XCTAssertTrue(CGImageSourceCopyAuxiliaryDataInfoAtIndex(outputSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
                        || CGImageSourceCopyAuxiliaryDataInfoAtIndex(outputSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil)
                    print("physical_deferred_hdr source_headroom=\(sourceHDR.contentHeadroom) film_headroom=\(filmHDR.contentHeadroom)")
                }
                XCTAssertNotEqual(original, output)
                XCTAssertEqual(proxyPlaceholder, assetID)
                // Simulate a restart after PhotoKit developed/renamed the proxy and before its manifest update.
                let retried = try await PhotoLibrary.saveDeferredProxy(Data(), recipe: recipe, reservedAsset: XCTUnwrap(proxyPlaceholder))
                XCTAssertEqual(retried, assetID)
                print("physical_deferred_delivery id=\(id) size=\(asset.pixelWidth)x\(asset.pixelHeight) original_bytes=\(original.count) edited_bytes=\(output.count)")
                continue
            }
            if verifyDelivery && !verifyDeferred {
                XCTAssertNil(captured.deferredPhoto)
                let resources = PHAssetResource.assetResources(for: asset)
                XCTAssertFalse(resources.contains { $0.type == .adjustmentData || $0.type == .photoProxy })
                let photo = try XCTUnwrap(resources.first { $0.type == .photo })
                let originalURL = journal.root.appendingPathComponent("\(id).heic")
                try await PHAssetResourceManager.default().writeData(for: photo, toFile: originalURL, options: nil)
                let originalInPhotos = try Data(contentsOf: originalURL)
                let renderedCheckpoint = try XCTUnwrap(checkpointFile).readToEnd()
                XCTAssertEqual(originalInPhotos, renderedCheckpoint, "The first Photos original must contain the rendered film bytes")
                XCTAssertNotEqual(originalInPhotos, captured.imageData)
                if requestBackground {
                    let deadline = Date().addingTimeInterval(8)
                    while !didEnterBackground, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                    XCTAssertTrue(didEnterBackground)
                }
                print("physical_film_delivery id=\(id) film=\(source.photoFilterName) original_matches=\(originalInPhotos == renderedCheckpoint) background=\(didEnterBackground) size=\(asset.pixelWidth)x\(asset.pixelHeight)")
                continue
            }
            let previewImage = await CapturePreviewRenderer.image(frame: previewFrame, lut: cube, recipe: recipe)
            let renderedPreview = try XCTUnwrap(previewImage)
            let previewAttachment = XCTAttachment(image: renderedPreview)
            previewAttachment.name = "viewfinder-\(focal.rawValue)mm-\(source.photoFilterName)-\(plan.format.rawValue)"
            previewAttachment.lifetime = .keepAlways
            add(previewAttachment)
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

    private struct RestartState: Codable {
        let pid: Int32
        let original: UUID
        let saved: UUID
        let asset: String
    }

    private static var restartDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("PhysicalCaptureRestartValidation", isDirectory: true)
    }

    @MainActor
    func testRecoverRealShutterInNewProcess() async throws {
        guard ProcessInfo.processInfo.environment["JUSTSHOOT_RESTART_STAGE"] == "read" else {
            throw XCTSkip("Run the opted-in physical producer and consumer in separate test processes")
        }
        let directory = Self.restartDirectory
        let state = try JSONDecoder().decode(RestartState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        XCTAssertNotEqual(state.pid, ProcessInfo.processInfo.processIdentifier)
        let journal = CaptureJournal(root: directory.appendingPathComponent("jobs"))
        let original = try Data(contentsOf: journal.file("original.image", for: state.original))
        let existing = try Data(contentsOf: journal.file("rendered.image", for: state.saved))
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let pipeline = CapturePipeline(journal: journal)
        var renderedFile: FileHandle?
        let phases = pipeline.$phases.sink {
            if $0[state.original] == .saving, renderedFile == nil {
                renderedFile = try? FileHandle(forReadingFrom: journal.file("rendered.image", for: state.original))
            }
        }
        defer { phases.cancel(); try? renderedFile?.close() }
        await pipeline.configure(container: container)
        await pipeline.retryPending()
        let deadline = Date().addingTimeInterval(60)
        while try !journal.jobs().isEmpty || pipeline.pendingCount != 0 {
            guard Date() < deadline else { return XCTFail(pipeline.lastError ?? "Recovery did not drain") }
            try await Task.sleep(for: .milliseconds(100))
        }
        await pipeline.retryPending()
        let rows = try ModelContext(container).fetch(FetchDescriptor<Photo>())
        XCTAssertEqual(Set(rows.map(\.id)), [state.original, state.saved])
        XCTAssertEqual(rows.count, 2)
        var matches: [UUID: Int] = [:]
        let date = try XCTUnwrap(rows.first?.timestamp)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
            date.addingTimeInterval(-2) as NSDate, date.addingTimeInterval(2) as NSDate)
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            let filenames = PHAssetResource.assetResources(for: asset).map(\.originalFilename)
            if let id = PhotoLibrary.captureIdentifier(in: filenames) { matches[id, default: 0] += 1 }
        }
        let rendered = try XCTUnwrap(renderedFile).readToEnd()
        for row in rows {
            XCTAssertEqual(matches[row.id], 1)
            let assetID = try XCTUnwrap(row.assetLocalIdentifier)
            if row.id == state.saved { XCTAssertEqual(assetID, state.asset) }
            let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
            let photo = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first { $0.type == .photo })
            let output = directory.appendingPathComponent("\(row.id).heic")
            try await PHAssetResourceManager.default().writeData(for: photo, toFile: output, options: nil)
            let bytes = try Data(contentsOf: output)
            XCTAssertEqual(bytes, row.id == state.saved ? existing : rendered)
            XCTAssertNotEqual(bytes, original)
        }
        try FileManager.default.removeItem(at: directory)
        print("physical_restart_recovered distinct_process=true assets=2 exactly_once=true")
    }

    @MainActor
    private func verifyBurstDelivery(camera: CameraManager, pipeline: CapturePipeline, journal: CaptureJournal,
                                    container: ModelContainer, source: FilmSource, key: String, lut: CubeLUT) async throws {
        let coordinator = CameraCoordinator(camera: camera, pipeline: pipeline)
        let selection = CameraCaptureSelection(source: source, lutKey: key, lut: lut, profile: source.captureRenderProfile,
            adjustment: nil, plan: .resolve(mode: .quality), curveFields: "", colorFields: "")
        var accepted: [UUID] = []
        var previews: [UUID] = []
        let switchToPhotos = ProcessInfo.processInfo.environment["JUSTSHOOT_SWITCH_TO_PHOTOS"] == "1"
        var pendingAtExit: Int?
        let observation = pipeline.$lastPreview.compactMap { $0?.id }.sink { id in
            previews.append(id)
            if switchToPhotos, accepted.count == 10, accepted.last == id {
                DiagnosticTrace(id: id.uuidString).event("test_open_photos", "burst=10")
                UIApplication.shared.open(URL(string: "photos-redirect://")!) { XCTAssertTrue($0) }
            }
        }
        let background = NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                pendingAtExit = pipeline.pendingCount
                camera.pauseSessionForBackground()
                Task { await pipeline.enterBackground() }
            }
        let foreground = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { _ in
                if pendingAtExit != nil { Task { await pipeline.retryPending() } }
            }
        defer { observation.cancel(); background.cancel(); foreground.cancel() }
        var peakPending = 0
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<10 {
            let deadline = Date().addingTimeInterval(15)
            while (coordinator.isShutterBusy || !camera.isReadyToCapture || !pipeline.canCapture), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            await coordinator.capture(selection: selection, currentLookKey: { key }, isSceneActive: { true },
                onAccepted: { if let id = coordinator.activeShutterID { accepted.append(id) } }, onWillCapture: {})
            XCTAssertNil(coordinator.error)
            guard accepted.count == index + 1 else { return XCTFail("Shutter was not admitted at index \(index)") }
            peakPending = max(peakPending, pipeline.pendingCount)
        }
        let issueSeconds = ProcessInfo.processInfo.systemUptime - start
        let deadline = Date().addingTimeInterval(90)
        while pipeline.lastCompletion?.captureID != accepted.last || pipeline.pendingCount != 0 {
            guard Date() < deadline else { return XCTFail(pipeline.lastError ?? coordinator.error ?? "Burst did not drain") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let rows = try ModelContext(container).fetch(FetchDescriptor<Photo>())
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(Set(rows.map(\.id)), Set(accepted))
        XCTAssertEqual(previews.last, accepted.last)
        if switchToPhotos { XCTAssertGreaterThan(try XCTUnwrap(pendingAtExit), 0) }
        let positions = previews.compactMap { accepted.firstIndex(of: $0) }
        XCTAssertEqual(positions, positions.sorted(), "An older thumbnail replaced a newer shot")
        let assets = Set(rows.compactMap(\.assetLocalIdentifier))
        XCTAssertEqual(assets.count, 10)
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: Array(assets), options: nil).count, 10)
        for row in rows {
            XCTAssertEqual(PhotoLibrary.findCapture(id: row.id, creationDate: row.timestamp), row.assetLocalIdentifier)
        }
        XCTAssertTrue(try journal.jobs().isEmpty)
        print("physical_burst shots=\(rows.count) previews=\(previews.count) peak_pending=\(peakPending) pending_at_exit=\(pendingAtExit ?? 0) issue_seconds=\(issueSeconds) drain_seconds=\(ProcessInfo.processInfo.systemUptime - start)")
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
    var pipeline: CapturePipeline?
    var container: ModelContainer?

    var body: some View {
        ZStack {
            CameraPreviewUnderlayView(manager: camera)
            RealtimePreviewView(manager: camera, resourcesReady: camera.entryPreparation.resourcesReady,
                lutCacheKey: key, preparedLUT: texture,
                grain: profile.grain, optics: profile.optics, chromatic: profile.effectiveChromatic)
        }
            .aspectRatio(camera.previewAspectRatio, contentMode: .fit)
            .background(.black)
            .overlay(alignment: .bottomLeading) {
                if let pipeline, let container {
                    ValidationBadge(pipeline: pipeline).modelContainer(container)
                }
            }
    }
}

private struct ValidationBadge: View {
    @ObservedObject var pipeline: CapturePipeline
    @State private var hint: RecentPhotoThumbnail?

    var body: some View {
        RecentPhotosBadge(lastThumbnailHint: $hint, pendingPreview: pipeline.lastPreview,
            isShutterBusy: false, isProcessing: pipeline.lastPreview.map { pipeline.isProcessing($0.id) } ?? false,
            controlRotationAngle: .zero, orientation: .portrait)
    }
}
