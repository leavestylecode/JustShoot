# Repository Guidelines

## Product Priorities

Performance and fluid interaction are the primary goals. Keep disk access, image decoding,
and repeated catalog work out of UI updates; bound background work and cancel unused requests.
Prefer previews, graphs, icons, and visible state over explanatory paragraphs. Keep labels short,
move secondary guidance behind an explicit help control, and preserve accessibility labels,
permission guidance, error recovery, and destructive-action explanations. Validate improvements
with focused regression tests and simulator inspection; claim device performance gains only
after measuring them on a physical device.

## Project Structure & Module Organization

`JustShoot/` contains one SwiftUI app target, organized by responsibility:

- `App/`: entry point, startup preparation and navigation composition.
- `Features/`: camera, films, gallery, film-card library, curves and settings. Camera separates `Presentation/`, `Coordination/`, `Hardware/`, `Preview/` and pure `Policies/`; gallery detail components live in `Gallery/Detail/`.
- `Capture/`: durable capture orchestration, admission storage, journal and recovery contracts.
- `Imaging/`: film rendering, LUTs, metadata parsing, encoding and shared Metal resources/shaders.
- `Persistence/`: SwiftData models/schema/index transactions, Photos export/reconciliation and custom LUT files.
- `Shared/`: image loading, reusable UI and diagnostics.

Views own presentation and selection. `CameraCoordinator` freezes shutter recipes and coordinates native capture with `CapturePipeline`; `CameraManager` retains native session ownership and its serial hardware queue. Share photo deletion through `PhotoDeletionService`. Keep policies independent of views, and avoid importing SwiftUI or persistent model types into rendering code. These are source boundaries within one target, not separate packages; see README for dependency and lifetime rules.

Bundled LUTs, `cards.json`, and film-card images live under `JustShoot/Resources/`; asset catalogs and localized strings live in `Assets.xcassets` and the `.xcstrings` files. Maintenance utilities are in `scripts/`. `JustShoot.xcodeproj` defines the single `JustShoot` app target and scheme. Its file-system-synchronized group automatically includes files added beneath `JustShoot/`.

## Build, Test, and Development Commands

```bash
open JustShoot.xcodeproj
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot \
  -destination 'generic/platform=iOS' build
python3 scripts/analyze_card_dupes.py
```

Use an installed simulator name in the first build command. Device builds require local signing. Automated agents should use XcodeBuildMCP for build, test, simulator, and log workflows, with project, scheme, and destination defaults stated explicitly.

## Coding Style & Naming Conventions

Use four-space indentation and standard Swift API naming: `UpperCamelCase` for types, `lowerCamelCase` for properties and methods, and descriptive suffixes such as `View`, `Manager`, or `Processor`. Keep implementation details `private`; keep protocol-conformance extensions beside their host type when they need private state. Preserve complete strict-concurrency compliance, actor isolation, and `Sendable` correctness. Log event names use `snake_case` with `key=value` fields. Add user-facing text to the string catalogs rather than hard-coding it. No formatter or linter is configured, so use Xcode formatting and treat new warnings as failures.

## Testing Guidelines

The shared `JustShoot` scheme includes the `JustShootTests` XCTest target; there is no coverage threshold. New testable logic should add XCTest coverage under `JustShootTests/`, using names such as `FilmProcessorTests.swift` and `testMalformedCubeIsRejected()`. Prioritize LUT parsing, metadata preservation, migrations, and concurrency edge cases. Simulator builds cover compilation and ordinary UI flows; camera, microphone, GPS, accelerometer, Photos integration, and Live Photo behavior require a physical device. Record the tested device and iOS version in the PR.

## Commit & Pull Request Guidelines

Follow the repository’s Conventional Commit-style history: `feat:`, `fix:`, `perf:`, `ui:`, `i18n:`, `refactor:`, or `docs:`, followed by a focused summary. PRs should explain behavior and risk, link relevant issues, list build/test evidence, and include screenshots or recordings for UI changes. Call out permission, entitlement, localization, schema, or bundled-resource changes. Never commit `build/`, `DerivedData/`, Xcode user state, signing material, or captured user data.
