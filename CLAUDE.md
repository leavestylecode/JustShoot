# JustShoot development notes

Follow `AGENTS.md` for repository conventions and build/test workflows. `README.md` describes the capture architecture, validation and diagnostics. This file records implementation boundaries; code remains the source of truth.

## Runtime structure

- `JustShootApp` opens the versioned SwiftData store without deleting it on failure.
- `CameraView` owns presentation, gestures and film/curve/color selection. Its `CameraCoordinator` freezes an immutable capture recipe and LUT for every accepted shutter request and rechecks native admission after suspension points.
- `CameraManager` owns AVFoundation, device controls and native capture callbacks. Hardware configuration, focal changes and teardown use one process-wide serial queue. Session generations invalidate work superseded by navigation or backgrounding.
- `CameraEntryCoordinator` owns session-generation preparation and active-time accounting. `CameraPreviewFrameStore` exchanges bounded native/presented frames under locks; `CameraLocationProvider` owns location authorization and updates. These components do not own a SwiftUI or Metal view.
- `CapturePipeline` owns one durable processing worker across camera views. `CaptureJournal` retains originals, the frozen LUT and progress until Photos export and SwiftData indexing succeed.
- `PhotoLibrary` writes finished media into Photos. `PhotoSaver` stores the lightweight asset/film index; internal image data is a fallback for failed exports and older versions.
- `PhotoLibraryReconciler` handles Photos/index reconciliation; `LibraryMaintenance` handles launch cleanup. `PhotoDeletionService` holds the capture/recovery gate through Photos confirmation, index commit and cache invalidation for both gallery deletion entry points.
- `PhotoImage` selects PhotoKit or internal storage. Image decoding uses bounded blocking work; image requests and view lifetimes propagate cancellation.

## Entry preparation

Use `PreparationScreen` for app and camera entry, with the matching static launch screen. Await actual initialization instead of delaying for a logo. Home needs its store, lightweight custom-filter snapshot, decoded cover snapshot and preview pipelines; retain the prepared images through first display. Keep historical-photo maintenance and pending-save processing outside this gate.

Camera preparation owns a session-generation state machine. Keep Metal mounted and opaque under the loading overlay so it can draw. Reveal only after the current LUT, native session and capture configuration, rendering resources and post-configuration GPU frame are ready. Pause timeout accounting for inactive permission sheets/backgrounding. Reject stale native/GPU results and preserve retry/back paths. Normal filter and focal adjustments do not restart the entry cover. Entry checks pipeline initialization independently of queue capacity so retained jobs cannot trap users behind a loader.

## Capture boundaries

Admission must cover storage reservation and native preparation, including hardware Camera Control input. Recheck the admission/session token after every await before issuing exposure. Cancel requests that have not exposed when leaving the camera or entering the background; retain and checkpoint already captured resources.

Native callbacks are keyed by `AVCapturePhotoSettings.uniqueID`. Restore temporary flash state and checkpoint the still before releasing the shutter. Live video delivery and postprocessing may continue after the next shutter is available. A failed dynamic resource must preserve the usable still and report the downgrade.

Keep user EV separate from temporary flash compensation. Hardware controls and screen gestures must update the same user state.

## Lens, format and orientation

Use the discovered virtual camera and device-derived focal options. Focal changes ramp zoom under `.restricted` with `.videoZoomChanged`. On iOS 27, supported telephoto selections can lock the named constituent after zoom settles. Releasing that lock and applying another zoom are separate configuration operations.

Capture waits for hardware acknowledgement, target zoom, a stopped ramp and an uninterrupted ZSL grace period. Any physical-source change restarts that grace, including after zoom settled. Native KVO records the source barrier before dispatching to MainActor, and the hardware invocation checks it again. Selecting a physical telephoto source starts its own acknowledgement/grace period. Do not bypass this gate or restore the older overshoot/deep-ramp strategy.

Use the automatic ordinary-photo policy: `.balanced`, the largest supported 4:3 size in the nominal 24 MP class, and efficient HEIC compression. Use a supported 12 MP size when a format only exposes 12/48 MP; never invent an unsupported size. Set both output and per-capture dimensions. There is no user quality selector; ignore obsolete quality preferences for new captures. Keep automatic deferred photo delivery disabled: this app needs the image bytes delivered to its own pipeline.

The interface stays portrait. Accelerometer readings drive control/gesture orientation; `RotationCoordinator` controls capture rotation. Video preview stabilization is independent of still capture.

## Rendering

The shared order is chromatic response → composed LUT → highlight headroom → halation/bloom → grain. Curves and relative manual temperature/tint are baked into the LUT. The capture device stays on automatic white balance.

The curve display names are Original, Soft, Contrast, Faded and X-Pro (原调、柔和、鲜明、褪色、负冲). Faded combines a lifted black floor with an S-shaped middle; lifting all shadows is a different response. Keep those roles distinct: Soft reduces midtone contrast; Contrast increases it. Keep Chinese built-in display names at two characters, with concise descriptions of their actual effects. Display names can change independently of stable preset IDs and frozen render parameters. Curves map film output, with the custom master before individual RGB curves. Reuse precomputed 256-sample tables; preserve the natural-spline behavior of existing custom definitions. Effective identity must leave LUT bytes unchanged, including finite HDR values. Legacy active styles migrate to a custom definition before their menu entries change. Curve data and selection share one payload; never overwrite an unreadable or unsupported curve library.

All paths use sRGB. Preview resolution and diffusion work are bounded; stills retain full resolution. Live video must explicitly carry matching color tags. Preserve the movie transform, audio, content identifier and timed still-image marker.

Static pixels are physically oriented before encoding and marked Orientation=1. Merge metadata before one encoding pass: 10-bit HEIC, then 8-bit HEIC, then JPEG. Do not add a second image compression pass or use repeated full-image encoding to chase an exact file size. Automatic HEIF quality is 0.85; JPEG fallback is 0.9. The codec varies byte allocation with content while preserving the delivered pixel dimensions and film graph. Legacy journals retain their frozen manual quality. Do not claim these public defaults exactly reproduce Apple Camera's private processing.

Bound LUT and texture caches by bytes. Eviction may discard derived data, never a captured recipe or original. Loading an unused imported LUT should not warm another copy. Check cancellation between expensive stages; a synchronous codec operation already running may finish before cancellation takes effect.

## Persistence and recovery

The manifest is the journal commit marker. Preserve existing v1 manifests and optional-field compatibility. Write resources before updating progress. Never delete an accepted original to satisfy a soft storage budget.

Photos export uses a stable capture UUID filename to find completed exports on retry. Index updates preserve capture identity and timestamp. Only remove the journal after both export and index commit succeed.

Deletion and recovery share a gate. Successful deletion must release the in-memory queue slot as well as files and index rows. Failed or cancelled deletion preserves retryable data.

Recovery snapshots and terminal results share a revision watermark. A late inventory must not recreate a completed slot or hide a failed/cancelled one. Refresh the real inventory after successful cleanup so resolved attention issues disappear while surviving staging entries remain visible.

Unreadable and unsupported journals must remain visible as recovery issues, with original export and an explicit discard action. Limited Photos authorization cannot prove a missing asset has been deleted; preserve the index when the asset is inaccessible.

Successful captures are rendered final media. Originals and complete recipes are removed with the journal; later nondestructive film changes are not currently supported.

## Resources and validation

Built-in LUTs, film cards and `cards.json` are under `JustShoot/Resources/`. Custom LUT files are under Documents/CustomLUTs; user curve definitions are managed by `FilmCurveLibrary`. Filesystem-synchronized Xcode groups include new Swift files automatically.

Run app builds and tests through XcodeBuildMCP with explicit project, scheme and simulator defaults. Keep strict concurrency complete and treat new Swift warnings as failures. Test state transitions, metadata, recovery, cancellation and resource budgets rather than duplicating implementation details.

Simulator tests validate software behavior. Camera Control, flash, real lens selection, microphone, Photos permission changes, background captures and sustained memory/thermal performance require physical-device validation. Use Settings → Export Diagnostic Log and retain the complete run when investigating latency.
