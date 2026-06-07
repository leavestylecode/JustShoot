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
    ///
    /// - contentIdentifier: 非 nil 时把它写进 MakerApple 字典 key "17"——这是 Live Photo 静态图
    ///   与配对视频关联的 content identifier。静态图被 LUT 重编码后 AVCapture 原写入的 MakerApple
    ///   可能不可靠存活，所以由调用方显式传入同一个 UUID，两端（这里 + LivePhotoProcessor 写视频）
    ///   各自显式写入，配对不依赖原始字节往返。
    func applyLUTPreservingMetadata(imageData: Data, lutCacheKey: String, outputQuality: CGFloat = 1.0, location: CLLocation? = nil, focalLengthIn35mm: Int? = nil, contentIdentifier: String? = nil) -> Data? {
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
        // 渲染输出的真实像素尺寸 = LUT 输出 CIImage 的 extent（= 裁切后的输入 extent）。
        // 这是判断"文件为何小"的关键诊断量：几百 KB 若伴随完整 ~22MP 尺寸 → 编码质量问题；
        // 若尺寸本身就小 → 采集/解码端把分辨率丢了。
        let outExtent = output.extent
        let outMP = (outExtent.isInfinite || outExtent.isEmpty) ? 0 : (outExtent.width * outExtent.height) / 1_000_000

        let rendered: Data
        let codec: String
        if let heif10 = try? ciContext.heif10Representation(
            of: output,
            colorSpace: srgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]
        ) {
            rendered = heif10
            codec = "heif10"
        } else if let heif8 = ciContext.heifRepresentation(
            of: output,
            format: .RGBA8,
            colorSpace: srgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]
        ) {
            Log.lut.info("lut_render_fallback codec=heif8 reason=heif10_unavailable")
            rendered = heif8
            codec = "heif8"
        } else if let jpeg = ciContext.jpegRepresentation(
            of: output,
            colorSpace: srgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]
        ) {
            Log.lut.info("lut_render_fallback codec=jpeg reason=heif_unavailable")
            rendered = jpeg
            codec = "jpeg"
        } else {
            Log.lut.error("lut_apply_failed reason=render_failed")
            return nil
        }

        // 🔑 一击定位行：编码刚完成、metadata 注入前。codec / 输出像素尺寸 / 百万像素 / 质量参数 /
        // 输入原始字节 / 编码后字节 全在一行。若 rendered_bytes 这里就只有几百 KB 而 out_dims 是完整
        // ~5500×4100，则问题在编码质量；若 out_dims 本身就小，则问题在采集/解码端。
        Log.lut.info("lut_render_done codec=\(codec, privacy: .public) out_dims=\(Int(outExtent.width))x\(Int(outExtent.height)) mp=\(String(format: "%.1f", outMP)) quality=\(String(format: "%.2f", Double(outputQuality))) in_bytes=\(imageData.count) rendered_bytes=\(rendered.count)")

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

        // 覆写等效焦距（EXIF：FocalLenIn35mmFilm）。覆写前先把系统**原始**写入的焦距打出来——
        // 这是"哪颗物理镜头真正出片"的 ground truth（capture_focal 是 dispatch 时刻的快照，系统可能在
        // 曝光瞬间又切了镜头；而这里的 EXIF 是出片数据自带的，最权威）：
        //   phys      = 物理镜头实际焦距(mm，如主摄≈6.8mm、长焦≈15.7mm)——直接看出系统用了哪颗镜头
        //   cam_equiv = 系统自己算的 35mm 等效（我们即将用 overwrite_to 覆盖它）
        //   lens      = 镜头型号串（含焦距），再次印证物理镜头
        if let srcExif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            let phys = (srcExif[kCGImagePropertyExifFocalLength as String] as? Double).map { String(format: "%.2fmm", $0) } ?? "nil"
            let camEquiv = srcExif[kCGImagePropertyExifFocalLenIn35mmFilm as String].map { "\($0)mm" } ?? "nil"
            let lensModel = srcExif[kCGImagePropertyExifLensModel as String] as? String ?? "nil"
            Log.lut.info("lut_exif_focal phys=\(phys, privacy: .public) cam_equiv=\(camEquiv, privacy: .public) overwrite_to=\(focalLengthIn35mm.map { "\($0)mm" } ?? "nil", privacy: .public) lens=\(lensModel, privacy: .public)")
        }

        if let fl35 = focalLengthIn35mm {
            var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = fl35
            metadata[kCGImagePropertyExifDictionary as String] = exif
        }

        // Live Photo 配对：把 content identifier 写进 MakerApple 字典 key "17"。配对视频侧
        // （LivePhotoProcessor）写同一个 id 到 QuickTime content.identifier，Photos 据此把两个
        // 资源识别为一张 Live Photo。这里显式写入（而非依赖原始 MakerApple 往返存活），更稳。
        if let cid = contentIdentifier {
            var maker = metadata[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
            maker["17"] = cid
            metadata[kCGImagePropertyMakerAppleDictionary as String] = maker
        }

        // CGImageSourceGetType 自动识别 HEIC/JPEG，destination 用同一 type 写回。
        // metadata 字典中的 PixelWidth/Height 等 size 字段会被 destination 用 LUT 渲染后的真实尺寸覆盖，
        // 不会和实际图像 dim 冲突。
        //
        // ⚠️ 关键修复（2026-06-06，日志实测）：CGImageDestinationAddImageFromSource 对 HEIC **不是**
        // 字节级 fast-copy——它会解码后按目标默认压缩质量**重新编码**，把 9.7MB 重压成 ~850KB
        // （rendered_bytes=9724987 → final_bytes=848401）。这是"相册照片只有几百KB"的真正根因。
        // 必须在 destination 创建选项 + 单图属性里都显式把 lossy 质量设回 outputQuality(1.0)，
        // 让这一步的重编码走最高质量、文件大小与画质对齐 LUT 渲染产物。
        let qualityOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: outputQuality]
        metadata[kCGImageDestinationLossyCompressionQuality as String] = outputQuality
        guard let renderedSource = CGImageSourceCreateWithData(rendered as CFData, nil),
              let mutableData = CFDataCreateMutable(nil, 0),
              let imageType = CGImageSourceGetType(renderedSource),
              let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, qualityOptions as CFDictionary) else {
            return nil
        }

        CGImageDestinationAddImageFromSource(destination, renderedSource, 0, metadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            Log.lut.error("lut_apply_failed reason=destination_finalize")
            return nil
        }
        let finalData = mutableData as Data
        // final_bytes 应≈rendered_bytes（已强制 q=outputQuality 重编码）。若 final ≪ rendered，说明质量参数没生效。
        Log.lut.info("lut_final_done codec=\(codec, privacy: .public) rendered_bytes=\(rendered.count) final_bytes=\(finalData.count) out_dims=\(Int(outExtent.width))x\(Int(outExtent.height)) gps=\(location != nil)")
        timer.end("in=\(imageData.count)B out=\(finalData.count)B gps=\(location != nil)")
        return finalData
    }
}
