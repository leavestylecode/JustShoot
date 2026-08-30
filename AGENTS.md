# Repository Guidelines

## Project Structure & Module Organization

`JustShoot/` contains the SwiftUI application. `JustShootApp.swift` is the entry point; camera and capture code lives in `CameraView.swift`, `CameraManager.swift`, and related camera files. Photo processing and persistence are centered in `FilmProcessor.swift`, `LivePhotoProcessor.swift`, `PhotoLibrary.swift`, and `Models.swift`. Gallery, film-card, and settings views are grouped by feature through descriptive filenames.

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

There is currently no test target or coverage threshold. New testable logic should add XCTest coverage under `JustShootTests/`, using names such as `FilmProcessorTests.swift` and `testMalformedCubeIsRejected()`. Prioritize LUT parsing, metadata preservation, migrations, and concurrency edge cases. Simulator builds cover compilation and ordinary UI flows; camera, microphone, GPS, accelerometer, Photos integration, and Live Photo behavior require a physical device. Record the tested device and iOS version in the PR.

## Commit & Pull Request Guidelines

Follow the repository’s Conventional Commit-style history: `feat:`, `fix:`, `perf:`, `ui:`, `i18n:`, `refactor:`, or `docs:`, followed by a focused summary. PRs should explain behavior and risk, link relevant issues, list build/test evidence, and include screenshots or recordings for UI changes. Call out permission, entitlement, localization, schema, or bundled-resource changes. Never commit `build/`, `DerivedData/`, Xcode user state, signing material, or captured user data.
