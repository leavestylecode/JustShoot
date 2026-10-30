import XCTest
import SwiftData
import SwiftUI
import CoreImage
import ImageIO
import AVFoundation
@preconcurrency import Photos
@testable import JustShoot

/// Explicitly opt in on a connected, unlocked phone. This takes real photographs
/// and keeps the resulting sRGB assets in Photos; ordinary test runs never capture.
/// For framing acceptance, mount the phone in portrait and use a stationary,
/// textured subject. Paired viewfinder/Photos attachments cover every focal option.
final class PhysicalCameraPipelineTests: XCTestCase {
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
            let result: CaptureResult? = await withCheckedContinuation { continuation in
                camera.capturePhoto(admission: admission, live: plan.capturesLivePhoto, raw: plan.capturesRAW,
                    expectedRAWFormat: plan.capturesRAW ? format : nil, previewFrame: previewFrame, onStillCaptured: { still in
                    await pipeline.checkpointStill(still, recipe: recipe, lut: cube, rawLUT: rawLUT)
                }) { continuation.resume(returning: $0) }
            }
            let captured = try XCTUnwrap(result)
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
        RealtimePreviewView(manager: camera, lutCacheKey: key, preparedLUT: texture,
            grain: profile.grain, optics: profile.optics, chromatic: profile.effectiveChromatic)
            .aspectRatio(CameraFraming.portraitAspect, contentMode: .fit)
            .background(.black)
    }
}
