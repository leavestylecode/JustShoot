import CoreImage
@preconcurrency import Photos
import UniformTypeIdentifiers

/// A session owns one PhotoKit input, including the base version against which its adjustments apply.
actor PhotoEditSession {
    static let identifier = "com.justshoot.photo-edit"
    private let input: PHContentEditingInput
    private let asset: PHAsset
    private let films: [FilmSource]
    private let captureLook: PhotoFilmLook?
    private var cameraPreview: CGImage?
    nonisolated let hasCameraOriginal: Bool
    nonisolated let originalPreview: CGImage
    nonisolated let initialRecipe: PhotoEditRecipe

    private init(asset: PHAsset, input: PHContentEditingInput, preview: CGImage, recipe: PhotoEditRecipe, films: [FilmSource], hasCameraOriginal: Bool, captureLook: PhotoFilmLook?) {
        self.captureLook = captureLook
        self.hasCameraOriginal = hasCameraOriginal
        self.asset = asset
        self.input = input
        self.originalPreview = preview
        self.initialRecipe = recipe
        self.films = films
    }

    struct Adjustment: Codable {
        let recipe: PhotoEditRecipe
        let hasCameraOriginal: Bool
        var filmName: String? = nil
        var captureLook: PhotoFilmLook? = nil

        func encoded() throws -> PHAdjustmentData {
            PHAdjustmentData(formatIdentifier: PhotoEditSession.identifier, formatVersion: "1",
                             data: try JSONEncoder().encode(self))
        }

        static func decode(_ data: PHAdjustmentData?) -> Self? {
            guard let data, data.formatIdentifier == PhotoEditSession.identifier, data.formatVersion == "1",
                  let edit = try? JSONDecoder().decode(Self.self, from: data.data), edit.recipe.isValid,
                  !edit.recipe.useCameraOriginal || edit.hasCameraOriginal else { return nil }
            return edit
        }

        static func decode(_ data: PHAdjustmentData?, films: [FilmSource]) -> Self? {
            guard let edit = decode(data),
                  edit.recipe.filmID.map({ id in films.contains { $0.id == id } }) ?? true else { return nil }
            return edit
        }
    }

    static func open(id: String, films: [FilmSource]) async throws -> PhotoEditSession {
        try await PhotoLibrary.ensureAuthorized()
        guard let asset = AssetImageLoader.shared.asset(id: id), asset.canPerform(.content) else { throw PhotoEditError.unavailable }
        // A deferred capture stores its camera original separately from the as-shot film.
        // An ordinary capture only contains finished pixels. Never infer a raw source from its film label.
        let first = try await DeferredPhotoEditingRequest.input(for: asset) { data in
            isCaptureAdjustment(data) || Adjustment.decode(data, films: films) != nil
        }
        let capture = first.adjustmentData.map(isCaptureAdjustment) == true
        let edit = Adjustment.decode(first.adjustmentData, films: films)
        let captureLook = capture ? capturedLook(first.adjustmentData) : edit?.captureLook
        let input = capture ? try await DeferredPhotoEditingRequest.input(for: asset) : first
        guard let url = input.fullSizeImageURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let preview = ImageLoader.downsample(source, maxPixel: 1440) else { throw PhotoEditError.render }
        try Task.checkCancellation()
        return PhotoEditSession(asset: asset, input: input, preview: preview,
            recipe: edit?.recipe ?? .init(), films: films, hasCameraOriginal: capture || edit?.hasCameraOriginal == true,
            captureLook: captureLook)
    }

    private static func isCaptureAdjustment(_ data: PHAdjustmentData) -> Bool {
        data.formatIdentifier == "com.justshoot.film" && data.formatVersion == "1"
    }

    private static func capturedLook(_ data: PHAdjustmentData?) -> PhotoFilmLook? {
        guard let data, isCaptureAdjustment(data),
              let recipe = try? JSONDecoder().decode(CaptureRecipe.self, from: data.data) else { return nil }
        return PhotoFilmLook(capture: recipe)
    }

    static func lookAdjustment(_ data: PHAdjustmentData) -> PhotoLookAdjustment? {
        if let edit = Adjustment.decode(data) { return .edit(edit) }
        return capturedLook(data).map(PhotoLookAdjustment.capture)
    }

    private func cameraData() async throws -> Data {
        guard hasCameraOriginal,
              let data = await AssetImageLoader.shared.imageData(id: asset.localIdentifier, original: true, timeout: 120)
        else { throw PhotoEditError.render }
        try Task.checkCancellation()
        return data
    }

    struct Preview: Sendable {
        let image: CGImage
        let sourceSize: CGSize
    }

    private func basePreview(useCameraOriginal: Bool) async throws -> CGImage {
        guard useCameraOriginal else { return originalPreview }
        if let cameraPreview { return cameraPreview }
        let data = try await cameraData()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let small = ImageLoader.downsample(source, maxPixel: 1440) else { throw PhotoEditError.render }
        cameraPreview = small
        return small
    }

    func filmSampleBase(cameraOriginal: Bool) async throws -> CGImage {
        let base = try await basePreview(useCameraOriginal: cameraOriginal)
        let scale = min(1, 128 / CGFloat(max(base.width, base.height)))
        let small = CIImage(cgImage: base).transformed(by: .init(scaleX: scale, y: scale))
        guard let result = FilmProcessor.shared.renderingContext().createCGImage(small, from: small.extent) else {
            throw PhotoEditError.render
        }
        return result
    }

    func filmSample(_ film: FilmSource, base: CGImage) throws -> CGImage? {
        try Task.checkCancellation()
        let render = try PhotoEditRender(PhotoEditRecipe(filmID: film.id), films: [film])
        let image = try render.apply(to: CIImage(cgImage: base))
        return FilmProcessor.shared.renderingContext().createCGImage(image, from: image.extent)
    }

    func preview(_ recipe: PhotoEditRecipe) async throws -> Preview {
        try Task.checkCancellation()
        let base = try await basePreview(useCameraOriginal: recipe.useCameraOriginal)
        let image = try PhotoEditRender(recipe, films: films).apply(to: CIImage(cgImage: base))
        guard let result = FilmProcessor.shared.renderingContext().createCGImage(image, from: image.extent) else {
            throw PhotoEditError.render
        }
        return Preview(image: result, sourceSize: CGSize(width: base.width, height: base.height))
    }

    func save(_ recipe: PhotoEditRecipe) async throws {
        let render = try PhotoEditRender(recipe, films: films)
        let output = PHContentEditingOutput(contentEditingInput: input)
        if asset.mediaSubtypes.contains(.photoLive) {
            guard let live = PHLivePhotoEditingContext(livePhotoEditingInput: input) else { throw PhotoEditError.render }
            let orientation = live.orientation
            live.frameProcessor = { frame, error in
                do {
                    // PhotoKit retains the frame orientation on output. Crop in display coordinates first.
                    let upright = frame.image.oriented(orientation)
                    let inverse: CGImagePropertyOrientation = orientation == .right ? .left : orientation == .left ? .right : orientation
                    return try render.apply(to: upright).oriented(inverse)
                } catch let failure {
                    error?.pointee = failure as NSError
                    return nil
                }
            }
            try await live.saveLivePhoto(to: output, options: nil)
        } else {
            let data: Data
            if recipe.useCameraOriginal { data = try await cameraData() }
            else {
                guard let url = input.fullSizeImageURL else { throw PhotoEditError.render }
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            guard let file = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = FilmImagePipeline.decodePhoto(data) else { throw PhotoEditError.render }
            var properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [String: Any] ?? [:]
            let fileOrientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
            let orientation = recipe.useCameraOriginal ? fileOrientation : input.fullSizeImageOrientation
            let source = decoded.oriented(forExifOrientation: orientation)
            let grade = try render.graded(source)
            let image = try render.framed(grade)
            properties[kCGImagePropertyOrientation as String] = 1
            var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
            var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifPixelXDimension as String] = Int(image.extent.width)
            exif[kCGImagePropertyExifPixelYDimension as String] = Int(image.extent.height)
            exif[kCGImagePropertyExifColorSpace as String] = 1
            properties[kCGImagePropertyExifDictionary as String] = exif
            properties[kCGImagePropertyPixelWidth as String] = Int(image.extent.width)
            properties[kCGImagePropertyPixelHeight as String] = Int(image.extent.height)
            let tagged = image.settingProperties(properties)
            let context = FilmProcessor.shared.renderingContext()
            let color = FilmImagePipeline.colorSpace
            var options: [CIImageRepresentationOption: Any] = [:]
            if #available(iOS 18, *), let hdr = FilmHDRHighlights.applyingNativeGainMap(from: data, to: grade,
                orientedSourceExtent: source.extent, exifOrientation: orientation) {
                options[.hdrImage] = try render.framed(hdr)
            }
            if output.supportedRenderedContentTypes.contains(.heic),
               let encoded = try? context.heif10Representation(of: tagged, colorSpace: color, options: options) {
                try encoded.write(to: output.renderedContentURL(for: .heic), options: .atomic)
            } else {
                try context.writeJPEGRepresentation(of: tagged, to: output.renderedContentURL, colorSpace: color,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
            }
        }
        let filmName = films.first { $0.id == recipe.filmID }?.displayName
        output.adjustmentData = try Adjustment(recipe: recipe, hasCameraOriginal: hasCameraOriginal,
                                               filmName: filmName, captureLook: captureLook).encoded()
        guard let latest = AssetImageLoader.shared.asset(id: asset.localIdentifier),
              latest.modificationDate == asset.modificationDate else { throw PhotoEditError.changed }
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: latest).contentEditingOutput = output
        }
    }
}

enum PhotoLookAdjustment: Sendable {
    case capture(PhotoFilmLook)
    case edit(PhotoEditSession.Adjustment)

    /// A crop-only edit keeps the captured color. A camera-original edit replaces it.
    func looks(asShot: PhotoFilmLook) -> (capture: PhotoFilmLook?, edit: PhotoFilmLook?) {
        switch self {
        case .capture(let look): return (look, nil)
        case .edit(let adjustment):
            let base = adjustment.captureLook ?? asShot
            let recipe = adjustment.recipe
            guard recipe.useCameraOriginal || recipe.filmID != nil || recipe.curve != .preset(.none)
            else { return (base, nil) }
            let edit = PhotoFilmLook(filmID: recipe.filmID, filmName: adjustment.filmName,
                                     curve: recipe.curve, intensity: recipe.intensity)
            return (recipe.useCameraOriginal || !base.hasRecord ? nil : base, edit)
        }
    }
}
