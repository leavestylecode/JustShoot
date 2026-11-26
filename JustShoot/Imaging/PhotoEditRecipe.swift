import CoreImage
import CoreImage.CIFilterBuiltins

enum PhotoCropAspect: String, Codable, CaseIterable {
    case original, square, portrait, landscape, wide, tall

    var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .square: 1
        case .portrait: 3 / 4
        case .landscape: 4 / 3
        case .wide: 16 / 9
        case .tall: 9 / 16
        }
    }

    var label: String {
        switch self {
        case .original: String(localized: "Original")
        case .square: "1:1"
        case .portrait: "3:4"
        case .landscape: "4:3"
        case .wide: "16:9"
        case .tall: "9:16"
        }
    }
}

struct PhotoEditCrop: Codable, Hashable, Sendable {
    var aspect = PhotoCropAspect.original
    var turns = 0
    var zoom = 1.0
    // Position within the available travel, measured from the top left.
    var x = 0.5
    var y = 0.5

    func rect(in extent: CGRect) -> CGRect {
        guard extent.width >= 1, extent.height >= 1 else { return .zero }
        let centered = CameraFraming.centeredCrop(in: extent, aspect: aspect.ratio ?? extent.width / extent.height,
            zoom: min(max(zoom, 1), 4))
        let w = max(1, floor(centered.width + 0.000001))
        let h = max(1, floor(centered.height + 0.000001))
        return CGRect(x: extent.minX + round((extent.width - w) * min(max(x, 0), 1)),
                      y: extent.minY + round((extent.height - h) * (1 - min(max(y, 0), 1))), width: w, height: h)
    }
}

enum PhotoEditCurve: Codable, Hashable, Sendable {
    case preset(CurvePreset)
    case custom(CustomFilmCurve)

    var resolved: FilmCurve {
        switch self {
        case .preset(let preset): .builtIn(preset)
        case .custom(let definition): .custom(definition)
        }
    }

    var label: String {
        switch self {
        case .preset(let preset): preset.displayName
        case .custom(let definition): definition.name
        }
    }
}

struct PhotoEditRecipe: Codable, Hashable, Sendable {
    var useCameraOriginal = false
    var filmID: String?
    var intensity = 1.0
    var curve = PhotoEditCurve.preset(.none)
    var crop = PhotoEditCrop()
}

/// Both the working preview and PhotoKit output apply the same graph at their own resolution.
struct PhotoEditRender: Sendable {
    let recipe: PhotoEditRecipe
    private let lut: CubeLUT?
    private let curveData: Data?

    init(_ recipe: PhotoEditRecipe, films: [FilmSource]) throws {
        guard recipe.isValid else { throw PhotoEditError.render }
        self.recipe = recipe
        if let id = recipe.filmID {
            guard let source = films.first(where: { $0.id == id }) else { throw CubeLUT.ParseError.malformed }
            lut = try FilmProcessor.shared.loadLUT(source: source)
        } else {
            lut = nil
        }
        let curve = recipe.curve.resolved
        curveData = curve.isNeutral ? nil : curve.previewData.interleavedRGBData
    }

    func apply(to input: CIImage) throws -> CIImage {
        try framed(graded(input))
    }

    func graded(_ input: CIImage) throws -> CIImage {
        var image = input
        if let lut {
            guard let stages = FilmImagePipeline.stages(for: image, lut: lut, lutIntensity: Float(recipe.intensity),
                chromaticGain: .one, optics: .disabled, grain: .disabled, grainSeed: 1) else { throw PhotoEditError.render }
            image = stages.final
        }
        if let curveData {
            let filter = CIFilter.colorCurves()
            filter.inputImage = image
            filter.colorSpace = FilmImagePipeline.colorSpace
            filter.curvesData = curveData
            guard let output = filter.outputImage else { throw PhotoEditError.render }
            image = output
        }
        return image
    }

    func framed(_ input: CIImage) throws -> CIImage {
        let rotations: [CGImagePropertyOrientation] = [.up, .left, .down, .right]
        let image = input.oriented(rotations[recipe.crop.turns])
        let rect = recipe.crop.rect(in: image.extent)
        guard !rect.isEmpty else { throw PhotoEditError.render }
        return image.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
    }
}

enum PhotoEditError: LocalizedError {
    case render, unavailable, changed

    var errorDescription: String? {
        switch self {
        case .render: String(localized: "This photo could not be processed.")
        case .unavailable: String(localized: "This photo must finish saving to Photos before it can be edited.")
        case .changed: String(localized: "This photo changed in Photos. Reopen the editor to use the latest version.")
        }
    }
}

extension PhotoEditRecipe {
    var isValid: Bool {
        (0..<4).contains(crop.turns) && (1...4).contains(crop.zoom) && (0...1).contains(crop.x)
            && (0...1).contains(crop.y) && (0...1).contains(intensity)
    }
}
