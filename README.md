# JustShoot

SwiftUI film camera for iOS 26 and later. Build with Xcode 27 using the `JustShoot` scheme.

## Capture architecture

- `CameraManager` owns capture session configuration, device controls and per-request capture delivery. Hardware configuration and teardown share a process-wide serial queue; generation checks discard starts superseded by navigation or background transitions. Preview buffer dimensions use AVFoundation's automatic negotiation; the app no longer forces the preview proxy. Metal drawable dimensions remain independently bounded.
- Live Photo support, session enablement and the saved on/off preference are separate. Enablement is reconciled after outputs/format configuration and checked again after commit, before starting the session. The toolbar control stays visible; unavailable capture capability does not silently delete the control or overwrite the user's preference. A requested Live Photo fails explicitly if capability is lost before capture instead of silently becoming a still.
- `CapturePipeline` coordinates one processing worker across camera views. Before exposure it reserves queue capacity and disk headroom. After delivery, `CaptureJournal` atomically records original photos, paired videos and a frozen LUT/render recipe under Application Support/PendingCaptures.
- Processing is serial and uses utility priority. Entering the background cancels GPU work while retaining its journal; foregrounding or restarting resumes pending captures. Settings shows retained captures and offers retry.
- Photos exports use stable capture filenames for retry lookup. SwiftData stores an idempotent index using the original capture timestamp. Both original and processed Live Photo files remain until export and indexing succeed.
- `PhotoLibrarySync` coalesces reconciliation across its entire async operation. Retained capture jobs are excluded from legacy-photo migration and orphan backfill. Storage initialization failures preserve the existing database and show a retry action.
- All render paths use sRGB. Preview and export apply LUT, highlight processing, Gaussian light diffusion and grain in the same order. Preview drawables are capped at a 1280-pixel long edge, with diffusion computed at half resolution; export keeps full-resolution processing. Final photos include metadata in a single encoding pass.
- Startup prepares only the preview pipelines. LUT loading is demand-driven, and synthetic Live Photo/HEVC warm-up is disabled. Postprocessing uses low-priority Core Image requests to leave GPU capacity for the viewfinder.

The queue accepts at most 16 outstanding captures with a 1 GiB soft disk budget and conservative pre-exposure disk reservations. Accepted captures are persisted even if the soft budget changes during exposure. Filesystem failures are surfaced; original files are never intentionally discarded to satisfy a queue budget. Future journal formats must be migrated explicitly; unreadable jobs are retained.

## Validation

`JustShootTests` covers LUT validation, capture-journal recovery and backpressure, timestamp-preserving index updates, color-space behavior, photo metadata, and Live Photo frame/metadata integrity and cancellation.

```bash
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

Automated agents should run build and test workflows through XcodeBuildMCP. Camera hardware, flash, audio recording, Photos permissions, background/foreground transitions during real captures, and sustained thermal behavior still require device testing. Include a burst followed by lock/unlock, permission denial followed by retry, and preview/export comparisons under strong highlights.

For device performance regressions, capture `session_queue_wait`, `session_configuration_done`, `session_start_running`, `session_stop_release`, `preview_first_frame` and `preview_perf`. These separate camera ownership/startup delays from main-thread encoding and GPU frame time. Simulator tests do not establish real-camera latency.

## Performance diagnostics

Diagnostics are enabled in Debug and Release. Filter the Xcode console for `diag `; every event carries a process `run`, a camera/capture `id`, and monotonic timing. The logging subsystem follows the app bundle identifier, with category `diagnostics`. Set the scheme environment variable `JUSTSHOOT_DIAGNOSTICS=0` to disable the additional monitoring.

On a device, reproduce the issue and use **Settings → Export Diagnostic Log** to share a `.txt` file. No debugger is required. Diagnostic events are also written on a utility queue to three rotating 2 MiB files in Caches; pending file writes are capped at 256 KiB. Export includes retained sessions in chronological order. `diagnostic_log_overflow` and the export header's `file_write_failures` disclose missing records; this is a bounded recent history, not an unlimited crash recorder. Caches can be purged by iOS, so export promptly after reproducing the issue. Exported copies in the temporary directory are limited to the three most recent files.

- `run_begin`: device model, iOS version, build configuration, memory footprint, thermal state and Low Power Mode.
- `camera_view_appear`, `device_discovery_*`, `session_*`, `main_*`, `camera_state`: permission wait, hardware queue wait, input/format/output configuration, start/stop, and the delay returning to the main actor.
- `preview_first_buffer`, `preview_first_submitted`, `preview_first_gpu_completed`, `preview_first_presented`: first-frame milestones. Actual presentation callbacks are available on device; the simulator explicitly reports their unavailability.
- `preview_perf`: approximately two-second CPU/GPU and submission-rate summaries. `preview_capture_drop` includes AVFoundation's reason and is rate-limited. A five-second `camera_heartbeat` reports frame age and resource use, including when no new frames arrive.
- `focal_begin`, `focal_dequeued`, `focal_device_locked`, `focal_ramp_issued`, `focal_constituent_changed`, `focal_settled`: correlate one transition by camera ID and `focal_seq`. Include requested/actual zoom, queue/lock delays, active lens type, format, exposure, white balance and system pressure.
- `preview_output_policy` and `session_output_ready`: record the requested output policy and the actual `preview_auto`/`preview_proxy` decision. `focal_transition_plan` records the actual-position anchor when interrupting a ramp. The hardware queue discards superseded or closed-session focal requests and computes the new ramp rate from the device position. A same-position zoom assignment cancels the old ramp's acceleration before starting the new ramp; `cancelVideoZoomRamp()` alone would only ease it out.
- `preview_flow`: numeric counters are accumulated in memory and emitted every two seconds and at focal/lifecycle boundaries. `capture_gap_ms` measures callback arrival gaps; `pts_gap_ms` measures source timestamp gaps; `submit_gap_ms` and `present_gap_ms` measure rendering submission and actual device presentation gaps. `*_age_ms` exposes a stream that has stopped producing events. Gaps span reporting windows, so a window's largest gap can exceed its duration. Counts in a window need not match because work crosses window boundaries.
- `preview_flow` also includes skip reasons, maximum CPU/GPU/drawable acquisition time, captured-frame age at submission, GPU completion-to-main-actor recycle wait, presentation latency, texture allocations and buffer-size changes. `duplicate` means the display tick saw the same frame; it is not automatically a dropped camera frame. GPU completion is not proof of presentation. Simulator logs set `presentation_supported=false`. Late callbacks from another generation/focal request increment `stale_callbacks` instead of contaminating the current transition.
- `zoom_samples` contains up to 24 `milliseconds_since_window_start:zoom:ramping` observations (first 23 plus latest); `zoom_n` reports the full observation count. These are KVO observations, not a promise that every sensor step was observed. No pixel buffers are copied or retained for diagnostics.
- `main_queue_stall` / `main_queue_recovered`: main-queue response delays of at least 250 ms. Only one probe can be outstanding; ongoing reports are limited to once every two seconds. Monitoring pauses while inactive. `watchdog_gap` identifies process-wide scheduling/suspension/debugger gaps instead of labeling them as a main-thread stall.
- `shutter_*`, `capture_*`, `live_*`, `still_*`, `photos_*`: one capture ID follows reservation, native callbacks, journaling, queue wait, processing, Photos export, indexing and thumbnail delivery.
- `live_photo_prepare_*`, `live_photo_state`, `live_photo_preference_changed`: distinguish native support, session enablement and user intent. `shutter_tap.requested_live` records intent; `session_output_ready.live_supported` and `.live` record native state, along with the final session preset. Always separate runs by `run`; exports can contain earlier test sessions.

For a useful device trace: clear the console, cold-launch the app, enter/exit the camera three times (wait about five seconds in each), switch focal lengths, take a normal photo and a Live Photo, then background/foreground once. Include the whole `diag` trace from `run_begin` and say which action felt slow and whether the debugger was attached. New diagnostic fields contain timings, IDs, counts and system states, not image content, GPS coordinates or user file paths.

For zoom flicker specifically, stay on one film/curve first. Wait five seconds after entry, switch through the available focal lengths with two seconds between taps, then switch back and forth quickly. Repeat after one still and one Live Photo capture, then export the log. Note the focal pair and approximate moment of the visible jump. Also try a launch from the Home Screen without Xcode attached to separate debugger effects. Real camera transition smoothness still requires a device; synthetic frames and simulator tests only validate instrumentation and software behavior.

A trace where zoom reaches its target and presentation continues does not prove that the image's field of view changed. It rules out rejected requests and a continuous render stall for that interval, but proxy output or image geometry still needs device comparison. A wide constituent at a telephoto focal selection can be the system's digital-crop fallback; that alone does not explain an unchanged field of view. The rollback from forced proxy buffers must be validated against the observed 100/200 mm regression on device.
