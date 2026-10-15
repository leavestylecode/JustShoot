import Foundation

// MARK: - 曲线基础数据

/// UI 绘图、色阶预览与 LUT 合成共用的 256 点曲线表。
struct CurvePreviewData: Hashable, Sendable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]
    let master: [Float]
}

struct CurveRGBSample: Sendable {
    let red: Float
    let green: Float
    let blue: Float
}

struct CurveControlPoint: Codable, Hashable, Sendable {
    var input: Float
    var output: Float
}

/// 三次样条及查表运算集中在这里，内置曲线与用户曲线不会出现两套渲染算法。
enum CurveMath {
    static let sampleCount = 256
    static let identityTable = (0..<sampleCount).map { Float($0) / Float(sampleCount - 1) }
    /// 首版自定义曲线的固定输入位置，仅用于旧数据迁移。
    static let legacyEditorInputs: [Float] = [0, 0.25, 0.5, 0.75, 1]

    static var identityPoints: [CurveControlPoint] {
        [
            CurveControlPoint(input: 0, output: 0),
            CurveControlPoint(input: 1, output: 1)
        ]
    }

    static func sample(_ table: [Float], at value: Float) -> Float {
        guard !value.isNaN else { return 0 }
        guard !table.isEmpty else { return min(max(value, 0), 1) }
        let position = min(max(value, 0), 1) * Float(table.count - 1)
        let lower = Int(position)
        guard lower < table.count - 1 else { return table[table.count - 1] }
        let fraction = position - Float(lower)
        return table[lower] * (1 - fraction) + table[lower + 1] * fraction
    }

    /// 自然三次样条。节点处一阶、二阶导数连续，不会出现逐段折线感；
    /// 样条允许合理过冲以获得自然弧度，最终输出再裁到照片通道有效范围 [0, 1]。
    static func expand(_ points: [CurveControlPoint]) -> [Float] {
        guard points.count >= 2,
              points.first?.input == 0,
              points.last?.input == 1,
              points.allSatisfy({ $0.input.isFinite && $0.output.isFinite
                  && (0...1).contains($0.input) && (0...1).contains($0.output) }) else {
            return identityTable
        }

        let count = points.count
        let inputs = points.map { Double($0.input) }
        let outputs = points.map { Double($0.output) }
        var widths = [Double](repeating: 0, count: count - 1)
        for index in widths.indices {
            widths[index] = inputs[index + 1] - inputs[index]
            guard widths[index] > 0 else { return identityTable }
        }
        if points.allSatisfy({ $0.input == $0.output }) { return identityTable }

        // 自然边界：首尾二阶导数为 0。内部二阶导数由三对角方程组求解。
        var secondDerivatives = [Double](repeating: 0, count: count)
        let interiorCount = count - 2
        if interiorCount > 0 {
            var lower = [Double](repeating: 0, count: interiorCount)
            var diagonal = [Double](repeating: 0, count: interiorCount)
            var upper = [Double](repeating: 0, count: interiorCount)
            var rightHandSide = [Double](repeating: 0, count: interiorCount)

            for interiorIndex in 1..<(count - 1) {
                let row = interiorIndex - 1
                let leftWidth = widths[interiorIndex - 1]
                let rightWidth = widths[interiorIndex]
                lower[row] = row > 0 ? leftWidth : 0
                diagonal[row] = 2 * (leftWidth + rightWidth)
                upper[row] = row < interiorCount - 1 ? rightWidth : 0
                rightHandSide[row] = 6 * (
                    (outputs[interiorIndex + 1] - outputs[interiorIndex]) / rightWidth
                    - (outputs[interiorIndex] - outputs[interiorIndex - 1]) / leftWidth
                )
            }

            // Thomas algorithm：O(n) 解三对角系统；曲线最多 16 点，开销远低于 LUT 合成。
            if interiorCount > 1 {
                for row in 1..<interiorCount {
                    let factor = lower[row] / diagonal[row - 1]
                    diagonal[row] -= factor * upper[row - 1]
                    rightHandSide[row] -= factor * rightHandSide[row - 1]
                }
            }

            var solution = [Double](repeating: 0, count: interiorCount)
            solution[interiorCount - 1] = rightHandSide[interiorCount - 1]
                / diagonal[interiorCount - 1]
            if interiorCount > 1 {
                for row in stride(from: interiorCount - 2, through: 0, by: -1) {
                    solution[row] = (rightHandSide[row] - upper[row] * solution[row + 1])
                        / diagonal[row]
                }
            }
            for row in solution.indices {
                secondDerivatives[row + 1] = solution[row]
            }
        }

        var table = [Float](repeating: 0, count: sampleCount)
        var segment = 0
        for sampleIndex in table.indices {
            let input = Double(sampleIndex) / Double(table.count - 1)
            while segment < count - 2 && input > inputs[segment + 1] {
                segment += 1
            }

            let width = widths[segment]
            let leftWeight = (inputs[segment + 1] - input) / width
            let rightWeight = (input - inputs[segment]) / width
            let output = leftWeight * outputs[segment]
                + rightWeight * outputs[segment + 1]
                + ((leftWeight * leftWeight * leftWeight - leftWeight) * secondDerivatives[segment]
                    + (rightWeight * rightWeight * rightWeight - rightWeight)
                        * secondDerivatives[segment + 1])
                    * width * width / 6
            table[sampleIndex] = Float(min(max(output, 0), 1))
        }
        return table
    }

    static func points(_ pairs: [(Float, Float)]) -> [CurveControlPoint] {
        pairs.map { CurveControlPoint(input: $0.0, output: $0.1) }
    }
}

// MARK: - 内置曲线

/// 内置曲线的稳定标识；旧选择的兼容映射集中在 LegacyCurveMigration。
enum CurvePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case filmSoft = "softShoulder"
    case punch = "highContrast"
    case matte = "matteSCurve"
    case crossProcess

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "Neutral")
        case .filmSoft: return String(localized: "Soft Contrast")
        case .punch: return String(localized: "S-Curve")
        case .matte: return String(localized: "Matte S")
        case .crossProcess: return String(localized: "X-Pro")
        }
    }

    var usesChannelCurves: Bool {
        self == .crossProcess
    }

    var summary: String {
        switch self {
        case .none: return String(localized: "Keep the film's original tones.")
        case .filmSoft: return String(localized: "Reduce midtone contrast.")
        case .punch: return String(localized: "Add midtone contrast with an S-curve.")
        case .matte: return String(localized: "Lift blacks with S-curve contrast.")
        case .crossProcess: return String(localized: "Cool shadows and warm highlights.")
        }
    }

    var controlPoints: (red: [CurveControlPoint], green: [CurveControlPoint], blue: [CurveControlPoint])? {
        switch self {
        case .none:
            return nil
        case .filmSoft:
            // Inverse S: reduce midtone contrast, keeping the black and white endpoints.
            // The previous Film Soft was another contrast-increasing S, overlapping Punch.
            let points = CurveMath.points([
                (0, 0), (0.25, 0.30), (0.50, 0.50), (0.75, 0.70), (1, 1)
            ])
            return (points, points, points)
        case .punch:
            // 暗部校准：曲线作用在 LUT 输出上，若底部保持 0.12→0.045 的陡降，会与胶片本身的
            // 反差叠加把可见纹理挤到黑端。抬高暗部两个控制点（0.12→0.07、0.28→0.20），
            // 中高调斜率基本不变——"punch" 的观感来自中间调反差，不靠压碎阴影。
            let points = CurveMath.points([
                (0, 0), (0.12, 0.07), (0.28, 0.20), (0.50, 0.50),
                (0.72, 0.84), (0.88, 0.955), (1, 1)
            ])
            return (points, points, points)
        case .matte:
            // Lift only the black endpoint, then dip the shadows and raise the lights.
            // The S-shaped middle keeps separation instead of lifting the whole shadow range.
            let points = CurveMath.points([
                (0, 0.075), (0.32, 0.22), (0.50, 0.50),
                (0.72, 0.84), (0.88, 0.955), (1, 1)
            ])
            return (points, points, points)
        case .crossProcess:
            return (
                CurveMath.points([(0, 0), (0.18, 0.07), (0.42, 0.33), (0.62, 0.70), (0.82, 0.93), (1, 1)]),
                CurveMath.points([(0, 0.055), (0.18, 0.15), (0.42, 0.39), (0.62, 0.67), (0.82, 0.84), (1, 0.97)]),
                CurveMath.points([(0, 0.10), (0.18, 0.24), (0.42, 0.44), (0.62, 0.60), (0.82, 0.76), (1, 0.90)])
            )
        }
    }

    private static let tableCache: [CurvePreset: CurvePreviewData] = {
        var cache: [CurvePreset: CurvePreviewData] = [:]
        for preset in CurvePreset.allCases {
            guard let points = preset.controlPoints else { continue }
            let red = CurveMath.expand(points.red)
            let green = CurveMath.expand(points.green)
            let blue = CurveMath.expand(points.blue)
            let master = red == green && green == blue ? red
                : red.indices.map { (red[$0] + green[$0] + blue[$0]) / 3 }
            cache[preset] = CurvePreviewData(red: red, green: green, blue: blue, master: master)
        }
        return cache
    }()

    var previewData: CurvePreviewData {
        Self.tableCache[self] ?? CurvePreviewData(
            red: CurveMath.identityTable,
            green: CurveMath.identityTable,
            blue: CurveMath.identityTable,
            master: CurveMath.identityTable
        )
    }
}

// MARK: - 用户曲线持久化模型

/// 用户曲线保存四组自由控制点：主曲线以及 R/G/B 通道曲线。
/// Codable 兼容首版固定五点的 `*Outputs` 字段，升级不会丢失用户已经创建的效果。
struct CustomFilmCurve: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var masterPoints: [CurveControlPoint]
    var redPoints: [CurveControlPoint]
    var greenPoints: [CurveControlPoint]
    var bluePoints: [CurveControlPoint]
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, isVisible, masterPoints, redPoints, greenPoints, bluePoints, createdAt, updatedAt
        case masterOutputs, redOutputs, greenOutputs, blueOutputs
    }

    init(name: String) {
        id = UUID()
        self.name = name
        isVisible = true
        masterPoints = CurveMath.identityPoints
        redPoints = CurveMath.identityPoints
        greenPoints = CurveMath.identityPoints
        bluePoints = CurveMath.identityPoints
        createdAt = Date()
        updatedAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt

        func decodePoints(_ pointsKey: CodingKeys, legacyKey: CodingKeys) throws -> [CurveControlPoint] {
            if let points = try container.decodeIfPresent([CurveControlPoint].self, forKey: pointsKey) {
                return points
            }
            let outputs = try container.decodeIfPresent([Float].self, forKey: legacyKey)
                ?? CurveMath.legacyEditorInputs
            return zip(CurveMath.legacyEditorInputs, outputs).map {
                CurveControlPoint(input: $0.0, output: $0.1)
            }
        }

        masterPoints = try decodePoints(.masterPoints, legacyKey: .masterOutputs)
        redPoints = try decodePoints(.redPoints, legacyKey: .redOutputs)
        greenPoints = try decodePoints(.greenPoints, legacyKey: .greenOutputs)
        bluePoints = try decodePoints(.bluePoints, legacyKey: .blueOutputs)
        self = normalized()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(masterPoints, forKey: .masterPoints)
        try container.encode(redPoints, forKey: .redPoints)
        try container.encode(greenPoints, forKey: .greenPoints)
        try container.encode(bluePoints, forKey: .bluePoints)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var filmCurve: FilmCurve { .custom(self) }

    mutating func applyTemplate(_ preset: CurvePreset) {
        guard let points = preset.controlPoints else {
            resetAllChannels()
            return
        }
        if preset.usesChannelCurves {
            masterPoints = CurveMath.identityPoints
            redPoints = points.red
            greenPoints = points.green
            bluePoints = points.blue
        } else {
            masterPoints = points.red
            redPoints = CurveMath.identityPoints
            greenPoints = CurveMath.identityPoints
            bluePoints = CurveMath.identityPoints
        }
    }

    mutating func resetAllChannels() {
        masterPoints = CurveMath.identityPoints
        redPoints = CurveMath.identityPoints
        greenPoints = CurveMath.identityPoints
        bluePoints = CurveMath.identityPoints
    }

    func normalized() -> CustomFilmCurve {
        var copy = self
        copy.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        copy.masterPoints = Self.normalizedPoints(masterPoints)
        copy.redPoints = Self.normalizedPoints(redPoints)
        copy.greenPoints = Self.normalizedPoints(greenPoints)
        copy.bluePoints = Self.normalizedPoints(bluePoints)
        return copy
    }

    private static func normalizedPoints(_ points: [CurveControlPoint]) -> [CurveControlPoint] {
        let sorted = points
            .filter { $0.input.isFinite && $0.output.isFinite }
            .map {
                CurveControlPoint(
                    input: min(max($0.input, 0), 1),
                    output: min(max($0.output, 0), 1)
                )
            }
            .sorted { $0.input < $1.input }

        var unique: [CurveControlPoint] = []
        for point in sorted {
            if let last = unique.last, abs(last.input - point.input) < 0.0005 {
                unique[unique.count - 1] = point
            } else {
                unique.append(point)
            }
        }

        if unique.first?.input ?? 1 > 0.0005 {
            unique.insert(CurveControlPoint(input: 0, output: 0), at: 0)
        } else {
            unique[0].input = 0
        }
        if unique.last?.input ?? 0 < 0.9995 {
            unique.append(CurveControlPoint(input: 1, output: 1))
        } else {
            unique[unique.count - 1].input = 1
        }

        if unique.count > 16 {
            unique = Array(unique.prefix(15)) + [unique[unique.count - 1]]
        }
        return unique.count >= 2 ? unique : CurveMath.identityPoints
    }
}

// MARK: - 统一曲线效果

/// 相机、预览和成片只认识这个值类型；来源可以是内置预设或用户自定义曲线。
struct FilmCurve: Identifiable, Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        case builtIn(CurvePreset)
        case custom(UUID)
    }

    let origin: Origin
    let displayName: String
    let previewData: CurvePreviewData
    let isNeutral: Bool
    let usesChannelCurves: Bool
    private let contentFingerprint: String

    private init(origin: Origin, displayName: String, data: CurvePreviewData, fingerprint: String = "") {
        self.origin = origin
        self.displayName = displayName
        previewData = data
        contentFingerprint = fingerprint
        isNeutral = [data.red, data.green, data.blue].allSatisfy { table in
            zip(table, CurveMath.identityTable).allSatisfy { pair in
                abs(pair.0 - pair.1) <= Float.ulpOfOne
            }
        }
        usesChannelCurves = data.red != data.green || data.green != data.blue
    }

    var id: String {
        switch origin {
        case .builtIn(let preset): return preset.rawValue
        case .custom(let id): return "custom:\(id.uuidString.lowercased())"
        }
    }

    var builtInPreset: CurvePreset? {
        guard case .builtIn(let preset) = origin else { return nil }
        return preset
    }

    /// Render identity follows the actual tables, including reset or collinear custom curves.
    /// Returning the original LUT for identity preserves finite HDR values outside [0, 1].
    var cacheKeySuffix: String {
        if isNeutral { return "" }
        switch origin {
        case .builtIn(let preset): return "#curve-\(preset.rawValue)"
        case .custom(let id): return "#curve-user-\(id.uuidString.lowercased())-\(contentFingerprint)"
        }
    }

    func sampleGray(_ input: Float) -> CurveRGBSample {
        CurveRGBSample(
            red: CurveMath.sample(previewData.red, at: input),
            green: CurveMath.sample(previewData.green, at: input),
            blue: CurveMath.sample(previewData.blue, at: input)
        )
    }

    func applied(to lut: CubeLUT) -> CubeLUT {
        guard !isNeutral, (2...CubeLUT.maximumDimension).contains(lut.dimension),
              lut.data.count == lut.dimension * lut.dimension * lut.dimension * 4 * MemoryLayout<Float>.stride else { return lut }
        // A tiny cube has too few samples to represent nonlinear tone curves. Bake the
        // curve into a denser source shared by preview, stills and Live video.
        let source = CurveLUTComposer.preparedSource(lut)
        var data = source.data
        data.withUnsafeMutableBytes { rawBuffer in
            let rgba = rawBuffer.bindMemory(to: Float.self)
            for index in stride(from: 0, to: rgba.count, by: 4) {
                rgba[index] = CurveMath.sample(previewData.red, at: rgba[index])
                rgba[index + 1] = CurveMath.sample(previewData.green, at: rgba[index + 1])
                rgba[index + 2] = CurveMath.sample(previewData.blue, at: rgba[index + 2])
            }
        }
        return CubeLUT(data: data, dimension: source.dimension)
    }

    static func builtIn(_ preset: CurvePreset) -> FilmCurve {
        FilmCurve(origin: .builtIn(preset), displayName: preset.displayName, data: preset.previewData)
    }

    static func custom(_ definition: CustomFilmCurve) -> FilmCurve {
        let normalized = definition.normalized()
        let master = CurveMath.expand(normalized.masterPoints)
        func combined(_ points: [CurveControlPoint]) -> [Float] {
            let channel = CurveMath.expand(points)
            if channel == CurveMath.identityTable { return master }
            if master == CurveMath.identityTable { return channel }
            return master.map { CurveMath.sample(channel, at: $0) }
        }
        let red = combined(normalized.redPoints)
        let green = combined(normalized.greenPoints)
        let blue = combined(normalized.bluePoints)
        let composite = red == green && green == blue ? red
            : red.indices.map { (red[$0] + green[$0] + blue[$0]) / 3 }
        return FilmCurve(origin: .custom(normalized.id), displayName: normalized.name,
            data: CurvePreviewData(red: red, green: green, blue: blue, master: composite),
            fingerprint: fingerprint(normalized))
    }

    /// Hash only render inputs: renaming or hiding a curve does not invalidate its pixels.
    /// Explicit channel/count separators make the cache identity independent of storage layout.
    private static func fingerprint(_ definition: CustomFilmCurve) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 1_099_511_628_211
        }
        for (channel, points) in [definition.masterPoints, definition.redPoints,
                                  definition.greenPoints, definition.bluePoints].enumerated() {
            mix(UInt64(channel))
            mix(UInt64(points.count))
            for point in points {
                mix(UInt64(point.input.bitPattern))
                mix(UInt64(point.output.bitPattern))
            }
        }
        return String(hash, radix: 16)
    }
}
