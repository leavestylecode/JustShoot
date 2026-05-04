# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JustShoot is an iOS film camera app built with SwiftUI and SwiftData that emulates authentic film photography. The app provides 8 built-in film presets via LUT (Look-Up Table) color grading, supports user-imported `.cube` LUTs as custom filters, and ships a 550-card film-packaging library for browsing real-world film stocks. Photos are captured at HEIF/HEVC with full EXIF/GPS metadata preserved.

**Current State**: Optimized for iOS 26 with the latest AVFoundation virtual-device architecture (`builtInTripleCamera` + `setPrimaryConstituentDeviceSwitchingBehavior(.locked)`), iOS 26 Liquid Glass UI for camera controls, and Swift 6 strict concurrency throughout. Under `complete` mode with zero warnings. iPhone-Camera–level interaction: tap-to-focus + drag-for-EV, orientation-aware controls under portrait UI lock, ZSL-gated lens switching, distance-aware flash with AE/WB lock-and-restore.

## Architecture

### Core Technologies
- **SwiftUI** with iOS 26 features (Liquid Glass `.glassEffect`, `matchedTransitionSource`, `navigationTransition(.zoom)`)
- **SwiftData** with versioned schema (`SchemaV1`), `@ModelActor` for off-main writes
- **AVFoundation** virtual-device architecture — `builtInTripleCamera` with `.locked` constituent switching
- **CoreImage + Metal** — sRGB-locked CIContext for LUT processing, dedicated compute shader for real-time preview
- **CoreMotion** accelerometer (5 Hz) for device orientation under system rotation lock
- **CoreLocation** with 30 s cache, zero-wait GPS fetch
- **Photos Framework** for export with metadata preservation

### Source Layout (post-refactor, 24 files)

```
JustShoot/
├── JustShootApp.swift              (75)   @main, SchemaV1 + JustShootMigrationPlan,
│                                          AppDelegate forces .portrait, retroactive
│                                          UINavigationController gesture
├── ContentView.swift               (418)  Home: 3-col preset+custom-LUT grid;
│                                          fileImporter for .cube; tile→camera zoom
├── Logging.swift                   (50)   Log enum (8 categories) + PerfTimer
├── Models.swift                    (383)  Photo @Model, CustomLUT @Model, FilmPreset,
│                                          FilmSource (preset|custom unification),
│                                          ParsedExifInfo, PhotoSaver @ModelActor,
│                                          AnyKeyPath @retroactive Sendable
├── FilmProcessor.swift             (323)  CubeLUT, FilmProcessor singleton (LUT
│                                          parse + applyLUTPreservingMetadata HEIF
│                                          pipeline)
├── FilmCardCatalog.swift           (167)  FilmCard, FilmCardBundle, FilmCardImageCache,
│                                          FilmCardLibrary (550-card index)
│
│ ── Camera (post-split: was one 3,233-line monolith)
├── CameraView.swift                (693)  SwiftUI shell + capture pipeline + gestures
├── CameraSubviews.swift            (260)  FocusIndicatorView, ExposureSunRail,
│                                          FocalLengthStrip, FilmSourceCoverThumbnail,
│                                          FlashMode, Notification.Name extension,
│                                          UIDeviceOrientation extension, openAppSettings
├── DeviceFocalInfo.swift           (133)  FocalLengthOption enum, ConstituentInfo,
│                                          DeviceFocalInfo (virtual-device focal data)
├── MetalPreview.swift              (291)  RealtimePreviewView + Metal Coordinator
│                                          (CVPixelBuffer → 3D LUT compute shader)
├── CameraManager.swift             (278)  Class declaration + stored properties +
│                                          init/deinit + frame state + delegates
│                                          (VideoDataOutput, SessionControls)
├── CameraManager+Orientation.swift (143)  CMMotion accelerometer +
│                                          RotationCoordinator KVO + EXIF orientation
├── CameraManager+Session.swift     (836)  permissions / configureAndStartSession /
│                                          format & dimensions / stabilization /
│                                          lockInitialFocalLength / KVO observers /
│                                          lifecycle / dumpLensSpecs diagnostics
├── CameraManager+Lens.swift        (247)  setFocalLength fast/slow path,
│                                          beginLensTransition / waitForLensSettled,
│                                          safe-shutter computation
├── CameraManager+Capture.swift     (348)  setFocusAndExposure, setExposureBias,
│                                          flash bias & restore, capturePhoto +
│                                          AVCapturePhotoCaptureDelegate
├── CameraManager+Location.swift    (93)   GPS 30 s cache + CLLocationManagerDelegate
│
│ ── Gallery (post-split: was one 1,601-line file)
├── GalleryView.swift               (345)  Grid + drag-to-select multi-delete +
│                                          PhotoThumbnailView cell + DetailPayload
├── ImageLoader.swift               (297)  Shared NSCache + disk cache + in-flight
│                                          dedup + currentScreen() helper
├── PhotoDetailView.swift           (492)  Paged detail viewer + PagerImage cell +
│                                          preheat / save / delete / info sheet
├── ZoomablePhoto.swift             (221)  UIViewRepresentable + ZoomingScrollView
│                                          (pinch zoom + edge-paging hand-off)
├── PhotoScrubber.swift             (160)  Horizontal thumbnail strip + cell
├── PhotoInfoPanel.swift            (104)  EXIF info sheet + ExifInfoCard
│
│ ── Film card library
├── FilmCardLibraryView.swift       (747)  Card library UI: filters, grid, detail
└── FilmCardCoverBackground.swift   (409)  Dominant-color extraction + adaptive backdrop
```

PBX file system synchronized group is on (`objectVersion = 77`); any file dropped into `JustShoot/` is auto-bundled into the target — no `pbxproj` edit needed.

### Data Model

```
Photo (@Model)
├── id: UUID
├── timestamp: Date
├── imageData: Data (.externalStorage)         ← HEIF or JPEG bytes
├── filmPresetName: String?                    ← FilmPreset.rawValue OR "custom:<UUID>"
├── filmDisplayLabel: String?                  ← user-facing label for custom LUTs
├── latitude / longitude / altitude: Double?
├── locationTimestamp: Date?
└── _parsedExif: ParsedExifInfo? (Transient, lazy)

CustomLUT (@Model)
├── id: UUID
├── displayName / fileName / iso / dimension
└── createdAt: Date
```

`FilmSource` is the unified abstraction for "what LUT to apply":

```
enum FilmSource {
    case preset(FilmPreset)              // built-in
    case custom(id, displayName, iso, fileName)
    var photoFilterName: String          // → Photo.filmPresetName
    var lutCacheKey: String              // → FilmProcessor cache key
}
```

`PhotoSaver` is a `@ModelActor` that owns its own `ModelContext` bound to the same `ModelContainer`. This bypasses `mainContext` so capture-time saves don't block the camera UI; SwiftData broadcasts changes back to the main `@Query` automatically.

### Photo Capture Pipeline

```
shutter tap (CameraView)
  ├── isCapturing = true                       ← guards entire pipeline (button throttle)
  ├── haptic + button press animation
  └── cameraManager.capturePhoto { ... }
         ├── await waitForLensSettled (≤600 ms) ← gate ZSL-vs-lens-switch race
         ├── flashMode == .on
         │     ├── lock exposureMode = .locked, whiteBalanceMode = .locked
         │     ├── apply distance-based exposure bias
         │     └── stash FlashRestoreState for post-capture
         └── photoOutput.capturePhoto(...)
                ├── willCapturePhotoFor    ── drives screen-flash overlay (synced w/ xenon)
                ├── didCapturePhotoFor     ── exposure-complete log
                └── didFinishProcessingPhoto
                       └── back on @MainActor:
                             ├── applyFlashRestore (restore AE/WB)
                             └── photoDataHandler(data)

Task.detached @userInitiated
  ├── cachedOrFreshLocation()                  ← 30 s cache, zero-wait
  ├── FilmProcessor.applyLUTPreservingMetadata
  │     ├── CIImage(data:).oriented(forExifOrientation:)
  │     ├── CIColorCubeWithColorSpace (sRGB)
  │     ├── ciContext.heifRepresentation (.RGBA8, sRGB, 0.95 quality)
  │     │     └── falls back to jpegRepresentation on encode failure
  │     └── CGImageDestinationAddImageFromSource(...)   ← byte-copy + metadata replace
  ├── PhotoSaver(modelContainer:).save(...)    ← @ModelActor, off main
  └── ImageLoader.loadThumbnail(imageData, photoId, 88pt) → write to lastPhotoThumbnail
```

### Lens-Switch Architecture (iOS 26 virtual device)

Single `AVCaptureSession` input is `builtInTripleCamera` (priority chain falls back to `builtInDualCamera` → `builtInDualWideCamera` → `builtInWideAngleCamera`). Constituent switching is driven by `videoZoomFactor` ramps with `setPrimaryConstituentDeviceSwitchingBehavior(.locked, ...)` for each focal-length option.

**FOV math (piecewise linear per constituent)**:
```
zoom = mm × constituent.lowerBound / constituent.nativeMm
```
On iPhone 17 Pro (UW=13/W=24/T=100, switchovers [2.0, 8.0]):
- 13 mm → 1.00 (UW)
- 24 mm → 2.00 (W)
- 35 mm → 2.92 (W)
- 50 mm → 4.17 (W)
- 100 mm → 8.00 (T)
- 200 mm → 16.0 (T)

Boundary options (24 mm, 100 mm) get `+0.05` epsilon to land strictly inside the target constituent's range — `.locked` selection on the exact threshold is ambiguous and may pick the wrong constituent.

**`applyFocalLength` two paths**:
- **Fast path** (target constituent already active, e.g. 35 → 50 both on W): single `lockForConfiguration` → `.locked` + `ramp(toVideoZoomFactor:)` + safe shutter. Zero async wait.
- **Slow path** (cross-constituent): Phase 0 (`.auto` + 33 ms yield to release locked min/max) → Phase 1 (single animated ramp; `.auto` crossfades the constituent during ramp) → Phase 2 (wait `isRampingVideoZoom == false`, then ≤300 ms for `activePrimaryConstituent === target`) → Phase 3 (`.locked`).

`isLensTransitioning` flag + `waitForLensSettled(timeoutMs:)` prevents `capturePhoto` from picking a frame from the previous constituent's ZSL ring buffer (this was the "35 mm photo recorded as 13 mm UW" bug).

### Stabilization Strategy

Mirrors iPhone Camera's split-path approach: stabilize the viewfinder, leave still capture to OIS + multi-frame fusion.

- **Preview path** (`videoDataOutput`): `applyPreviewStabilization` sets `connection.preferredVideoStabilizationMode` with priority `.previewOptimized` → `.standard` → `.off`, gated by `format.isVideoStabilizationModeSupported`. `.previewOptimized` (iOS 17+) is purpose-built for camera-app viewfinders — stabilizes the preview without adding shutter latency.
- **Photo path** (`photoOutput`): **never** set `preferredVideoStabilizationMode`. Still capture relies on OIS / sensor-shift IS (hardware, always on) + multi-frame fusion (Smart HDR, Deep Fusion, Photonic Engine — engaged automatically by `maxPhotoQualityPrioritization = .balanced`). Setting a stabilization mode on the photo connection introduces warping/cropping that conflicts with Deep Fusion frame alignment and degrades 24+ MP output.

### Orientation Handling

UI is locked to `.portrait` at the AppDelegate level, but the user can hold the phone in any orientation:

- **Device orientation**: `CMMotionManager.startAccelerometerUpdates(...)` at 5 Hz, classified into `UIDeviceOrientation.{portrait, portraitUpsideDown, landscapeLeft, landscapeRight}` from the gravity vector. NOT `UIDevice.orientationDidChangeNotification` — that gets suppressed under system rotation lock; iPhone Camera ignores the lock the same way.
- **Floating control containers stay fixed in screen coordinates**; only their inner glyphs/numbers rotate via a `controlRotationAngle` (0/90/-90/180°) with a 0.35 s spring animation. iPhone Camera's exact pattern.
- **Gesture remap to perceived axes**: `perceivedTranslation()` maps SwiftUI `DragGesture.translation` (screen coords) to user-perceived (vertical, horizontal) so finger-up always means "EV brighter" regardless of how the phone is held.
- **Photo orientation** uses `AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelCapture` applied to `photoOutput.connection.videoRotationAngle`; preview connection always renders 90° CW (sensor landscape → portrait viewport).

### Tap-to-Focus + Drag-for-EV

Single `DragGesture(minimumDistance: 0)` serves both gestures. AVF commit is **deferred until gesture intent is unambiguous** (a tap on release, OR vertical-dominant drag passing the threshold). Without this defer, every horizontal swipe runs an AF cycle and zeroes user-set EV bias.

State machine:
- **No active focus**: touch-down shows reticle (visual only, no AVF). On vertical-dominant drag (`|dy| > 14 && |dy| > |dx| * 1.5`) → enter EV mode, commit AVF to start point (resets bias to 0), then `bias = biasAtDragStart + dy/100` (100 pt = 1 EV, ±1 EV soft cap matching `ExposureSunRail` visual span).
- **Active focus** (3.5 s `focusHoldTimer` not yet expired): touch-down does **not** move reticle or fire haptic (iPhone Camera behavior). Vertical drag continues EV from current bias (no re-AVF). Lift-as-tap moves reticle and re-commits AVF.
- **Lift-as-cancel** (non-tap, non-EV): hide reticle, no AVF side-effects.

### Capture Quality Tuning

Three settings work together (all set in `applyBestFormatAndModes` + `configureAndStartSession`):

1. **`maxPhotoDimensions`** — picks the largest 4:3 dim ≤ 60 MP cap. iPhone 17 Pro's `supportedMaxPhotoDimensions` only lists `[12 MP, 48 MP]` on 4:3 formats; the 24 MP middle tier is system-only. Going to 48 MP gives ~22 MP real detail at 1.46× digital zoom (35 mm), which matches iPhone Camera at 1.5×.
2. **`device.activeColorSpace = .sRGB`** — film LUTs are sRGB-trained; locking it skips P3→sRGB conversion in the CoreImage path and gives more predictable color.
3. **`photoQualityPrioritization = .balanced`** on both `output.maxPhotoQualityPrioritization` and per-capture settings — engages Deep Fusion + Smart HDR + Photonic Engine **synchronously**. Adds ~100–300 ms to `didFinishProcessingPhoto` but ZSL + ResponsiveCapture preserve shutter feel.

**Critical: do NOT enable `isAutoDeferredPhotoDeliveryEnabled`.** The deferred Deep Fusion result is delivered **only to PhotoKit**, not to the photo delegate. Apps with custom storage (SwiftData, here) get the "early/quick" proxy that skips Deep Fusion — enabling deferred *lowers* quality.

### HEIF + Metadata Fast-Copy

`FilmProcessor.applyLUTPreservingMetadata` encodes once (HEIF/HEVC `.RGBA8`, sRGB, quality 0.95; JPEG fallback) then injects metadata via `CGImageDestinationAddImageFromSource(dest, source, 0, mergedMetadata)`. When source and dest use the same `imageType`, this is the **fast copy + metadata replace** path — pixel data is copied byte-for-byte, only the metadata block is rewritten. **No recompression. Zero pixel-quality loss.** File size ~50% of an equivalent-quality JPEG.

Pixel orientation is applied pre-encode via `ciImage.oriented(forExifOrientation:)`; output is written as `Orientation = 1`.

## Development Commands

```bash
# Open in Xcode
open JustShoot.xcodeproj

# Build for current dev simulator
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot \
  -destination 'id=1A1DC730-6016-4F18-A8F8-5D1254087051' \
  -configuration Debug build

# List simulators
xcrun simctl list devices available

# Build for device (requires provisioning profile)
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot \
  -destination 'generic/platform=iOS' build
```

**Important**: Full camera + GPS functionality requires a physical iOS device. The simulator can show camera permission dialogs but cannot access camera hardware or accelerometer.

### Logging Filter

Console.app or terminal:
```bash
log stream --predicate 'subsystem == "com.leavestylecode.JustShoot"'
log stream --predicate 'subsystem == "com.leavestylecode.JustShoot" && category == "camera.capture"'
```

8 categories (defined in `Logging.swift`): `camera.session`, `camera.capture`, `camera.orient`, `camera.gps`, `photo.lut`, `photo.save`, `gallery`, `ui`. Event names are `snake_case` with `key=value` params; durations in `ms`. Use `Log.perf(label, logger:)` for timed sections.

### Testing LUT Processing

LUT files live in `JustShoot/Resources/*.cube`. `FilmProcessor.parseCubeFile` validates:
- Cube dimension declared (`LUT_3D_SIZE`)
- Data values match `dimension³ × 3`
- Files are converted to RGBA `Data` with alpha=1.0 (`.cube` files are RGB)
- Encoding fallback: UTF-8 → ISO Latin-1 → Windows CP1252 → MacOSRoman (some `.cube` titles have non-UTF-8 bytes)

## Adding a New Built-in Film Preset

1. Add a case to `FilmPreset` enum in `Models.swift` with `displayName`, `iso`, `lutResourceName`, and `libraryCardImage`
2. Drop the `.cube` file into `JustShoot/Resources/` (sync group auto-bundles it)
3. Pick a card image from `Resources/cards/*.heic` to match the stock visually
4. Add a color accent to `ContentView.FilmPresetGrid.accentColor(for:)` if the home grid uses one

That's it — `FilmSource.preset` automatically routes via `lutCacheKey` and `FilmProcessor.preload(preset:)` is called on app launch.

## Adding a Custom LUT (User Flow)

ContentView's `+` toolbar → `.fileImporter` for `.cube` → `FilmProcessor.parseCubeFile` validates → user names + sets ISO → `CustomLUT` row inserted, file copied to `Documents/CustomLUTs/<UUID>.cube`. The LUT is preloaded and addressable via `FilmSource.from(customLUT)`.

## Memory Management

- SwiftData `@Attribute(.externalStorage)` keeps `imageData` out of the SQLite row (loaded on-demand)
- `ImageLoader` (gallery) and `FilmCardImageCache` (catalog) are separate `NSCache`s with 50-item / 50 MB limits each — gallery and library don't evict each other
- Both use `CGImageSource` thumbnail downsampling; full images never decoded into RAM unless on the detail page
- `ImageLoader` deduplicates in-flight loads via `OSAllocatedUnfairLock` — concurrent grid scrolls don't queue duplicate decode tasks
- Disk caches under `Library/Caches/{Thumbs,Previews}/` survive process restart; cleared on photo deletion

## GPS Integration

- Started only when `CameraView` appears (not at app launch)
- Stopped when `CameraView` disappears
- `cachedOrFreshLocation()` returns cached location if < 30 s old; otherwise returns whatever `currentLocation` is (no blocking wait)
- GPS metadata written to both image data and `Photo` model for dual persistence

GPS *timestamp* in EXIF uses capture time, **not** location-fix time, so a burst of photos with the same cached location doesn't show identical GPS timestamps in Photos.app.

## Key Technical Constraints

- **iOS 26.0+** (deployment target). The legacy 18.0 entries in pbxproj are for the test target only.
- **Swift 6 strict concurrency**: `SWIFT_STRICT_CONCURRENCY=complete` + `SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY=YES`. Zero warnings on clean build. `extension AnyKeyPath: @retroactive @unchecked Sendable {}` is the only retroactive conformance — required for `#Predicate` macro expansion.
- **Physical device required** for camera and accelerometer
- **Photos.app permission** required for export with metadata
- **Location permission** required for GPS tagging
- **Localization**: English source + zh-Hans catalog (`Localizable.xcstrings`, `InfoPlist.xcstrings`)
- **Portrait UI lock** at `AppDelegate` level — controls and gestures rotate via `controlRotationAngle` and `perceivedTranslation`, not via system rotation

## Common Pitfalls

- **Don't combine `setPrimaryConstituentDeviceSwitchingBehavior(.auto)` and `videoZoomFactor =` in the same `lockForConfiguration` block.** When transitioning out of `.locked`, the zoom write is still clamped to the locked min/max — split into two sequential `lockForConfiguration` cycles with a 33 ms yield between (see `applyFocalLength` slow path).
- **Boundary focal lengths need `+0.05` epsilon.** At zoom values *exactly* on a switchover threshold (e.g. 2.0 or 8.0), system constituent selection is ambiguous and may pick the lower-zoom constituent (giving you UW/W with digital crop instead of W/T native).
- **Swift drops the `Device` suffix** on KVO-observable properties: Obj-C `activePrimaryConstituentDevice` → Swift `activePrimaryConstituent`. The setter `setPrimaryConstituentDeviceSwitchingBehavior(_:_)` keeps the suffix.
- **Don't enable `isAutoDeferredPhotoDeliveryEnabled`** — only PhotoKit gets the deferred (high-quality) result; custom storage gets the early proxy.
- **Cross-file extensions can't access `private` members.** Many `CameraManager` properties were promoted from `private` to internal during the 2026-05-05 refactor for this reason. New properties accessed by extension files in other Swift files should default to no access modifier.
- **Don't call `stopRunning()` synchronously on the main thread** — it blocks. Stop on `sessionQueue` (see `stopSession`).

## Notes for Future Development

- Manual focus override (slider during reticle hold?) — current architecture has 3.5 s `focusHoldTimer` + drag-for-EV; manual focus could fit alongside drag-for-EV but needs a clear gesture orthogonal to vertical EV
- Film grain overlay (post-LUT, pre-encode) — `FilmProcessor.applyLUTPreservingMetadata` is the natural insertion point, just before `heifRepresentation`
- ProRAW path is intentionally not implemented — incompatible with the LUT pipeline (RAW data has no meaningful color cube application before demosaic)
- Roll/27-shot disposable behavior was removed in favor of unlimited capture per `FilmSource`; if ever revived, group via `Photo.filmPresetName` + an arbitrary stride rather than re-introducing a `Roll` model
- LUT processing is GPU-accelerated (Metal CIContext); a custom Metal compute shader (à la `LUTShader.metal` for preview) could give another 2–3× speedup but the current path is already < 200 ms on iPhone 17 Pro for 48 MP and is not the bottleneck — `heifRepresentation` is
