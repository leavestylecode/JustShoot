import CoreImage
import CoreVideo
import Foundation

/// Opt-in evidence, never an automatic exposure/color correction. Summaries use
/// encoded sRGB values; camera motion makes these unsuitable for pixelwise parity.
enum CaptureComparisonDiagnostics {
    struct Statistics: Codable, Equatable, Sendable {
        let meanRGB: [Double]
        let lumaP10: Double
        let lumaP50: Double
        let lumaP90: Double
    }

    private struct PreviewRecord: Encodable {
        let frameID: UInt64
        let frameUptime: TimeInterval
        let presentedUptime: TimeInterval?
        let focalSequence: UInt64
        let sourceRevision: UInt64
        let previewCrop: CGFloat
        let inputSize: CGSize
        let outputSize: CGSize
        let rotation: UInt32
        let captureDate: Date
        let lutKey: String
        let colorAdjustment: ResolvedCameraColorAdjustment?
        let chromaticGain: SIMD3<Float>
        let input: Statistics
        let output: Statistics
    }

    static func directory(for id: UUID) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProcessingDiagnostics", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func statistics(_ image: CIImage, context: CIContext) -> Statistics {
        let size = 32
        let extent = image.extent
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(size) / extent.width, y: CGFloat(size) / extent.height))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: size * 4,
            bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
        var means = [Double](repeating: 0, count: 3)
        var luma = [Double]()
        luma.reserveCapacity(size * size)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = (0..<3).map { Double(pixels[i + $0]) / 255 }
            for channel in 0..<3 { means[channel] += rgb[channel] / Double(size * size) }
            luma.append(rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722)
        }
        luma.sort()
        return Statistics(meanRGB: means, lumaP10: luma[luma.count / 10],
            lumaP50: luma[luma.count / 2], lumaP90: luma[luma.count * 9 / 10])
    }

    static func writePreview(frame: CameraPreviewFrame, input: CIImage, output: CIImage,
                             recipe: CaptureRecipe, context: CIContext) {
        do {
            let directory = directory(for: recipe.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, image) in [("0_preview_input", input), ("0_preview_look", output)] {
                if let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace) {
                    try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
                }
            }
            let record = PreviewRecord(frameID: frame.frameID, frameUptime: frame.capturedAt,
                presentedUptime: frame.presentedAt, focalSequence: frame.focalSequence,
                sourceRevision: frame.sourceRevision, previewCrop: frame.crop,
                inputSize: CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer)),
                outputSize: frame.outputSize, rotation: frame.rotation,
                captureDate: recipe.captureDate, lutKey: frame.lutKey, colorAdjustment: recipe.colorAdjustment,
                chromaticGain: frame.chromaticGain,
                input: statistics(input, context: context), output: statistics(output, context: context))
            try writeJSON(record, name: "0_preview.json", id: recipe.id)
        } catch { Log.capture.error("capture_preview_diagnostics_failed id=\(recipe.id) error=\(error.localizedDescription, privacy: .public)") }
    }

    static func writeStages(_ stages: [(name: String, image: CIImage)], context: CIContext, id: UUID) {
        do {
            let metrics = Dictionary(uniqueKeysWithValues: stages.map { ($0.name, statistics($0.image, context: context)) })
            try writeJSON(metrics, name: "stage_metrics.json", id: id)
        } catch { Log.capture.error("capture_stage_metrics_failed id=\(id) error=\(error.localizedDescription, privacy: .public)") }
    }

    private static let work = BlockingImageWork(maximumConcurrentOperations: 1, label: "com.justshoot.capture-comparison")

    static func recordLibraryImage(_ data: Data, id: UUID) async {
        let _: Bool? = await work.run {
            guard let image = FilmImagePipeline.decodePhoto(data, applyOrientation: true) else { return false }
            do {
                // The directory may have been pruned while PhotoKit was responding.
                guard FileManager.default.fileExists(atPath: directory(for: id).path) else { return false }
                let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace,
                    .outputColorSpace: FilmImagePipeline.colorSpace, .cacheIntermediates: false, .priorityRequestLow: true])
                try writeJSON(statistics(image, context: context), name: "5_library.json", id: id)
                return true
            } catch {
                Log.capture.error("capture_library_metrics_failed id=\(id) error=\(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, name: String, id: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory(for: id).appendingPathComponent(name), options: .atomic)
    }
}
