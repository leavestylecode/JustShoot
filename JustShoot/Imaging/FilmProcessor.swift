import Foundation
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import Metal
import os

// MARK: - LUT 解析数据


// MARK: - 胶片处理器（线程安全）
final class FilmProcessor: Sendable {
    static let shared = FilmProcessor()

    private let srgbColorSpace: CGColorSpace
    /// CIContext 首次创建在真机约需 1 秒；与 LUT cache 分锁，避免纯 LUT 读取触发或等待 GPU 初始化。
    private let renderContextLock = OSAllocatedUnfairLock<CIContext?>(initialState: nil)
    private let rawRenderContextLock = OSAllocatedUnfairLock<CIContext?>(initialState: nil)
    /// LUT bytes share one budget; lightweight source/curve recipes have separate entry limits.
    private let lock: OSAllocatedUnfairLock<LUTState>

    private struct CurveComposition: Sendable {
        let baseKey: String
        let curve: FilmCurve
    }

    /// 锁内保护的可变状态（仅缓存 LUT 数据，不缓存 CIFilter）
    private struct LUTState {
        var luts: ByteBudgetLRU<String, CubeLUT>
        /// 动态用户曲线无法从缓存键反解完整控制点，因此在生成键时登记轻量合成配方。
        var curveCompositions: ByteBudgetLRU<String, CurveComposition>
        var fileSources: ByteBudgetLRU<String, URL>

        init(maximumBytes: Int, maximumRecipeEntries: Int) {
            luts = ByteBudgetLRU(maximumBytes: maximumBytes, maximumEntries: 64)
            curveCompositions = ByteBudgetLRU(maximumBytes: 0, maximumEntries: maximumRecipeEntries)
            fileSources = ByteBudgetLRU(maximumBytes: 0, maximumEntries: maximumRecipeEntries)
        }
    }

    /// A 128³ table is 32 MiB. Entry counts alone cannot bound retained LUT memory.
    static let maximumLUTCacheBytes = 64 * 1_024 * 1_024
    private static let compiledLUTMagic = Array("JSLUT001".utf8)
    private static let compiledLUTHeaderSize = 16

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

    init(maximumLUTCacheBytes: Int = FilmProcessor.maximumLUTCacheBytes,
         maximumRecipeEntries: Int = 128) {
        let timer = Log.perf("film_processor_init", logger: Log.lut)
        self.srgbColorSpace = FilmImagePipeline.colorSpace
        self.lock = OSAllocatedUnfairLock(initialState: LUTState(
            maximumBytes: maximumLUTCacheBytes, maximumRecipeEntries: maximumRecipeEntries))
        timer.end()
    }

    var cachedLUTBytes: Int { lock.withLock { $0.luts.retainedBytes } }
    var cachedLUTCount: Int { lock.withLock { $0.luts.count } }

    /// 唯一的静态照片 CIContext。创建过程在锁内执行：后台预热与极快首拍撞车时，后者等待同一实例，
    /// 不会各自创建一份昂贵的 Metal context。
    func renderingContext(raw: Bool = false) -> CIContext {
        let contextLock = raw ? rawRenderContextLock : renderContextLock
        return contextLock.withLock { context in
            if let context { return context }

            // 显式使用 Metal 设备，确保 LUT 处理走 GPU 加速路径。
            // highQualityDownsample: 任何隐式缩放都走 Lanczos（保高频细节），不开默认走廉价 linear。
            // cacheIntermediates: 48MP 路径中间步骤缓存可达数百 MB；关掉后按需重算，避免低内存设备 jetsam。
            var baseOptions: [CIContextOption: Any] = [
                CIContextOption.workingColorSpace: raw ? RawFilmRenderer.linearSpace : srgbColorSpace,
                CIContextOption.outputColorSpace: srgbColorSpace,
                CIContextOption.highQualityDownsample: true,
                CIContextOption.cacheIntermediates: false,
                CIContextOption.priorityRequestLow: true
            ]
            if raw { baseOptions[.workingFormat] = CIFormat.RGBAf }
            let created: CIContext
            if let mtlDevice = MTLCreateSystemDefaultDevice() {
                created = CIContext(mtlDevice: mtlDevice, options: baseOptions)
            } else {
                var opts = baseOptions
                opts[CIContextOption.useSoftwareRenderer] = false
                created = CIContext(options: opts)
            }
            context = created
            return created
        }
    }

    /// A display-sized sRGB sample uses the capture LUT without optical effects or grain.
    func gradedPreview(_ original: CGImage, preset: FilmPreset) -> CGImage? {
        do {
            let lut = try loadLUT(source: .preset(preset))
            guard let stages = FilmImagePipeline.stages(for: CIImage(cgImage: original), lut: lut,
                chromaticGain: .one, optics: .disabled, grain: .disabled, grainSeed: 1) else { return nil }
            return renderingContext().createCGImage(stages.graded, from: stages.graded.extent,
                format: .RGBA8, colorSpace: srgbColorSpace, deferred: false)
        } catch {
            Log.lut.error("film_preview_lut_failed preset=\(preset.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Apply the curve's 256 sRGB samples directly to a display-sized reference photo.
    func gradedPreview(_ original: CGImage, curve: FilmCurve) -> CGImage? {
        guard !curve.isNeutral else { return original }
        let filter = CIFilter.colorCurves()
        filter.inputImage = CIImage(cgImage: original)
        filter.colorSpace = srgbColorSpace
        filter.curvesData = curve.previewData.interleavedRGBData
        guard let output = filter.outputImage else { return nil }
        return renderingContext().createCGImage(output, from: output.extent, format: .RGBA8,
            colorSpace: srgbColorSpace, deferred: false)
    }

    /// 首屏完成后由启动编排在后台调用。若已准备好则近似零开销。
    func prepareRendering() {
        let timer = Log.perf("film_render_prepare", logger: Log.lut)
        _ = renderingContext()
        _ = FilmImageKernels.shared
        timer.end()
    }

    /// Called by the serial RAW resource actor before enabling the shutter.
    func prepareRawRendering() throws {
        _ = renderingContext(raw: true)
        try RawFilmRenderer.prepare()
        try FilmMaterialRenderer.prepare()
    }

    /// Initializes the shared still-render CIContext and effect kernels before capture admission. This performs
    /// no synthetic exposure, HEIF encode, Live Photo transcode, or permission request.
    func warmUpForCapture() async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async(qos: .utility, flags: [.enforceQoS, .detached]) {
                self.prepareRendering()
                continuation.resume()
            }
        }
        try Task.checkCancellation()
    }

    // MARK: - 逐阶段诊断对照图
    //
    // 设置页开启「保留处理阶段对照图」（默认关）后，每次静态成片在
    // Documents/ProcessingDiagnostics/<拍摄ID>/ 下保留原片、SDR 输入、LUT、光学、颗粒阶段，
    // 并在可用时附带快门预览帧及相册回读的亮度/色彩统计，用于定位差异首次出现的阶段。
    // 每张 48MP 10-bit HEIC 约 2–4 MB，只保留最近 6 次拍摄，其余自动清理；
    // 失败只记日志、绝不影响出片。

    /// 与 SettingsView 的 @AppStorage("processingStageDiagnostics") 共享；默认关。
    static var stageDiagnosticsEnabled: Bool {
        UserDefaults.standard.object(forKey: "processingStageDiagnostics") as? Bool ?? false
    }

    private static let stageDiagnosticsRetention = 6
    private static var stageDiagnosticsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProcessingDiagnostics", isDirectory: true)
    }

    private func writeStageDiagnostics(
        id: UUID,
        original: Data,
        stages: [(name: String, image: CIImage)],
        context: CIContext,
        cancellation: CaptureRenderCancellation?
    ) {
        guard cancellation?.isCancelled != true else { return }
        let directory = Self.stageDiagnosticsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // 原片按真实编码字节保留（AVCapture 交付 HEIC；极旧设备回退 JPEG 时按魔数定扩展名）。
            let source = CGImageSourceCreateWithData(original as CFData, nil)
            let originalExtension = source.map { RawFilmRenderer.isDNG($0) } == true ? "dng" : (original.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic")
            try original.write(to: directory.appendingPathComponent("1_original.\(originalExtension)"), options: .atomic)

            for stage in stages {
                guard cancellation?.isCancelled != true else { return }
                var encoded: Data?
                var ext = "heic"
                if let heif10 = try? context.heif10Representation(
                    of: stage.image,
                    colorSpace: srgbColorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
                ) {
                    encoded = heif10
                } else if cancellation?.isCancelled == true {
                    return
                } else if let jpeg = context.jpegRepresentation(
                    of: stage.image,
                    colorSpace: srgbColorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
                ) {
                    encoded = jpeg
                    ext = "jpg"
                }
                guard cancellation?.isCancelled != true else { return }
                if let encoded {
                    try encoded.write(to: directory.appendingPathComponent("\(stage.name).\(ext)"), options: .atomic)
                }
            }
            Self.pruneStageDiagnostics(keeping: Self.stageDiagnosticsRetention)
            Log.lut.info("stage_diagnostics_written id=\(id.uuidString, privacy: .public) stages=\(stages.count + 1)")
        } catch {
            Log.lut.error("stage_diagnostics_write_failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 只保留最近 N 次拍摄的对照图目录；清理失败静默（下次写入再试）。
    private static func pruneStageDiagnostics(keeping limit: Int) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: stageDiagnosticsRoot,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let dated = contents.compactMap { url -> (Date, URL)? in
            let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (created ?? .distantPast, url)
        }
        guard dated.count > limit else { return }
        for (_, url) in dated.sorted(by: { $0.0 > $1.0 }).dropFirst(limit) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// 构建期生成的直接加载格式：magic(8) + dimension(UInt32 LE) + floatCount(UInt32 LE)
    /// + RGBA Float32 LE。Apple 平台均为 little-endian，payload 可直接交给 CIColorCube / Metal。
    static func decodeCompiledLUT(_ data: Data) throws -> CubeLUT {
        guard data.count >= compiledLUTHeaderSize,
              Array(data.prefix(compiledLUTMagic.count)) == compiledLUTMagic else {
            throw NSError(
                domain: "FilmProcessor",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Invalid compiled LUT header"]
            )
        }

        func littleEndianUInt32(at offset: Int) -> Int {
            Int(data[offset])
                | (Int(data[offset + 1]) << 8)
                | (Int(data[offset + 2]) << 16)
                | (Int(data[offset + 3]) << 24)
        }

        let dimension = littleEndianUInt32(at: 8)
        let floatCount = littleEndianUInt32(at: 12)
        guard (2...CubeLUT.maximumDimension).contains(dimension) else { throw CubeLUT.ParseError.malformed }
        let expectedFloatCount = dimension * dimension * dimension * 4
        let expectedByteCount = compiledLUTHeaderSize + floatCount * MemoryLayout<Float>.stride
        guard dimension > 0,
              floatCount == expectedFloatCount,
              data.count == expectedByteCount else {
            throw NSError(
                domain: "FilmProcessor",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Compiled LUT dimensions mismatch"]
            )
        }

        return try CubeLUT.validated(
            data: data.subdata(in: compiledLUTHeaderSize..<data.count),
            dimension: dimension
        )
    }

    /// 从 .cube 文件文本解析 LUT 数据（纯函数，无锁无 I/O）
    static func parseCubeFile(_ text: String) throws -> CubeLUT {
        try CubeLUT.parse(text)
    }

    /// 健壮读取 .cube 文本：部分 LUT 文件的 TITLE 含非 UTF-8 字节（如中文 GBK/Shift-JIS），
    /// 强制 UTF-8 会抛错。这里按常见编码回退，最后兜底丢弃非法字节。
    static func readCubeText(from url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CubeLUT.maximumFileBytes else { throw CubeLUT.ParseError.malformed }
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .isoLatin1, .windowsCP1252, .macOSRoman] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        // 兜底：按 ASCII 读取，忽略非法字节（cube 文件的数据部分必然是 ASCII 数字）
        return String(decoding: data, as: UTF8.self)
    }

    func loadCubeLUT(resourceName: String) throws -> CubeLUT {
        // 快速路径：缓存命中
        if let cached = lock.withLock({ $0.luts.value(forKey: resourceName) }) {
            Log.lut.debug("lut_cache_hit name=\(resourceName, privacy: .public) dim=\(cached.dimension)")
            return cached
        }

        let totalTimer = Log.perf("lut_load", logger: Log.lut)

        // 内置资源优先走构建期编译的二进制格式。读取 + 16-byte header 校验后即可直接使用，
        // 不再在冷启动时解析整份十进制文本。
        if let compiledURL = Bundle.main.url(forResource: resourceName, withExtension: "jslut") {
            do {
                let data = try Data(contentsOf: compiledURL, options: .mappedIfSafe)
                let cube = try Self.decodeCompiledLUT(data)
                _ = lock.withLock { $0.luts.insert(cube, forKey: resourceName, cost: cube.byteCount) }
                totalTimer.end("name=\(resourceName) dim=\(cube.dimension) source=binary bytes=\(data.count)")
                return cube
            } catch {
                Log.lut.error("lut_binary_load_failed name=\(resourceName, privacy: .public) error=\(error.localizedDescription, privacy: .public) fallback=text")
            }
        }

        // 兼容回退：资源遗漏/损坏时仍可解析原始 .cube，不让拍摄功能失效。
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "cube") else {
            Log.lut.error("lut_resource_missing name=\(resourceName, privacy: .public)")
            throw NSError(domain: "FilmProcessor", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "LUT resource not found: %@.cube"), resourceName)])
        }

        do {
            let readTimer = Log.perf("lut_text_read", logger: Log.lut)
            let text = try Self.readCubeText(from: url)
            readTimer.end("name=\(resourceName) chars=\(text.count)")
            let parseTimer = Log.perf("lut_text_parse", logger: Log.lut)
            let cube = try Self.parseCubeFile(text)
            parseTimer.end("name=\(resourceName) dim=\(cube.dimension)")
            _ = lock.withLock { $0.luts.insert(cube, forKey: resourceName, cost: cube.byteCount) }
            totalTimer.end("name=\(resourceName) dim=\(cube.dimension) source=text")
            return cube
        } catch {
            Log.lut.error("lut_parse_failed name=\(resourceName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func preload(preset: FilmPreset) {
        _ = try? loadLUT(source: .preset(preset))
    }

    /// 从文件 URL 加载自定义 LUT（用于用户导入的 .cube 文件）
    @discardableResult
    func loadCubeLUTFromFile(url: URL, cacheKey: String) throws -> CubeLUT {
        if let cached = lock.withLock({ state in
            state.fileSources.insert(url, forKey: cacheKey, cost: 0)
            return state.luts.value(forKey: cacheKey)
        }) {
            return cached
        }
        do {
            let cube: CubeLUT
            if url.pathExtension.lowercased() == "jslut" {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 16 + CubeLUT.maximumDimension * CubeLUT.maximumDimension * CubeLUT.maximumDimension * 16 else {
                    throw CubeLUT.ParseError.malformed
                }
                cube = try Self.decodeCompiledLUT(Data(contentsOf: url, options: .mappedIfSafe))
            } else {
                // Existing imported files retain their historical sRGB interpretation.
                cube = try Self.parseCubeFile(Self.readCubeText(from: url))
            }
            _ = lock.withLock { $0.luts.insert(cube, forKey: cacheKey, cost: cube.byteCount) }
            return cube
        } catch {
            Log.lut.error("lut_custom_parse_failed key=\(cacheKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Deleting a custom LUT also invalidates its cached bytes, source and derived recipes.
    func removeCachedLUT(cacheKey: String) {
        lock.withLock { state in
            state.luts.removeValue(forKey: cacheKey)
            state.fileSources.removeValue(forKey: cacheKey)
            let prefix = cacheKey + "#curve-"
            state.luts.removeAll { $0.hasPrefix(prefix) }
            state.curveCompositions.removeAll { $0.hasPrefix(prefix) }
        }
    }

    /// 中性曲线返回原键；其余曲线登记合成配方。用户曲线键包含内容指纹，保存编辑后不会命中旧 LUT。
    func composedLUTCacheKey(_ lutKey: String, curve: FilmCurve) -> String {
        guard !curve.isNeutral else { return lutKey }
        let composedKey = lutKey + curve.cacheKeySuffix
        _ = lock.withLock { state in
            state.curveCompositions.insert(CurveComposition(baseKey: lutKey, curve: curve),
                forKey: composedKey, cost: 0)
        }
        return composedKey
    }

    /// Strictly memory-only: safe for callers that must never perform source I/O.
    func cachedLUT(cacheKey: String) -> CubeLUT? {
        lock.withLock { $0.luts.value(forKey: cacheKey) }
    }

    /// Evicted bytes reload from their source. Current curve selections register a recipe before
    /// preparation; very old user recipes may be forgotten, while captures own immutable LUT bytes.
    func resolveLUT(cacheKey: String) -> CubeLUT? {
        if let cached = cachedLUT(cacheKey: cacheKey) {
            return cached
        }
        if let composition = lock.withLock({ $0.curveCompositions.value(forKey: cacheKey) }) {
            guard let base = resolveLUT(cacheKey: composition.baseKey) else { return nil }
            return compose(base: base, curve: composition.curve, composedKey: cacheKey)
        }
        if let url = lock.withLock({ $0.fileSources.value(forKey: cacheKey) }) {
            return try? loadCubeLUTFromFile(url: url, cacheKey: cacheKey)
        }
        if (cacheKey.hasSuffix(FilmLookRefinement.cacheSuffix) || cacheKey.hasSuffix(FilmMaterial.revision)),
           let preset = FilmPreset.allCases.first(where: { FilmSource.preset($0).lutCacheKey == cacheKey }) {
            return try? loadLUT(source: .preset(preset))
        }
        if Bundle.main.url(forResource: cacheKey, withExtension: "jslut") != nil
            || Bundle.main.url(forResource: cacheKey, withExtension: "cube") != nil {
            return try? loadCubeLUT(resourceName: cacheKey)
        }
        return nil
    }

    private func compose(base: CubeLUT, curve: FilmCurve, composedKey: String) -> CubeLUT {
        if let cached = lock.withLock({ $0.luts.value(forKey: composedKey) }) {
            return cached
        }
        let timer = Log.perf("lut_curve_compose", logger: Log.lut)
        let composed = curve.applied(to: base)
        _ = lock.withLock { $0.luts.insert(composed, forKey: composedKey, cost: composed.byteCount) }
        timer.end("curve=\(curve.id) dim=\(composed.dimension)")
        return composed
    }

    /// Returns the requested bytes even when a configured cache budget cannot retain the table.
    func loadLUT(source: FilmSource, curve: FilmCurve = .builtIn(.none)) throws -> CubeLUT {
        let baseKey = source.lutCacheKey
        let base: CubeLUT
        switch source {
        case .preset(let p):
            if let cached = cachedLUT(cacheKey: baseKey) {
                base = cached
            } else {
                let timer = Log.perf("lut_look_refine", logger: Log.lut)
                if let material = try FilmMaterial.load(preset: p) {
                    var carrier = FilmMaterial.identity().cube
                    carrier.material = material
                    base = carrier
                } else {
                    let original = try loadCubeLUT(resourceName: p.lutResourceName)
                    base = try FilmLookRefinement.applying(to: original, preset: p)
                }
                _ = lock.withLock { $0.luts.insert(base, forKey: baseKey, cost: base.byteCount) }
                timer.end("film=\(p.rawValue) revision=\(FilmLookRefinement.revision) dim=\(base.dimension)")
            }
        case .custom(_, _, _, let fileName):
            let url = CustomLUTFiles.directory.appendingPathComponent(fileName)
            base = try loadCubeLUTFromFile(url: url, cacheKey: baseKey)
        }
        guard !curve.isNeutral else { return base }
        let key = composedLUTCacheKey(baseKey, curve: curve)
        return compose(base: base, curve: curve, composedKey: key)
    }

    func preload(source: FilmSource, curve: FilmCurve = .builtIn(.none)) {
        _ = try? loadLUT(source: source, curve: curve)
    }

    /// 应用 LUT 并保留/添加元数据（拍照用，统一 sRGB 色彩空间）
    ///
    /// - contentIdentifier: 非 nil 时把它写进 MakerApple 字典 key "17"——这是 Live Photo 静态图
    ///   与配对视频关联的 content identifier。静态图被 LUT 重编码后 AVCapture 原写入的 MakerApple
    ///   可能不可靠存活，所以由调用方显式传入同一个 UUID，两端（这里 + LivePhotoProcessor 写视频）
    ///   各自显式写入，配对不依赖原始字节往返。
    /// - diagnosticCaptureID: 开启「保留处理阶段对照图」设置时（见 stageDiagnosticsEnabled），
    ///   逐阶段写出原片 / LUT 后 / 光学后 / 成片四张对照图，用于定位细节在哪一步丢失。
    /// - outputQuality: nil selects automatic encoding. A non-nil value preserves only an
    ///   older journal's frozen compression recipe; new captures leave this unset.
    /// - cancellation: Checked before and after costly work. Cancellation returns nil;
    ///   an encoding call already in progress completes before observing the signal.
    func applyLUTPreservingMetadata(
        imageData: Data,
        lutCacheKey: String,
        capturedLUT: CubeLUT? = nil,
        lutIntensity: Float = 1,
        rawRecipe: RawCaptureRecipe? = nil,
        rawLUT: RawFilmLUT? = nil,
        capturesHDR: Bool = false,
        grain: FilmGrainParameters = .disabled,
        grainSeed: UInt32 = 0,
        optics: FilmOpticsParameters = .disabled,
        chromatic: FilmChromaticResponseParameters = .neutral,
        chromaticSceneCCT: Float? = nil,
        chromaticGainOverride: SIMD3<Float>? = nil,
        outputQuality: CGFloat? = nil,
        encodingMode: PhotoEncodingPolicy.Mode = .automatic,
        location: CLLocation? = nil,
        captureDate: Date = Date(),
        focalLengthIn35mm: Int? = nil,
        contentIdentifier: String? = nil,
        diagnosticCaptureID: UUID? = nil,
        trace: DiagnosticTrace? = nil,
        cancellation: CaptureRenderCancellation? = nil
    ) -> Data? {
        guard cancellation?.isCancelled != true else { return nil }
        // 读取原始 metadata（AVCapture 写入的完整 EXIF / TIFF / Maker / 色彩空间字典）。
        // 一次读取，后面 orientation 判断 + metadata 注入都复用，避免重复打开 CGImageSource。
        let metadataReadSpan = trace?.span("film_metadata_read")
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
        metadataReadSpan?.end()

        let decodeSpan = trace?.span("film_decode")
        let decoded: CIImage?
        do {
            defer { decodeSpan?.end() }
            if let rawRecipe {
                if rawRecipe.requiresRawLUT {
                    guard let rawLUT else { return nil }
                    decoded = RawFilmRenderer.develop(imageData, lut: rawLUT, recipe: rawRecipe, cancellation: cancellation)
                } else {
                    guard let capturedLUT, (try? rawRecipe.validate(displayLUT: capturedLUT)) != nil,
                          rawLUT == nil else { return nil }
                    decoded = RawFilmRenderer.develop(imageData, recipe: rawRecipe, cancellation: cancellation)
                }
            } else {
                decoded = FilmImagePipeline.decodePhoto(imageData)
            }
        }
        guard let rawCI = decoded else {
            Log.lut.error("lut_apply_failed reason=ciimage_init_nil bytes=\(imageData.count)")
            return nil
        }
        guard cancellation?.isCancelled != true else { return nil }
        let timer = Log.perf("lut_apply", logger: Log.lut)
        // 物理旋转像素到视觉正向朝向，这样 extent 反映真实宽高、输出 orientation=1 才正确
        let orientCropSpan = trace?.span("film_orient_crop")
        var ciInput = rawCI.oriented(forExifOrientation: exifOrientation)

        let inputExtent = ciInput.extent
        let isLandscape = inputExtent.width > inputExtent.height
        Log.lut.info("lut_apply_begin key=\(lutCacheKey, privacy: .public) exif=\(exifOrientation) w=\(Int(inputExtent.width)) h=\(Int(inputExtent.height)) landscape=\(isLandscape) chromatic_kk=\(chromaticSceneCCT.map { Int($0) }.map(String.init) ?? "off") strength=\(String(format: "%.2f", chromatic.strength))")

        // Native device zoom is already present in the photo. Share only the
        // viewfinder's aspect crop, never its video-proxy zoom compensation.
        ciInput = ciInput.cropped(to: CameraFraming.photoCrop(in: inputExtent))
        orientCropSpan?.end()

        guard cancellation?.isCancelled != true else { return nil }
        let lutResolveSpan = trace?.span("film_lut_resolve")
        let resolvedLUT: CubeLUT?
        do {
            defer { lutResolveSpan?.end() }
            resolvedLUT = capturedLUT ?? resolveLUT(cacheKey: lutCacheKey)
        }
        guard let lut = resolvedLUT else {
            Log.lut.error("lut_apply_failed reason=lut_missing key=\(lutCacheKey, privacy: .public)")
            return nil
        }

        guard let stages = FilmImagePipeline.stages(for: ciInput, lut: rawRecipe?.requiresRawLUT == true ? nil : lut,
            lutIntensity: lutIntensity,
            chromaticGain: chromaticGainOverride ?? chromatic.responseGain(sceneCCT: chromaticSceneCCT),
            protectChromaticHighlights: chromatic.protectsHighlights,
            optics: optics, grain: grain, grainSeed: grainSeed,
            cancellation: cancellation) else { return nil }
        let output = stages.final
        let wantsStageDiagnostics = diagnosticCaptureID != nil && Self.stageDiagnosticsEnabled

        // Prefer 10-bit HEIC to retain precision in LUT interpolation and smooth gradients.
        // Automatic compression keeps the full output extent and film grain; only an
        // unavailable codec causes fallback to 8-bit HEIC or JPEG.
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
            // 坐标变化慢可接受沿用 cached，但时间必须取真值——由调用方在快门 tap 时刻快照传入
            // （后处理串行排队后，本函数的执行时刻可能晚于拍摄数秒到数十秒，不能在这里取 Date()）。
            gps[kCGImagePropertyGPSDateStamp as String] = Self.gpsDateFormatter.string(from: captureDate)
            gps[kCGImagePropertyGPSTimeStamp as String] = Self.gpsTimeFormatter.string(from: captureDate)

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

        metadata[kCGImagePropertyPixelWidth as String] = Int(output.extent.width)
        metadata[kCGImagePropertyPixelHeight as String] = Int(output.extent.height)
        if rawRecipe != nil {
            metadata.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        }
        // Encoded pixels are sRGB for every source, including processed HEIC. Do
        // not retain an input's P3/uncalibrated EXIF tag beside the output sRGB ICC.
        var outputExif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        outputExif[kCGImagePropertyExifColorSpace as String] = 1
        outputExif[kCGImagePropertyExifPixelXDimension as String] = Int(output.extent.width)
        outputExif[kCGImagePropertyExifPixelYDimension as String] = Int(output.extent.height)
        metadata[kCGImagePropertyExifDictionary as String] = outputExif
        metadata.removeValue(forKey: kCGImagePropertyDepth as String)
        let outputWithMetadata = output.settingProperties(metadata)

        let hdrImage: CIImage?
        if capturesHDR, let rawRecipe {
            guard PhotoCaptureMode.supportsHDR, rawRecipe.version == 4,
                  let hdrSource = RawFilmRenderer.develop(imageData, recipe: rawRecipe,
                    extendedDynamicRangeAmount: 1, cancellation: cancellation) else { return nil }
            let aligned = hdrSource.oriented(forExifOrientation: exifOrientation).cropped(to: ciInput.extent)
            guard let extended = FilmHDRHighlights.applying(to: output, source: aligned) else { return nil }
            hdrImage = extended
        } else if capturesHDR, #available(iOS 18.0, *) {
            hdrImage = FilmHDRHighlights.applyingNativeGainMap(from: imageData, to: output,
                orientedSourceExtent: inputExtent, exifOrientation: exifOrientation)
        } else {
            hdrImage = nil
        }

        let outExtent = output.extent
        let outMP = (outExtent.isInfinite || outExtent.isEmpty) ? 0 : (outExtent.width * outExtent.height) / 1_000_000

        guard cancellation?.isCancelled != true else { return nil }
        let contextSpan = trace?.span("film_context")
        let ciContext = renderingContext(raw: rawRecipe != nil)
        contextSpan?.end()
        guard cancellation?.isCancelled != true else { return nil }
        // The encode span includes ALL lazy GPU effect evaluation (chromatic/LUT/optics/grain)
        // plus HEIF compression — CIImage graphs materialize only inside the encoder.
        let encodeSpan = trace?.span("film_encode")
        let encodedOutput: PhotoImageEncoder.Output?
        do {
            defer { encodeSpan?.end() }
            encodedOutput = PhotoImageEncoder.encode(outputWithMetadata, context: ciContext,
                colorSpace: srgbColorSpace, legacyQuality: outputQuality, mode: encodingMode,
                hdrImage: hdrImage, cancellation: cancellation)
        }
        guard let encoded = encodedOutput else {
            if cancellation?.isCancelled != true { Log.lut.error("lut_apply_failed reason=render_failed") }
            return nil
        }
        let rendered = encoded.data
        let codec = encoded.decision.codec.rawValue
        if encoded.decision.codec != .heif10 {
            Log.lut.info("lut_render_fallback codec=\(codec, privacy: .public) reason=preferred_codec_unavailable")
        }
        guard cancellation?.isCancelled != true else { return nil }

        DiagnosticTrace(id: diagnosticCaptureID?.uuidString ?? "photo-encoder").event("photo_encoding",
            "mode=\(encoded.decision.mode.rawValue) scene=\(grain.isEnabled ? "film_grain" : "clean_render") " +
            "pixels=\(Int(outExtent.width * outExtent.height)) width=\(Int(outExtent.width)) height=\(Int(outExtent.height)) " +
            "codec=\(codec) source_bytes=\(imageData.count) output_bytes=\(rendered.count) " +
            "selected_quality=\(String(format: "%.2f", Double(encoded.decision.quality))) grain_amount=\(String(format: "%.3f", grain.amount)) " +
            "grain_response=\(grain.responseIdentifier)")

        // 🔑 一击定位行：像素与 metadata 一次编码完成后。codec / 输出像素尺寸 / 百万像素 / 质量参数 /
        // 输入原始字节 / 编码后字节 全在一行。若 rendered_bytes 这里就只有几百 KB 而 out_dims 是完整
        // ~5500×4100，则问题在编码质量；若 out_dims 本身就小，则问题在采集/解码端。
        Log.lut.info("lut_render_done codec=\(codec, privacy: .public) out_dims=\(Int(outExtent.width))x\(Int(outExtent.height)) mp=\(String(format: "%.1f", outMP)) quality=\(String(format: "%.2f", Double(encoded.decision.quality))) grain=\(String(format: "%.3f", grain.amount)) optics=\(optics.isEnabled) halation=\(String(format: "%.2f", optics.halationAmount)) bloom=\(String(format: "%.2f", optics.bloomAmount)) headroom=\(String(format: "%.2f", optics.headroomAmount)) in_bytes=\(imageData.count) rendered_bytes=\(rendered.count)")

        if wantsStageDiagnostics, let diagnosticCaptureID {
            writeStageDiagnostics(
                id: diagnosticCaptureID,
                original: imageData,
                stages: [("1_input_sdr", ciInput), ("2_after_lut", stages.graded), ("3_after_optics", stages.optical),
                         ("4_after_grain", stages.final)],
                context: ciContext,
                cancellation: cancellation
            )
            CaptureComparisonDiagnostics.writeStages([("input_sdr", ciInput), ("after_lut", stages.graded),
                ("after_optics", stages.optical), ("after_grain", stages.final)] +
                (FilmImagePipeline.decodePhoto(rendered).map { [(name: "encoded", image: $0)] } ?? []),
                context: ciContext, id: diagnosticCaptureID)
        }

        guard cancellation?.isCancelled != true else { return nil }
        // Pixels and metadata have already been encoded together in a single pass.
        timer.end("in=\(imageData.count)B out=\(rendered.count)B gps=\(location != nil)")
        return rendered
    }
}
