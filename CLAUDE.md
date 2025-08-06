# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JustShoot is an iOS disposable film camera simulation app built with SwiftUI and SwiftData. The app simulates authentic film photography with two camera types (Fuji Provia 100F and Kodak Portra 400) using LUT color grading for realistic film emulation.

**Current State**: The project is currently in development transition - the basic SwiftUI template is committed, but advanced camera functionality has been implemented in working sessions and needs to be re-implemented.

## Architecture

### Core Technologies
- **SwiftUI**: Modern declarative UI framework for iOS 17+
- **SwiftData**: Data persistence with Photo, FilmRoll, and CameraType models
- **AVFoundation**: Camera capture with digital zoom (35mm equivalent focal length)
- **CoreImage + Metal**: Real-time LUT filter processing with GPU acceleration
- **Photos Framework**: Photo library integration for saving processed images

### Photo Processing Pipeline
The app implements a sophisticated photo processing workflow:
1. **Capture**: AVCapturePhotoOutput with metadata extraction
2. **35mm Simulation**: Digital zoom (1.35x crop factor) instead of physical lens switching
3. **LUT Processing**: Film emulation using .cube files with CIColorCube filters
4. **Quality Optimization**: High-quality JPEG output (98% quality) with single compression pass
5. **Storage**: Dual-data strategy (imageData for primary, processedImageData for optimized display)

### Data Models Architecture
```swift
@Model FilmRoll {
    var photos: [Photo]           // 1-to-many relationship
    var maxShots: Int = 27        // Disposable camera constraint
    var cameraType: CameraType    // Fuji Provia 100F or Kodak Portra 400
    var isCompleted: Bool         // Roll completion status
}

@Model Photo {
    var imageData: Data              // High-quality processed image
    var processedImageData: Data?    // Optional optimized version
    var cameraType: CameraType       // Film type for LUT processing
    var metadata: PhotoMetadata      // EXIF data preservation
    var filmRoll: FilmRoll?         // Parent roll relationship
}
```

## Development Commands

### Building and Running
```bash
# Open in Xcode
open JustShoot.xcodeproj

# Build for simulator (recommended device: iPhone 15 Pro)
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# Build for specific simulator ID (more reliable)
xcodebuild -project JustShoot.xcodeproj -scheme JustShoot -destination 'id=D3C6DAF8-7FC7-4941-913F-A4C1D3BC82FA' build

# Note: Camera functionality requires physical iOS device - simulator shows permission UI but no live camera
```

### Performance Optimization Settings
- Preview resolution: 1920×1080 (1080p) for performance
- Frame rate limit: 30fps to prevent thermal throttling
- Photo quality: Maximum quality with iOS 17 .quality prioritization
- LUT caching: Preloaded on app launch for all camera types

## Core Implementation Patterns

### Memory Safety
- All image processing uses comprehensive bounds checking
- PhotoCropHelper applies safe cropping with intersection validation
- LUT processor includes fallback processing for failed operations
- Concurrent access protection for shared data structures

### Error Handling Strategy
- Step-by-step photo processing with detailed logging
- Graceful fallbacks at each processing stage
- EXC_BAD_ACCESS prevention through nil-checking and bounds validation
- User-friendly error states in UI components

### Image Quality Management
- Single compression pass to maintain quality
- 35mm crop applied before LUT processing to reduce data size
- High-quality JPEG storage (98% compression) for final output
- Smart processedImage() selection based on data quality thresholds

## Film Camera Features

- **Film Roll System**: Each roll limited to 27 shots, must complete roll before camera switching
- **Camera Types**: 
  - Fuji Provia 100F (ISO 100, green theme, enhanced contrast/saturation)
  - Kodak Portra 400 (ISO 400, orange theme, warm color grading)
- **35mm Focal Length**: Achieved through 1.35x digital zoom crop, not physical lens switching
- **LUT Processing**: Real-time preview and high-quality photo processing using .cube files in Resources/
- **Authentic UX**: No settings menu, only flash toggle and shutter button (true disposable camera experience)

## LUT Resources

- `Resources/FujiProvia100F.cube`: Professional film emulation LUT for Fuji camera type
- `Resources/KodakPortra400.cube`: Warm portrait film emulation LUT for Kodak camera type
- LUT files are 25×25×25 dimension color cubes parsed at runtime
- Metal GPU acceleration used when available for real-time processing

## Key Technical Constraints

- iOS 17+ required for SwiftData @Model macro and enhanced photo processing
- Physical device required for actual camera functionality
- CloudKit integration configured but camera permissions take precedence
- App Sandbox enabled with read-only file access for LUT resources