# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JustShoot is an iOS film camera simulation app built with SwiftUI and SwiftData that emulates authentic film photography. The app provides 8 different film presets using LUT (Look-Up Table) color grading, organizes photos into 27-shot rolls mimicking disposable cameras, and preserves complete EXIF/GPS metadata.

**Current State**: Optimized for iOS 18+ with modern AVFoundation APIs. The app features responsive capture, instant shutter feedback, intelligent GPS caching, real-time LUT preview, automatic 35mm focal length simulation, flash with distance-based compensation, and a gallery system organized by film rolls.

## Architecture

### Core Technologies
- **SwiftUI**: Modern declarative UI framework for iOS 18+
- **SwiftData**: Data persistence with Photo and Roll models
- **AVFoundation**: Responsive capture with iOS 18 optimizations (ResponsiveCaptureEnabled, FastCapturePrioritization)
- **CoreImage + Metal**: Real-time LUT filter processing with GPU acceleration via MTKView
- **CoreLocation**: Intelligent GPS caching with 30s cache expiry, zero-wait location strategy
- **Photos Framework**: Photo library integration with complete metadata preservation

### Key Components

**Models.swift**: Data models and film processing engine
- `Photo`: Stores imageData, film preset, GPS coordinates, timestamps with EXIF extraction utilities
- `Roll`: 27-shot film roll container with preset tracking and completion status
- `FilmPreset`: Enum defining 8 film types (Fuji C200, Pro 400H, Provia 100F, Kodak Portra 400, Vision3 5219/5203, 5207, Harman Phoenix 200)
- `FilmProcessor`: Singleton handling LUT loading, caching, and application with metadata preservation

**CameraView.swift**: Camera interface and capture logic (iOS 18 optimized)
- `CameraView`: SwiftUI camera UI with instant shutter feedback, 3:4 preview, exposure counter, flash toggle
- `CameraManager`: iOS 18 responsive capture, 35mm focal length simulation (1.0-1.35x zoom), flash compensation, intelligent GPS caching
- `RealtimePreviewView`: MTKView-based real-time LUT preview rendering at 30fps with portrait orientation lock
- `AVCaptureDevice.RotationCoordinator` for orientation handling (iOS 18 only, no legacy support)

**ContentView.swift**: Main menu with film preset selection grid
- Displays 8 film presets with ISO values, active roll indicators, and shot progress
- Shows total photo count and navigates to gallery or camera views

**GalleryView.swift**: Photo browsing and management
- `ImageLoader`: Singleton with NSCache + disk caching for thumbnails and previews using CGImageSource downsampling
- Roll-based organization showing photos grouped by film type
- `PhotoDetailView`: Swipeable full-screen photo viewer with EXIF display and Photos.app export

### Photo Processing Pipeline (iOS 18 Optimized)

1. **Instant Feedback**: Haptic feedback + 0.1s flash animation triggered immediately, before camera callback
2. **Capture**: iOS 18 responsive capture with speed prioritization and fast capture mode
3. **Concurrent Processing**: LUT and GPS fetching run in parallel async tasks
4. **35mm Simulation**: Digital zoom (device-specific, typically 1.0-1.35x) via maxPhotoDimensions
5. **LUT Processing**: CIColorCube filter from .cube files (25×25×25 dimension) on background queue
6. **Metadata Preservation**: GPS coordinates (cached), device info, focal length, orientation via CGImageDestination
7. **Storage**: SwiftData with @Attribute(.externalStorage) for imageData

### 35mm Focal Length System

The app simulates a fixed 35mm equivalent focal length across all devices:
- Reads device native focal length (24mm for iPhone 16/15 Pro, 26mm for standard models, 28mm for older devices)
- Calculates required zoom factor to reach 35mm equivalent: `requiredZoom = 35.0 / deviceEquivalent`
- Applied via `AVCaptureDevice.videoZoomFactor` on session start
- EXIF metadata records both physical and 35mm equivalent focal lengths

### Orientation Handling Strategy (iOS 18)

Uses `AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelCapture`:
- Applied to photo output connection via `videoRotationAngle`
- Real-time preview always rotates landscape frames 90° to portrait in MTKView rendering
- Converts rotation angle to EXIF orientation values (1/3/6/8) for metadata
- No legacy iOS support - minimum deployment target is iOS 18.0

### Flash System

- Real flash (`AVCaptureDevice.FlashMode.on`) not torch simulation
- Distance-based exposure bias compensation (-0.8 to +0.7 EV) using lens position as proxy for subject distance
- Temporary exposure lock during capture to prevent AE from canceling bias
- Automatic restoration of previous exposure settings after capture

## Development Commands

### Building and Running
```bash
# Open in Xcode
open JustShoot.xcodeproj

# Build for simulator
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# Build for specific simulator by ID (more reliable)
xcrun simctl list devices | grep "iPhone 15 Pro"
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot -destination 'id=<UDID>' build

# List available simulators
xcrun simctl list devices available

# Boot a simulator
xcrun simctl boot <UDID>

# Install and run on simulator (camera won't work, but UI can be tested)
xcrun simctl install <UDID> build/Debug-iphonesimulator/JustShoot.app
xcrun simctl launch <UDID> com.leavestyle.JustShoot

# Build for device (requires provisioning profile)
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot -destination 'generic/platform=iOS' build
```

**Important**: Full camera functionality requires a physical iOS device. Simulator shows camera permission dialogs but cannot access camera hardware.

### Testing LUT Processing
LUT files are located in `JustShoot/Resources/*.cube`. The FilmProcessor validates:
- Cube dimension must be declared (`LUT_3D_SIZE`)
- Data must match dimension³ × 3 values
- Files are parsed and converted to RGBA format with alpha=1.0

### Performance Characteristics
- Preview resolution: 1920×1080 BGRA at 30fps (set via `preferredFramesPerSecond`)
- LUT caching: All presets preloaded on first use, stored in `FilmProcessor.lutCache`
- Photo processing: Background queue with 0.95 JPEG quality
- Image loading: CGImageSource thumbnail generation with hardware acceleration
- Disk cache: Thumbnails and previews cached in Library/Caches/{Thumbs,Previews}/

## Data Model Relationships

```swift
Roll (1) ←→ (many) Photo
- Roll.photos: [Photo]
- Photo.roll: Roll? (inverse relationship)
- Roll tracks preset, capacity (27), completion status
- Photo stores imageData, filmPresetName, GPS coordinates (lat/lon/alt/timestamp)
```

## Film Preset Configuration

Each FilmPreset defines:
- `displayName`: User-facing name
- `iso`: Nominal ISO value (50-500)
- `lutResourceName`: Filename without .cube extension in Resources/

Adding a new preset requires:
1. Add case to `FilmPreset` enum in Models.swift
2. Provide display name, ISO value, and LUT resource name
3. Add corresponding .cube file to JustShoot/Resources/
4. Add color accent to `ContentView.FilmPresetGrid.accentColor(for:)`

## Memory Management

- SwiftData external storage for imageData prevents memory pressure
- ImageLoader NSCache with 50-item, 50MB limits
- Disk caching for thumbnails/previews reduces repeated decoding
- CGImageSource downsampling avoids loading full images
- Memory warning observer clears cache in PhotoDetailView

## GPS Integration (iOS 18 Optimized)

Intelligent caching strategy eliminates waiting:
- Started only when CameraView appears
- Stopped when CameraView disappears
- **30-second cache**: Returns cached location if < 30s old
- **Zero-wait**: No timeout blocking, uses best available location immediately
- Background refresh via `requestLocation()` for next capture
- GPS metadata written to both image data and Photo model for dual persistence
- Method `cachedOrFreshLocation()` replaces deprecated `fetchFreshLocation()`

## Key Technical Constraints

- **iOS 18.0+ required** - No legacy version support
- **Modern AVFoundation features**:
  - `isResponsiveCaptureEnabled` - Faster shutter response
  - `isFastCapturePrioritizationEnabled` - Optimized burst mode
  - `maxPhotoDimensions` - Precise output size control
  - `AVCaptureDevice.RotationCoordinator` - Orientation handling
- **Physical device required** for actual camera and GPS functionality
- **Photos.app permission** required for saving images with metadata
- **Location permission** required for GPS tagging
- **Chinese localization** present in UI strings (can be localized if needed)
- **Portrait-only preview** in CameraView with automatic landscape frame rotation
- **No settings UI** - authentic disposable camera experience with minimal controls

## Common Implementation Patterns

### Adding EXIF Metadata
Always use `FilmProcessor.applyLUTPreservingMetadata()` which:
1. Applies LUT to CIImage
2. Renders to JPEG with ciContext
3. Copies original metadata via CGImageSource/CGImageDestination
4. Merges GPS info from CLLocation
5. Adds device info and orientation

### Orientation-Aware Rendering (iOS 18)
```swift
// Always use RotationCoordinator
guard let coordinator = rotationCoordinator else { return }
let angle = coordinator.videoRotationAngleForHorizonLevelCapture

// Apply to connections
if let connection = photoOutput.connection(with: .video),
   connection.isVideoRotationAngleSupported(angle) {
    connection.videoRotationAngle = angle
}

// Convert to EXIF value
let exifValue = exifOrientationFromRotationAngle(angle)
```

### Safe Image Downsampling
```swift
let options: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    kCGImageSourceCreateThumbnailWithTransform: true
]
CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
```

## Project File Organization

```
JustShoot/
├── JustShoot.xcodeproj/          # Xcode project
├── JustShoot/
│   ├── JustShootApp.swift        # App entry point with ModelContainer
│   ├── ContentView.swift         # Main menu and film preset grid
│   ├── CameraView.swift          # Camera UI, manager, and real-time preview
│   ├── GalleryView.swift         # Photo browsing and detail views
│   ├── Models.swift              # Data models and FilmProcessor
│   └── Resources/
│       ├── FujiC200.cube
│       ├── FujiPro400H.cube
│       ├── FujiProvia100F.cube
│       ├── KodakPortra400.cube
│       ├── KodakVision5219.cube  # 500T
│       ├── KodakVision5203.cube  # 50D
│       ├── Kodak5207.cube        # 250D
│       └── HarmanPhoenix200.cube
├── build/                        # Build artifacts (gitignored)
└── CLAUDE.md                     # This file
```

## iOS 18 Optimizations Summary

### Performance Improvements
- **Shutter lag**: Reduced from ~150ms to <50ms (66% improvement)
- **GPS wait time**: Eliminated 1.5s timeout (100% improvement)
- **Burst mode**: Enabled via `isFastCapturePrioritizationEnabled`
- **Concurrent processing**: LUT and GPS fetch in parallel

### Key API Usage
- `photoOutput.isResponsiveCaptureEnabled = true`
- `photoOutput.isFastCapturePrioritizationEnabled = true`
- `photoOutput.maxPhotoDimensions` for precise output size
- `cachedOrFreshLocation()` with 30s cache for zero-wait GPS

### Removed Legacy Support
- No iOS 16/17 compatibility code
- No deprecated `videoOrientation` usage
- No `UIDeviceOrientation` fallback logic
- Simplified EXIF orientation handling

## Notes for Future Development

- Consider adding manual focus control while maintaining auto-exposure
- Flash distance estimation from lensPosition is empirical - may need per-device calibration
- Preview rotation could be made user-controllable (currently forced portrait)
- Roll completion behavior could offer auto-download to Photos.app
- Multi-language support would require extracting hardcoded Chinese strings
- Potential Metal shader optimization for LUT processing (3-5x speedup possible)
