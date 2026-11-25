import CoreImage
import ImageIO

enum RawFilmRenderer {
    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private static let kernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "justShootRawFilm", fromMetalLibraryData: data)
    }()

    static func prepare() throws {
        guard kernel != nil else { throw CubeLUT.ParseError.malformed }
    }

    static func isDNG(_ source: CGImageSource) -> Bool {
        if CGImageSourceGetType(source) as String? == "com.adobe.raw-image" { return true }
        // Some linear DNGs are identified as TIFF; require their DNG metadata as well.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        return properties?[kCGImagePropertyDNGDictionary as String] != nil
    }

    static func develop(_ data: Data, lut: RawFilmLUT, recipe: RawCaptureRecipe,
                        cancellation: CaptureRenderCancellation? = nil) -> CIImage? {
        guard (try? recipe.validate(lut: lut)) != nil,
              let image = develop(data, recipe: recipe, cancellation: cancellation) else { return nil }
        return mapDeveloped(image, lut: lut, recipe: recipe)
    }

    /// Decode once at full precision. All new recipes retain Apple's per-image
    /// tone and gamut rendering. Legacy version 3 recipes retain the DNG exposure reference
    /// and local gain map while replacing Apple's global curve with the film curve.
    static func develop(_ data: Data, recipe: RawCaptureRecipe,
                        extendedDynamicRangeAmount: Float = 0,
                        cancellation: CaptureRenderCancellation? = nil) -> CIImage? {
        guard cancellation?.isCancelled != true, recipe.isValid,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              isDNG(source),
              let raw = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") else { return nil }
        configure(raw, recipe: recipe)
        if extendedDynamicRangeAmount > 0 { raw.extendedDynamicRangeAmount = extendedDynamicRangeAmount }
        guard cancellation?.isCancelled != true, let image = raw.outputImage else { return nil }
        return image
    }

    static func configure(_ raw: CIRAWFilter, recipe: RawCaptureRecipe) {
        // Keep the per-image DNG baselineExposure: ProRAW stores different amounts
        // of highlight headroom, so unscaled sensor values have no fixed middle gray.
        // Baseline exposure is a linear gain, not Apple's display tone curve.
        // Never normalize to the image's peak: highlights must remain above 1.
        raw.exposure = 0
        if recipe.version == 4 {
            // Feed SDR looks a complete SDR development, preserving per-image
            // exposure, local gain, global tone and gamut mapping. No 8-bit
            // intermediate file is created; CI retains a floating-point graph.
            raw.extendedDynamicRangeAmount = 0
        }
        if recipe.resolvedInputSpace == .sceneLinearRec2020 {
            raw.shadowBias = 0
            raw.boostAmount = 0
            // Apple's per-image gain map adapts shadows/highlights to the captured
            // scene. Removing it crushes indoor shadows through contrasty film LUTs.
            // Keep it for new captures; old journals retain their frozen policy.
            if recipe.version < 3, raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            raw.isGamutMappingEnabled = false
        }
        raw.scaleFactor = 1
        raw.isDraftModeEnabled = false
        raw.orientation = .up // FilmProcessor rotates pixels exactly once using source EXIF.
        if let temperature = recipe.temperature { raw.neutralTemperature = temperature }
        if let tint = recipe.tint { raw.neutralTint = tint }
    }

    /// Input is a color-managed, linear-transfer image, never a rendered JPEG.
    /// Version 3 includes ProRAW's local dynamic-range adaptation; its values are
    /// not a radiometric measurement of the unmodified scene.
    /// Explicit matching makes the kernel's numeric input independent of the CIContext.
    static func mapDeveloped(_ image: CIImage, lut: RawFilmLUT, recipe: RawCaptureRecipe) -> CIImage? {
        guard (try? recipe.validate(lut: lut)) != nil, let kernel,
              let linear = image.matchedFromWorkingSpace(to: linearSpace) else { return nil }
        let tables = lut.images()
        var curves = [Float](repeating: 1, count: 256 * 4)
        for i in 0..<256 {
            curves[i * 4] = recipe.redCurve[i]
            curves[i * 4 + 1] = recipe.greenCurve[i]
            curves[i * 4 + 2] = recipe.blueCurve[i]
        }
        let curveImage = CIImage(bitmapData: curves.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: 256 * 16, size: CGSize(width: 256, height: 1), format: .RGBAf, colorSpace: nil).samplingLinear()
        let extents = [image.extent] + tables.map(\.extent) + [curveImage.extent]
        guard let mapped = kernel.apply(extent: image.extent, roiCallback: { index, rect in
            index == 0 ? rect : extents[Int(index)]
        }, arguments: [linear] + tables + [curveImage]) else { return nil }
        // Kernel returns encoded sRGB. Declare its source space before other CI stages.
        return mapped.matchedToWorkingSpace(from: FilmImagePipeline.colorSpace)
    }
}
