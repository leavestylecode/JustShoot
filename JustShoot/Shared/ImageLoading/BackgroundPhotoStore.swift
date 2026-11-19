import CoreImage
import ImageIO
import Observation
import UIKit

/// Only the small, oriented background is kept. Replacing it never touches the Photos asset.
actor BackgroundPhotoFile {
    private let url: URL
    init(url: URL) { self.url = url }

    func load() -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = ImageLoader.downsample(source, maxPixel: 768) else { return nil }
        return UIImage(cgImage: cgImage).preparingForDisplay()
    }

    func replace(with data: Data) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = ImageLoader.downsample(source, maxPixel: 768) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let image = UIImage(cgImage: thumbnail)
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        return image.preparingForDisplay() ?? image
    }

    func remove() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
}

struct BackgroundPhotoRequest: Equatable {
    let source: ObjectIdentifier?
    let effect: BackgroundPhotoEffect
}

struct BackgroundPhotoEffect: Equatable, Sendable {
    let blur: Double
    let saturation: Double

    private static let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ source: CGImage) -> UIImage? {
        let input = CIImage(cgImage: source)
        // Extend edge pixels before blurring so the fitted background has no dark border.
        let filtered = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blur * input.extent.height / 768)
        guard let output = Self.context.createCGImage(filtered, from: input.extent) else { return nil }
        return UIImage(cgImage: output)
    }
}

@MainActor @Observable
final class BackgroundPhotoStore {
    static let shared = BackgroundPhotoStore(file: BackgroundPhotoFile(
        url: URL.applicationSupportDirectory.appending(path: "Appearance/background.jpg")))

    private(set) var image: UIImage? {
        didSet {
            renderTask?.cancel()
            renderTask = nil
            requestedEffect = nil
            filteredImage = nil
        }
    }
    private(set) var filteredImage: UIImage?
    private var requestedEffect: BackgroundPhotoEffect?
    private var renderTask: Task<UIImage?, Never>?
    private(set) var isChanging = false
    private let file: BackgroundPhotoFile
    private var didLoad = false
    private var loadTask: Task<UIImage?, Never>?

    init(file: BackgroundPhotoFile) { self.file = file }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        let task = loadTask ?? Task { await file.load() }
        loadTask = task
        let result = await task.value
        // A replacement or removal may already have supplied a newer image.
        if !didLoad {
            image = result
            didLoad = true
        }
        loadTask = nil
    }

    /// All visible pages share one rendered bitmap for the current photo and adjustments.
    func prepare(_ effect: BackgroundPhotoEffect) async {
        await loadIfNeeded()
        guard !Task.isCancelled, let image, let pixels = image.cgImage, effect != requestedEffect else { return }
        renderTask?.cancel()
        requestedEffect = effect
        let task = Task { await BlockingImageWork.shared.run { effect.render(pixels) } }
        renderTask = task
        let result = await task.value
        guard !task.isCancelled, self.image === image, requestedEffect == effect else { return }
        filteredImage = result
        renderTask = nil
    }

    func replace(with data: Data) async throws {
        guard !isChanging else { throw CocoaError(.userCancelled) }
        isChanging = true
        defer { isChanging = false }
        image = try await file.replace(with: data)
        didLoad = true
    }

    func remove() async throws {
        guard !isChanging else { throw CocoaError(.userCancelled) }
        isChanging = true
        defer { isChanging = false }
        try await file.remove()
        image = nil
        didLoad = true
    }
}
