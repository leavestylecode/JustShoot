import Foundation

// MARK: - 曲线预览数据

/// UI 绘图与色阶预览共用的只读曲线表。每条通道曲线都是 256 个 [0, 1] 采样值。
struct CurvePreviewData: Sendable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]
    let master: [Float]
}

/// 某个中性灰输入经过逐通道曲线后的 RGB 输出，用于绘制预设色阶。
struct CurveRGBSample: Sendable {
    let red: Float
    let green: Float
    let blue: Float
}

// MARK: - 拍摄曲线预设

/// 叠加在胶片 LUT 之后的一维逐通道曲线。
///
/// 预设按摄影后期中真正有区分度的响应组织：中性、胶片 toe/shoulder、开放暗部、
/// 高反差、抬黑哑光、压缩动态范围，以及两种 RGB 通道风格。曲线会一次性烘焙进
/// 3D LUT；实时 Metal 预览、静态照片与 Live Photo 视频消费同一份数据。
enum CurvePreset: String, CaseIterable, Identifiable, Sendable {
    case none
    // Raw value 保留旧版本名称，让已经写入 @AppStorage 的选择继续有效。
    case filmSoft = "softShoulder"
    case openShadows = "airyPastel"
    case punch = "highContrast"
    case matte = "matteShadow"
    case fade = "softFaded"
    case warmPrint = "warmRetro"
    case crossProcess

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "Neutral")
        case .filmSoft: return String(localized: "Film Soft")
        case .openShadows: return String(localized: "Open Shadows")
        case .punch: return String(localized: "Punch")
        case .matte: return String(localized: "Matte")
        case .fade: return String(localized: "Fade")
        case .warmPrint: return String(localized: "Warm Print")
        case .crossProcess: return String(localized: "X-Pro")
        }
    }

    /// RGB 曲线需要在缩略图中分别显示三条通道；纯明度预设只显示主曲线，减少噪声。
    var usesChannelCurves: Bool {
        self == .warmPrint || self == .crossProcess
    }

    /// none 保持原 LUT 键；其他预设使用稳定后缀，供预览和出片共享。
    var cacheKeySuffix: String {
        self == .none ? "" : "#curve-\(rawValue)"
    }

    static func fromCacheKeySuffix(_ key: String) -> CurvePreset? {
        guard let range = key.range(of: "#curve-", options: .backwards) else { return nil }
        return CurvePreset(rawValue: String(key[range.upperBound...]))
    }

    // MARK: - 曲线定义

    /// 每通道控制点 (input, output)，使用单调三次插值展开。nil 表示恒等响应。
    private var controlPoints: (red: [(Float, Float)], green: [(Float, Float)], blue: [(Float, Float)])? {
        switch self {
        case .none:
            return nil

        case .filmSoft:
            // 典型胶片显示响应：柔和 toe + shoulder，中间调保持自然，端点不过度剪切。
            let points: [(Float, Float)] = [
                (0, 0), (0.08, 0.045), (0.25, 0.20), (0.50, 0.52),
                (0.75, 0.82), (0.92, 0.965), (1, 1)
            ]
            return (points, points, points)

        case .openShadows:
            // 类似 Film Extra Shadow：真黑仍为 0，只降低暗部局部反差以保留纹理。
            let points: [(Float, Float)] = [
                (0, 0), (0.08, 0.11), (0.25, 0.31), (0.50, 0.54),
                (0.75, 0.79), (0.92, 0.95), (1, 1)
            ]
            return (points, points, points)

        case .punch:
            // 明确的强 S 曲线：压暗阴影、提亮亮部，适合需要硬朗反差的胶片 LUT。
            let points: [(Float, Float)] = [
                (0, 0), (0.12, 0.045), (0.28, 0.17), (0.50, 0.50),
                (0.72, 0.84), (0.88, 0.955), (1, 1)
            ]
            return (points, points, points)

        case .matte:
            // 抬起黑位但基本保留白点；区别于 Fade 的全动态范围压缩。
            let points: [(Float, Float)] = [
                (0, 0.06), (0.16, 0.18), (0.35, 0.36), (0.62, 0.66),
                (0.84, 0.88), (1, 0.985)
            ]
            return (points, points, points)

        case .fade:
            // 同时抬黑与压白，缩短输出动态范围，得到真正的低反差褪色响应。
            let points: [(Float, Float)] = [
                (0, 0.075), (0.25, 0.29), (0.50, 0.51), (0.75, 0.72), (1, 0.93)
            ]
            return (points, points, points)

        case .warmPrint:
            // 冷一点的暗部 + 暖黄高光，模拟暖调印相纸，而不是简单给全图加黄色。
            let red: [(Float, Float)] = [
                (0, 0.015), (0.15, 0.10), (0.38, 0.34), (0.62, 0.68), (0.85, 0.91), (1, 1)
            ]
            let green: [(Float, Float)] = [
                (0, 0.025), (0.15, 0.12), (0.38, 0.35), (0.62, 0.66), (0.85, 0.88), (1, 0.985)
            ]
            let blue: [(Float, Float)] = [
                (0, 0.055), (0.15, 0.15), (0.38, 0.36), (0.62, 0.61), (0.85, 0.80), (1, 0.93)
            ]
            return (red, green, blue)

        case .crossProcess:
            // E-6/C-41 风格：强 S 响应，阴影偏青蓝、高光偏暖黄，保留为明确的实验性选项。
            let red: [(Float, Float)] = [
                (0, 0), (0.18, 0.07), (0.42, 0.33), (0.62, 0.70), (0.82, 0.93), (1, 1)
            ]
            let green: [(Float, Float)] = [
                (0, 0.055), (0.18, 0.15), (0.42, 0.39), (0.62, 0.67), (0.82, 0.84), (1, 0.97)
            ]
            let blue: [(Float, Float)] = [
                (0, 0.10), (0.18, 0.24), (0.42, 0.44), (0.62, 0.60), (0.82, 0.76), (1, 0.90)
            ]
            return (red, green, blue)
        }
    }

    // MARK: - 256 点查表

    private static let identityTable = (0..<256).map { Float($0) / 255.0 }

    private static let tableCache: [CurvePreset: CurvePreviewData] = {
        var cache: [CurvePreset: CurvePreviewData] = [:]
        for preset in CurvePreset.allCases {
            guard let points = preset.controlPoints else { continue }
            let red = Self.expandToTable(points.red)
            let green = Self.expandToTable(points.green)
            let blue = Self.expandToTable(points.blue)
            let master = red.indices.map { (red[$0] + green[$0] + blue[$0]) / 3 }
            cache[preset] = CurvePreviewData(red: red, green: green, blue: blue, master: master)
        }
        return cache
    }()

    /// UI 使用的真实曲线数据；Neutral 返回恒等表，避免绘图层自行构造近似数据。
    var previewData: CurvePreviewData {
        Self.tableCache[self] ?? CurvePreviewData(
            red: Self.identityTable,
            green: Self.identityTable,
            blue: Self.identityTable,
            master: Self.identityTable
        )
    }

    /// 返回一个中性灰输入经过当前曲线后的 RGB 值，供 UI 的五档色阶预览使用。
    func sampleGray(_ input: Float) -> CurveRGBSample {
        let clamped = min(max(input, 0), 1)
        guard let tables = Self.tableCache[self] else {
            return CurveRGBSample(red: clamped, green: clamped, blue: clamped)
        }
        return CurveRGBSample(
            red: Self.sampleTable(tables.red, clamped),
            green: Self.sampleTable(tables.green, clamped),
            blue: Self.sampleTable(tables.blue, clamped)
        )
    }

    /// 把曲线烘焙进 3D LUT。Data 使用写时复制，只复制一次底层存储，不再先转成临时 Float 数组。
    func applied(to lut: CubeLUT) -> CubeLUT {
        guard let tables = Self.tableCache[self], lut.data.count.isMultiple(of: MemoryLayout<Float>.stride * 4) else {
            return lut
        }

        var data = lut.data
        data.withUnsafeMutableBytes { rawBuffer in
            let rgba = rawBuffer.bindMemory(to: Float.self)
            for index in stride(from: 0, to: rgba.count, by: 4) {
                rgba[index] = Self.sampleTable(tables.red, rgba[index])
                rgba[index + 1] = Self.sampleTable(tables.green, rgba[index + 1])
                rgba[index + 2] = Self.sampleTable(tables.blue, rgba[index + 2])
            }
        }
        return CubeLUT(data: data, dimension: lut.dimension)
    }

    private static func sampleTable(_ table: [Float], _ value: Float) -> Float {
        let position = min(max(value, 0), 1) * Float(table.count - 1)
        let lower = Int(position)
        guard lower < table.count - 1 else { return table[table.count - 1] }
        let fraction = position - Float(lower)
        return table[lower] * (1 - fraction) + table[lower + 1] * fraction
    }

    /// 加权单调三次 Hermite 插值。控制点单调时不会产生 ringing 或越过 [0, 1]。
    private static func expandToTable(_ points: [(Float, Float)]) -> [Float] {
        precondition(points.count >= 2, "曲线至少需要两个控制点")
        precondition(points.first?.0 == 0 && points.last?.0 == 1, "曲线必须覆盖完整输入范围")

        let count = points.count
        var widths = [Float](repeating: 0, count: count - 1)
        var slopes = [Float](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            widths[index] = points[index + 1].0 - points[index].0
            precondition(widths[index] > 0, "曲线控制点必须按 input 严格递增")
            slopes[index] = (points[index + 1].1 - points[index].1) / widths[index]
        }

        var tangents = [Float](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            if slopes[index - 1] * slopes[index] <= 0 {
                tangents[index] = 0
            } else {
                let leftWeight = 2 * widths[index] + widths[index - 1]
                let rightWeight = widths[index] + 2 * widths[index - 1]
                tangents[index] = (leftWeight + rightWeight)
                    / (leftWeight / slopes[index - 1] + rightWeight / slopes[index])
            }
        }

        var table = [Float](repeating: 0, count: 256)
        var segment = 0
        for sampleIndex in table.indices {
            let input = Float(sampleIndex) / Float(table.count - 1)
            while segment < count - 2 && input > points[segment + 1].0 {
                segment += 1
            }

            let width = widths[segment]
            let t = (input - points[segment].0) / width
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let output = h00 * points[segment].1
                + h10 * width * tangents[segment]
                + h01 * points[segment + 1].1
                + h11 * width * tangents[segment + 1]
            table[sampleIndex] = min(max(output, 0), 1)
        }
        return table
    }
}
