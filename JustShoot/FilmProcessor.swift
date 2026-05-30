import Foundation
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import Metal
import os

// MARK: - LUT 解析数据
struct CubeLUT: Sendable {
    let data: Data
    let dimension: Int
}

// MARK: - 胶片处理器（线程安全）
final class FilmProcessor: Sendable {
    static let shared = FilmProcessor()

    private let ciContext: CIContext
    private let srgbColorSpace: CGColorSpace
    /// 保护 lutCache 的锁
    private let lock = OSAllocatedUnfairLock<LUTState>(initialState: LUTState())

    /// 锁内保护的可变状态（仅缓存 LUT 数据，不缓存 CIFilter）
    private struct LUTState {
        var lutCache: [String: CubeLUT] = [:]
    }

    /// GPS EXIF 时间戳格式化器——固定 UTC、格式恒定，每张照片都用到。DateFormatter 初始化开销大，
    /// 旧实现每次拍照新建两个；hoist 成 static 复用。iOS 26 SDK 起 DateFormatter 本身已是 Sendable，
    /// 配置后只读，直接作 static let 共享即可（无需 nonisolated(unsafe)）。
    private static let gpsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        f.dateFormat = "yyyy:MM:dd"
        return f
    }()
    private static let gpsTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        f.dateFormat = "HH:mm:ss.SS"
        return f
    }()

    private init() {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.srgbColorSpace = colorSpace
        // 显式使用 Metal 设备，确保 LUT 处理走 GPU 加速路径。
        // highQualityDownsample: 任何隐式缩放都走 Lanczos（保高频细节），不开默认走廉价 linear。
        // cacheIntermediates: 48MP 路径中间步骤缓存可达数百 MB；关掉后按需重算，避免低内存设备 jetsam。
        let baseOptions: [CIContextOption: Any] = [
            CIContextOption.workingColorSpace: colorSpace,
            CIContextOption.outputColorSpace: colorSpace,
            CIContextOption.highQualityDownsample: true,
            CIContextOption.cacheIntermediates: false
        ]
        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: mtlDevice, options: baseOptions)
        } else {
            var opts = baseOptions
            opts[CIContextOption.useSoftwareRenderer] = false
            self.ciContext = CIContext(options: opts)
        }
    }

    /// 从 .cube 文件文本解析 LUT 数据（纯函数，无锁无 I/O）
    static func parseCubeFile(_ text: String) throws -> CubeLUT {
        var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        lines.removeAll { $0.hasPrefix("#") || $0.isEmpty }

        var size = 0
        var values: [Float] = []

        for line in lines {
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                if let last = line.split(separator: " ").last, let dim = Int(last) {
                    size = dim
                }
            } else {
                let comps = line.split(separator: " ").compactMap { Float($0) }
                if comps.count == 3 {
                    values.append(contentsOf: comps)
                }
            }
        }

        guard size > 0, values.count == size * size * size * 3 else {
            throw NSError(domain: "FilmProcessor", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Failed to parse LUT or dimensions mismatch")])
        }

        var rgba: [Float] = []
        rgba.reserveCapacity(size * size * size * 4)
        for i in stride(from: 0, to: values.count, by: 3) {
            rgba.append(values[i + 0])
            rgba.append(values[i + 1])
            rgba.append(values[i + 2])
            rgba.append(1.0)
        }

        let data: Data = rgba.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        return CubeLUT(data: data, dimension: size)
    }

    /// 健壮读取 .cube 文本：部分 LUT 文件的 TITLE 含非 UTF-8 字节（如中文 GBK/Shift-JIS），
    /// 强制 UTF-8 会抛错。这里按常见编码回退，最后兜底丢弃非法字节。
    static func readCubeText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .isoLatin1, .windowsCP1252, .macOSRoman] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        // 兜底：按 ASCII 读取，忽略非法字节（cube 文件的数据部分必然是 ASCII 数字）
        return String(decoding: data, as: UTF8.self)
    }

    func loadCubeLUT(resourceName: String) throws -> CubeLUT {
        // 快速路径：缓存命中
        if let cached = lock.withLock({ $0.lutCache[resourceName] }) {
            Log.lut.debug("lut_cache_hit name=\(resourceName, privacy: .public) dim=\(cached.dimension)")
            return cached
        }

        // 慢路径：解析 LUT 文件（锁外执行，避免长时间持锁）
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "cube") else {
            Log.lut.error("lut_resource_missing name=\(resourceName, privacy: .public)")
            throw NSError(domain: "FilmProcessor", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "LUT resource not found: %@.cube"), resourceName)])
        }

        let timer = Log.perf("lut_load", logger: Log.lut)
        do {
            let text = try Self.readCubeText(from: url)
            let cube = try Self.parseCubeFile(text)
            lock.withLock { $0.lutCache[resourceName] = cube }
            timer.end("name=\(resourceName) dim=\(cube.dimension)")
            return cube
        } catch {
            Log.lut.error("lut_parse_failed name=\(resourceName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func preload(preset: FilmPreset) {
        _ = try? loadCubeLUT(resourceName: preset.lutResourceName)
    }

    /// 从文件 URL 加载自定义 LUT（用于用户导入的 .cube 文件）
    @discardableResult
    func loadCubeLUTFromFile(url: URL, cacheKey: String) throws -> CubeLUT {
        if let cached = lock.withLock({ $0.lutCache[cacheKey] }) {
            return cached
        }
        do {
            let text = try Self.readCubeText(from: url)
            let cube = try Self.parseCubeFile(text)
            lock.withLock { $0.lutCache[cacheKey] = cube }
            return cube
        } catch {
            Log.lut.error("lut_custom_parse_failed key=\(cacheKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// 删除自定义 LUT 时调用——把对应缓存条目移除。否则用户导入后又删除的 .cube 会在整个进程
    /// 生命周期内继续占用内存（一个 64³ cube ≈ 3MB），随导入/删除次数无上限增长。
    func removeCachedLUT(cacheKey: String) {
        lock.withLock { $0.lutCache[cacheKey] = nil }
    }

    /// 获取已缓存的 LUT 数据（用于 Metal 预览创建 3D 纹理）
    func getCachedLUT(cacheKey: String) -> CubeLUT? {
        lock.withLock { $0.lutCache[cacheKey] }
    }

    /// 预加载 FilmSource 对应的 LUT
    func preload(source: FilmSource) {
        switch source {
        case .preset(let p):
            preload(preset: p)
        case .custom(_, _, _, let fileName):
            let url = CustomLUT.storageDirectory.appendingPathComponent(fileName)
            _ = try? loadCubeLUTFromFile(url: url, cacheKey: source.lutCacheKey)
        }
    }

    /// 应用 LUT 并保留/添加元数据（拍照用，统一 sRGB 色彩空间）
    func applyLUTPreservingMetadata(imageData: Data, lutCacheKey: String, outputQuality: CGFloat = 1.0, location: CLLocation? = nil, focalLengthIn35mm: Int? = nil) -> Data? {
        // 读取原始 metadata（AVCapture 写入的完整 EXIF / TIFF / Maker / 色彩空间字典）。
        // 一次读取，后面 orientation 判断 + metadata 注入都复用，避免重复打开 CGImageSource。
        let sourceProps: [String: Any] = {
            guard let src = CGImageSourceCreateWithData(imageData as CFData, nil) else { return [:] }
            return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        }()
        let exifOrientation: Int32 = {
            if let v = sourceProps[kCGImagePropertyOrientation as String] as? Int32 { return v }
            if let v = sourceProps[kCGImagePropertyOrientation as String] as? Int { return Int32(v) }
            if let v = sourceProps[kCGImagePropertyOrientation as String] as? UInt32 { return Int32(v) }
            return 1
        }()

        guard let rawCI = CIImage(data: imageData) else {
            Log.lut.error("lut_apply_failed reason=ciimage_init_nil bytes=\(imageData.count)")
            return nil
        }
        let timer = Log.perf("lut_apply", logger: Log.lut)
        // 物理旋转像素到视觉正向朝向，这样 extent 反映真实宽高、输出 orientation=1 才正确
        var ciInput = rawCI.oriented(forExifOrientation: exifOrientation)

        let inputExtent = ciInput.extent
        let isLandscape = inputExtent.width > inputExtent.height
        Log.lut.info("lut_apply_begin key=\(lutCacheKey, privacy: .public) exif=\(exifOrientation) w=\(Int(inputExtent.width)) h=\(Int(inputExtent.height)) landscape=\(isLandscape)")

        // 出片保持 sensor 原生 4:3（横）/ 3:4（纵）画幅，与预览 viewport `.aspectRatio(3.0/4.0)`
        // 完全对齐。sensor 输出已经是 4:3，下面的 crop 在 |差异| ≤ 0.01 时是 no-op；保留这段代码
        // 是为了万一上游格式选择给出非 4:3 的 active format（罕见）也能兜底裁回标称比例。
        let targetAspect: CGFloat = isLandscape ? (4.0 / 3.0) : (3.0 / 4.0)
        let currentAspect = inputExtent.width / inputExtent.height

        if abs(currentAspect - targetAspect) > 0.01 {
            var cropRect = inputExtent
            if currentAspect > targetAspect {
                let newWidth = inputExtent.height * targetAspect
                let xOffset = (inputExtent.width - newWidth) / 2
                cropRect = CGRect(x: inputExtent.origin.x + xOffset, y: inputExtent.origin.y, width: newWidth, height: inputExtent.height)
            } else {
                let newHeight = inputExtent.width / targetAspect
                let yOffset = (inputExtent.height - newHeight) / 2
                cropRect = CGRect(x: inputExtent.origin.x, y: inputExtent.origin.y + yOffset, width: inputExtent.width, height: newHeight)
            }
            ciInput = ciInput.cropped(to: cropRect)
        }

        // 应用 LUT 滤镜（每次创建新 CIFilter，避免线程竞争）
        // 使用 CIColorCubeWithColorSpace 显式指定输入色彩空间为 sRGB，
        // 保证在 P3/HDR 源像素上应用 LUT 时的颜色一致性
        guard let colorCube = CIFilter(name: "CIColorCubeWithColorSpace"),
              let lut = getCachedLUT(cacheKey: lutCacheKey) else {
            Log.lut.error("lut_apply_failed reason=lut_missing key=\(lutCacheKey, privacy: .public)")
            return nil
        }

        colorCube.setValue(ciInput, forKey: kCIInputImageKey)
        colorCube.setValue(lut.dimension, forKey: "inputCubeDimension")
        colorCube.setValue(lut.data, forKey: "inputCubeData")
        colorCube.setValue(srgbColorSpace, forKey: "inputColorSpace")

        guard let output = colorCube.outputImage else { return nil }

        // 渲染为 10-bit HEIC（HEVC Main10），与 iPhone Camera 出片比特深度对齐。
        // CIColorCubeWithColorSpace 在浮点域插值 LUT cell，输出的中间色精度本身就 > 8-bit，
        // 压回 RGBA8 会量化掉这部分精度——渐变最易在天空/皮肤上出 banding。10-bit 保留这部分。
        // 文件体积比 8-bit + 0.95 大 ~50–80%（200mm/12MP 约 300KB → 700–900KB），
        // 对齐 iPhone Camera 的同场景出片大小。
        // 兜底链：heif10 → 8-bit HEIC → JPEG（极旧设备无 HEVC 编码器）。
        let rendered: Data
        if let heif10 = try? ciContext.heif10Representation(
            of: output,
            colorSpace: srgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]
        ) {
            rendered = heif10
        } else if let heif8 = ciContext.heifRepresentation(
            of: output,
            format: .RGBA8,
            colorSpace: srgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]
        ) {
            Log.lut.info("lut_render_fallback codec=heif8 reason=heif10_unavailable")
            rendered = heif8
        } else if let jpeg = ciContext.jpegRepresentation(
            of: output,
            colorSpace: srgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]
        ) {
            Log.lut.info("lut_render_fallback codec=jpeg reason=heif_unavailable")
            rendered = jpeg
        } else {
            Log.lut.error("lut_apply_failed reason=render_failed")
            return nil
        }

        // 注入 metadata：把原始 source props 中的 EXIF/TIFF/GPS 等字典通过 CGImageDestination 写到
        // 已编码的图像上。**source 和 destination 是同一 imageType 时，AddImageFromSource 是 fast copy +
        // metadata replace**（Apple docs 原话），不会重新压缩——画质零损失。
        var metadata = sourceProps

        // 方向：像素已通过 .oriented(forExifOrientation:) 物理旋转到正向，输出标记为 .up
        metadata[kCGImagePropertyOrientation as String] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        // GPS
        if let loc = location {
            var gps: [String: Any] = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
            gps[kCGImagePropertyGPSLatitude as String] = abs(loc.coordinate.latitude)
            gps[kCGImagePropertyGPSLongitude as String] = abs(loc.coordinate.longitude)
            gps[kCGImagePropertyGPSLatitudeRef as String] = loc.coordinate.latitude >= 0 ? "N" : "S"
            gps[kCGImagePropertyGPSLongitudeRef as String] = loc.coordinate.longitude >= 0 ? "E" : "W"
            gps[kCGImagePropertyGPSAltitude as String] = abs(loc.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = loc.altitude >= 0 ? 0 : 1

            // GPS 时间戳用"拍照时刻"而非 location fix 时刻：30s 缓存策略下连拍多张
            // 会复用同一个 CLLocation，loc.timestamp 是 fix 时刻而非拍摄时刻，
            // 写入 EXIF 后用户在相册里看到一组照片"GPS 时间相同"——与文件创建时间错位。
            // 坐标变化慢可接受沿用 cached，但时间必须取真值。
            let captureTime = Date()
            gps[kCGImagePropertyGPSDateStamp as String] = Self.gpsDateFormatter.string(from: captureTime)
            gps[kCGImagePropertyGPSTimeStamp as String] = Self.gpsTimeFormatter.string(from: captureTime)

            if loc.speed >= 0 {
                gps[kCGImagePropertyGPSSpeed as String] = loc.speed * 3.6
                gps[kCGImagePropertyGPSSpeedRef as String] = "K"
            }
            if loc.course >= 0 {
                gps[kCGImagePropertyGPSImgDirection as String] = loc.course
                gps[kCGImagePropertyGPSImgDirectionRef as String] = "T"
            }
            metadata[kCGImagePropertyGPSDictionary as String] = gps
        }

        // 覆写等效焦距（EXIF：FocalLenIn35mmFilm）
        if let fl35 = focalLengthIn35mm {
            var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = fl35
            metadata[kCGImagePropertyExifDictionary as String] = exif
        }

        // CGImageSourceGetType 自动识别 HEIC/JPEG，destination 用同一 type 写回 → fast copy 路径。
        // metadata 字典中的 PixelWidth/Height 等 size 字段会被 destination 用 LUT 渲染后的真实尺寸覆盖，
        // 不会和实际图像 dim 冲突。
        guard let renderedSource = CGImageSourceCreateWithData(rendered as CFData, nil),
              let mutableData = CFDataCreateMutable(nil, 0),
              let imageType = CGImageSourceGetType(renderedSource),
              let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
            return nil
        }

        CGImageDestinationAddImageFromSource(destination, renderedSource, 0, metadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            Log.lut.error("lut_apply_failed reason=destination_finalize")
            return nil
        }
        let finalData = mutableData as Data
        timer.end("in=\(imageData.count)B out=\(finalData.count)B gps=\(location != nil)")
        return finalData
    }
}
