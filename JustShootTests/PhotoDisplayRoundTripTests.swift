import XCTest
import Photos
import CoreImage
import ImageIO
import SwiftData
@testable import JustShoot

/// 复现真机「拍完 → 相册查看全黑」的全链路集成测试。
///
/// 用与真机完全相同的渲染管线(色温响应 kernel + 线性域光学 + 颗粒 → 10-bit HEIC,5712×4284)
/// 产出字节，走 PhotoLibrary.save → PHAsset.fetchAssets(withLocalIdentifiers:) →
/// PHImageManager 预览请求，断言每一环。任何一环失败即定位真机黑屏的层级。
final class PhotoDisplayRoundTripTests: XCTestCase {

    @MainActor
    func testNumberedCapturesWithTheSameFilenameRetryByAssetIdentifier() async throws {
        try ensurePhotoLibraryAuthorized()
        let data = try Self.syntheticCapture(width: 64, height: 48)
        let date = Date().addingTimeInterval(-120)
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        func save(_ captureID: UUID, journal: CaptureJournal) async throws -> String {
            try await PhotoLibrary.save(imageData: data, creationDate: date, latitude: nil, longitude: nil,
                altitude: nil, locationTimestamp: nil, captureID: captureID, fileNumber: 42, journal: journal)
        }
        let first = UUID(), second = UUID()
        for id in [first, second] {
            try FileManager.default.createDirectory(at: journal.directory(for: id), withIntermediateDirectories: true)
        }
        let a = try await save(first, journal: journal)
        defer { removeFixtureUnlessRetained(a) }
        let b = try await save(second, journal: journal)
        defer { removeFixtureUnlessRetained(b) }
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(PhotoLibrary.stillFilename(id: a), "OOO_0042.JPG")
        XCTAssertEqual(PhotoLibrary.stillFilename(id: b), "OOO_0042.JPG")
        let reopened = CaptureJournal(root: journal.root)
        let recovered = try await save(first, journal: reopened)
        XCTAssertEqual(try reopened.assetPlaceholder(for: first), a)
        XCTAssertEqual(recovered, a)
        // Only the second photo still has a recovery receipt. The first is an orphan
        // with the same filename and date, and must be backfilled exactly once.
        try reopened.finish(first)
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let reconciler = await PhotoLibraryReconciler.background(container: container)
        await reconciler.reconcileWithLibrary(journal: reopened)
        await reconciler.reconcileWithLibrary(journal: reopened)
        let indexed = try container.mainContext.fetch(FetchDescriptor<Photo>()).compactMap(\.assetLocalIdentifier)
        XCTAssertEqual(indexed.filter { $0 == a || $0 == b }, [a])
    }

    func testFilmAdjustmentUpdatesTheSameAssetAndKeepsTheOriginal() async throws {
        try ensurePhotoLibraryAuthorized()
        let source = try Self.syntheticCapture(width: 768, height: 576)
        let captureID = UUID()
        let date = Date()
        let id = try await PhotoLibrary.save(imageData: source, creationDate: date,
            latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil, captureID: captureID)
        defer { removeFixtureUnlessRetained(id) }
        let image = CIImage(color: CIColor(red: 0.2, green: 0.7, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 768, height: 576))
        let edited = try XCTUnwrap(PhotoImageEncoder.encode(image, context: CIContext(),
            colorSpace: FilmImagePipeline.colorSpace, mode: .quality)?.data)
        let recipe = CaptureRecipe(id: captureID, captureDate: date, filterName: "test-adjustment", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: 2, chromaticSceneCCT: nil, photoDisplayTime: nil)
        try await PhotoLibrary.saveDeferredAdjustment(imageData: edited, id: id, recipe: recipe)
        let original = await AssetImageLoader.shared.imageData(id: id, original: true)
        let current = await AssetImageLoader.shared.imageData(id: id)
        // PhotoKit may rewrite container metadata. The original's pixel content
        // and dimensions must remain separate from the green film adjustment.
        let originalImage = try XCTUnwrap(CIImage(data: XCTUnwrap(original)))
        let sourceImage = try XCTUnwrap(CIImage(data: source))
        XCTAssertEqual(originalImage.extent.size, CGSize(width: 768, height: 576))
        var originalPixel = [UInt8](repeating: 0, count: 4)
        var sourcePixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext()
        let sample = CGRect(x: 384, y: 288, width: 1, height: 1)
        context.render(originalImage, toBitmap: &originalPixel, rowBytes: 4,
            bounds: sample, format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
        context.render(sourceImage, toBitmap: &sourcePixel, rowBytes: 4,
            bounds: sample, format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(originalPixel[channel]) - Int(sourcePixel[channel])), 2)
        }
        let bytes = try XCTUnwrap(current)
        let decoded = try XCTUnwrap(CIImage(data: bytes))
        XCTAssertEqual(decoded.extent.size, CGSize(width: 768, height: 576))
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(decoded, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
        XCTAssertGreaterThan(pixel[1], pixel[0] + 60, "The current asset must contain the film adjustment")
        XCTAssertEqual(PhotoLibrary.findCapture(id: captureID, creationDate: date), id)
        // Retrying a save updates the existing asset without adding another photo.
        try await PhotoLibrary.saveDeferredAdjustment(imageData: edited, id: id, recipe: recipe)
        XCTAssertEqual(PhotoLibrary.findCapture(id: captureID, creationDate: date), id)
    }

    func testRenderedHEICRoundTripsThroughPhotoLibrary() async throws {
        try ensurePhotoLibraryAuthorized()

        // 1) 构造 5712×4284 的采集原片(带高光/暗部/色块的合成图，触发 halation/bloom/肩部/趾部路径)
        let width = 5712, height = 4284
        let source = try Self.syntheticCapture(width: width, height: height)

        // 2) 普通拍照的自动编码，保留实际 24.47MP 像素和完整胶片处理链。
        let preset = FilmPreset.fujiC200
        let profile = preset.renderProfile
        let lut = try FilmProcessor.shared.loadCubeLUT(resourceName: preset.lutResourceName)
        let renderedResult = FilmProcessor.shared.applyLUTPreservingMetadata(
            imageData: source,
            lutCacheKey: preset.lutResourceName,
            capturedLUT: lut,
            grain: profile.grain,
            grainSeed: 0x1234_5678,
            optics: profile.optics,
            chromatic: profile.effectiveChromatic,
            chromaticSceneCCT: 6_300
        )
        let rendered = try XCTUnwrap(renderedResult, "渲染输出为空——新管线(色温响应/线性光学)产片失败")
        let encodedSource = try XCTUnwrap(CGImageSourceCreateWithData(rendered as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encodedSource, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, height)

        // 3) 入库(与 CapturePipeline 同一路径),返回 localIdentifier
        let captureID = UUID()
        let creationDate = Date()
        let savedID = try await PhotoLibrary.save(
            imageData: rendered,
            creationDate: creationDate,
            latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil,
            captureID: captureID
        )
        defer { removeFixtureUnlessRetained(savedID) }
        XCTAssertFalse(savedID.isEmpty)

        // 4) 显示链第一环:按 localIdentifier fetch PHAsset(viewer 的取图入口)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [savedID], options: nil)
        XCTAssertEqual(fetched.count, 1, "fetchAssets(withLocalIdentifiers:) 取不到刚保存的资产——viewer 会全黑")

        // 5) 显示链第二环:PHImageManager 预览请求(PhotoImage.preview 的底层)
        let preview = await AssetImageLoader.shared.preview(id: savedID, maxPixel: 2_868)
        XCTAssertNotNil(preview, "PHImageManager 预览请求失败——主图会显示 Unable to load")

        // 6) 显示链第三环:缩略图请求(胶片条底层)
        let thumb = await AssetImageLoader.shared.thumbnail(id: savedID, maxPixel: 600)
        XCTAssertNotNil(thumb, "缩略图请求失败——胶片条会全黑")

        // 7) 成片字节本身可被 ImageIO 解码(排除渲染输出损坏)
        let decodable = UIImage(data: rendered)
        XCTAssertNotNil(decodable, "渲染输出的 HEIC 无法解码")
    }

    // MARK: - 辅助

    /// Unattended device runs can retain their synthetic images for inspection.
    /// Deleting an asset on a physical iPhone opens a system confirmation over subsequent tests.
    private func removeFixtureUnlessRetained(_ identifier: String) {
        guard ProcessInfo.processInfo.environment["JUSTSHOOT_KEEP_PHOTO_FIXTURES"] != "1" else { return }
        Task { try? await PhotoLibrary.delete(localIdentifiers: [identifier]) }
    }

    /// 测试进程照片库授权。注意**不主动 requestAuthorization**——弹窗在测试宿主里无人应答会挂死。
    /// 需先 `xcrun simctl privacy <udid> grant photos leavestylecode.JustShoot`(在 app 安装后执行)。
    private func ensurePhotoLibraryAuthorized() throws {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return
        default:
            throw XCTSkip("照片库未授权(模拟器需 simctl privacy grant photos leavestylecode.JustShoot,且须在 app 已安装后执行)")
        }
    }

    /// 生成一张带结构的合成"原片":水平亮度渐变 + 高光点 + 色块,编码为 JPEG。
    private static func syntheticCapture(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        // 暗部→亮部渐变
        let colors = [
            CGColor(colorSpace: cs, components: [0.02, 0.03, 0.05, 1])!,
            CGColor(colorSpace: cs, components: [0.85, 0.75, 0.6, 1])!,
        ]
        let gradient = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: [])
        // 高光点(触发 halation/bloom 能量提取)
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fillEllipse(in: CGRect(x: width / 5, y: height * 2 / 3, width: width / 12, height: width / 12))
        // 饱和色块(触发色温响应与 LUT)
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.9, 0.2, 0.2, 1])!)
        ctx.fill(CGRect(x: width / 2, y: height / 4, width: width / 5, height: height / 5))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.1, 0.4, 0.9, 1])!)
        ctx.fill(CGRect(x: width * 3 / 4, y: height / 2, width: width / 6, height: height / 4))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
