import XCTest
import Photos
import CoreImage
@testable import JustShoot

/// 复现真机「拍完 → 相册查看全黑」的全链路集成测试。
///
/// 用与真机完全相同的渲染管线(色温响应 kernel + 线性域光学 + 颗粒 → 10-bit HEIC,5712×4284)
/// 产出字节，走 PhotoLibrary.save → PHAsset.fetchAssets(withLocalIdentifiers:) →
/// PHImageManager 预览请求，断言每一环。任何一环失败即定位真机黑屏的层级。
final class PhotoDisplayRoundTripTests: XCTestCase {

    func testRenderedHEICRoundTripsThroughPhotoLibrary() async throws {
        try await ensurePhotoLibraryAuthorized()

        // 1) 构造 5712×4284 的采集原片(带高光/暗部/色块的合成图，触发 halation/bloom/肩部/趾部路径)
        let width = 5712, height = 4284
        let source = try Self.syntheticCapture(width: width, height: height)

        // 2) 与真机一致的渲染配置(C200 + 完整 renderProfile 含色温响应)+ 48MP heif10 输出
        let preset = FilmPreset.fujiC200
        let profile = preset.renderProfile
        let lut = try FilmProcessor.shared.loadCubeLUT(resourceName: preset.lutResourceName)
        let renderedResult = await FilmProcessor.shared.applyLUTPreservingMetadata(
            imageData: source,
            lutCacheKey: preset.lutResourceName,
            capturedLUT: lut,
            grain: profile.grain,
            grainSeed: 0x1234_5678,
            optics: profile.optics,
            chromatic: profile.effectiveChromatic,
            chromaticSceneCCT: 6_300,
            outputQuality: 1.0
        )
        let rendered = try XCTUnwrap(renderedResult, "渲染输出为空——新管线(色温响应/线性光学)产片失败")
        XCTAssertGreaterThan(rendered.count, 1_000_000, "48MP heif10 不可能小于 1MB")

        // 3) 入库(与 CapturePipeline 同一路径),返回 localIdentifier
        let captureID = UUID()
        let creationDate = Date()
        let savedID = try await PhotoLibrary.save(
            imageData: rendered,
            creationDate: creationDate,
            latitude: nil, longitude: nil, altitude: nil, locationTimestamp: nil,
            captureID: captureID
        )
        defer { Task { try? await PhotoLibrary.delete(localIdentifiers: [savedID]) } }
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

    /// 测试进程照片库授权。注意**不主动 requestAuthorization**——弹窗在测试宿主里无人应答会挂死。
    /// 需先 `xcrun simctl privacy <udid> grant photos leavestylecode.JustShoot`(在 app 安装后执行)。
    private func ensurePhotoLibraryAuthorized() async throws {
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
