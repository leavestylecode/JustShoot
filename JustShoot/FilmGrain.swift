import Foundation
import CoreImage

// MARK: - 自动胶片渲染配置

/// 胶片乳剂的颗粒结构类别。用户不需要看到或配置；它只描述同 ISO 下不同胶片的质感差异。
private enum FilmGrainCharacter: Sendable {
    case ultraFine
    case fine
    case balanced
    case expressive

    var amountScale: Float {
        switch self {
        case .ultraFine: return 0.78
        case .fine: return 0.92
        case .balanced: return 1.08
        case .expressive: return 1.45
        }
    }

    var sizeScale: Float {
        switch self {
        case .ultraFine: return 0.88
        case .fine: return 0.95
        case .balanced: return 1.08
        case .expressive: return 1.40
        }
    }

    var chroma: Float {
        switch self {
        case .ultraFine: return 0.045
        case .fine: return 0.060
        case .balanced: return 0.075
        case .expressive: return 0.100
        }
    }
}

/// 所有“胶片自身”的技术参数统一从这里输出。颗粒 + 光学（halation/bloom/headroom）+
/// 色温响应（未校白）；CameraView 只消费结果，不暴露一排用户开关。
struct FilmRenderProfile: Sendable, Equatable, Codable {
    let grain: FilmGrainParameters
    let optics: FilmOpticsParameters
    /// Optional 仅为 journal 旧任务解码兼容（早期 manifest 无此键 → nil → 中性不响应）。
    let chromatic: FilmChromaticResponseParameters?

    var effectiveChromatic: FilmChromaticResponseParameters { chromatic ?? .neutral }
}

// MARK: - 胶片原生色温响应（未校白模拟）
//
// 数码管线先 AWB 校白再套 LUT，等价于“每卷胶片都被完美校白”——而胶片的味道很大部分
// 来自**没有**校白：T 卷在日光下整卷偏蓝、日光卷在钨丝灯下偏橙、400H 阴影里的青调。
// 这里按胶片原生平衡色温对场景色温的偏差，在线性 RGB 域做 von Kries 对角响应：
//
//   gain = W(sceneCCT) / W(nativeCCT)     （W = 该色温单位白向量的线性光值）
//
// AWB 已把场景白拉到中性，乘上 gain 恰好把它“放回”该胶片乳剂下的原生偏色。
// strength 对每通道增益取幂（0 = 完全校白 = 现状，1 = 完整原生响应）。色温 tint 轴
// 不参与（AWB 已拉平；初版只做 CCT 轴，非线性的阴影/高光 tint 待真机校准后再上）。
struct FilmChromaticResponseParameters: Sendable, Equatable, Codable {
    /// 胶片乳剂的设计平衡色温（K）。Tungsten 电影卷 3200，其余日光卷 5500。
    let nativeCCT: Float
    /// 0 = 完全校白（现状行为），1 = 完整原生响应。
    let strength: Float
    /// Absent in older capture recipes: replay those with their original response.
    let highlightProtection: Bool?

    init(nativeCCT: Float, strength: Float, highlightProtection: Bool = true) {
        self.nativeCCT = nativeCCT
        self.strength = strength
        self.highlightProtection = highlightProtection
    }

    static let neutral = FilmChromaticResponseParameters(nativeCCT: 6_500, strength: 0, highlightProtection: false)

    var isNeutral: Bool { strength <= 0.0001 }
    var protectsHighlights: Bool { highlightProtection ?? false }

    /// 场景色温 → 线性 RGB 域的每通道增益。读数缺失/无效时返回单位增益（不响应）。
    func responseGain(sceneCCT: Float?) -> SIMD3<Float> {
        guard !isNeutral, let sceneCCT, sceneCCT.isFinite else { return .one }
        let scene = Self.linearRGBUnitWhite(clamping: sceneCCT)
        let native = Self.linearRGBUnitWhite(clamping: nativeCCT)
        var gain = SIMD3<Float>(
            scene.x / max(native.x, 0.01),
            scene.y / max(native.y, 0.01),
            scene.z / max(native.z, 0.01)
        )
        // 极端读数（混合光源/读数跳变）防失控；真实乳剂的偏色也从不无限大。
        for index in gain.indices {
            let clamped = min(max(gain[index], 0.5), 2.2)
            gain[index] = pow(clamped, strength)
        }
        return gain
    }

    /// CCT → 单位白向量（线性光域，未做显示域钳制）。
    /// 用 Planckian 轨迹的标准分段多项式（Wyszecki & Stiles 拟合，1667–25000K 有效）求
    /// 黑体 xy 色度 → XYZ → linear sRGB。不能用 sRGB 显示域拟合（如 Tanner Helland）：
    /// 它在暖端把红通道饱和在 1，红端辐照度比例丢失，von Kries 的商恒为 1——
    /// 钨丝灯下日光卷的橙调会消失。向量不做归一化（增益是两向量的商，尺度约掉）。
    static func linearRGBUnitWhite(clamping kelvin: Float) -> SIMD3<Float> {
        let t = min(max(kelvin, 2_000), 15_000)
        let x: Float
        if t <= 4_000 {
            x = -0.266_123_9e9 / (t * t * t) - 0.234_358_0e6 / (t * t) + 0.877_695_6e3 / t + 0.179_910
        } else {
            x = -3.025_846_9e9 / (t * t * t) + 2.107_037_9e6 / (t * t) + 0.222_634_7e3 / t + 0.240_390
        }
        let y: Float
        if t <= 2_222 {
            y = -1.106_381_4 * x * x * x - 1.348_110_2 * x * x + 2.185_558_32 * x - 0.202_196_83
        } else if t <= 4_000 {
            y = -0.954_947_6 * x * x * x - 1.374_185_93 * x * x + 2.091_370_15 * x - 0.167_488_67
        } else {
            y = 3.081_758_0 * x * x * x - 5.873_386_7 * x * x + 3.751_129_97 * x - 0.370_014_83
        }
        guard y > 0 else { return .one }
        // xy 色度 → XYZ（Y=1），再经 sRGB(D65) 逆矩阵到线性光。
        let bigX = x / y
        let bigZ = (1 - x - y) / y
        let r = 3.240_6 * bigX - 1.537_2 - 0.498_6 * bigZ
        let g = -0.968_9 * bigX + 1.875_8 + 0.041_5 * bigZ
        let b = 0.055_7 * bigX - 0.204_0 + 1.057_0 * bigZ
        return SIMD3<Float>(max(r, 0), max(g, 0), max(b, 0))
    }
}

private enum AutomaticFilmProfile {
    /// 以 ISO 50 为基线、按曝光档数平滑增长，再由乳剂结构修正。避免为每种胶片散落魔法数。
    static func grain(
        iso: Float,
        character: FilmGrainCharacter,
        response: FilmGrainParameters.Response? = nil
    ) -> FilmGrainParameters {
        let clampedISO = min(max(iso, 50), 3200)
        let normalizedStops = log2(clampedISO / 50) / 6
        let baseAmount = 0.034 + normalizedStops * 0.032
        let baseSize = 0.95 + normalizedStops * 0.70
        return FilmGrainParameters(
            amount: baseAmount * character.amountScale * (response == .balanced ? 0.94 : 1),
            size: baseSize * character.sizeScale,
            chroma: character.chroma,
            response: response
        )
    }
}

struct FilmGrainParameters: Sendable, Equatable, Codable {
    enum Response: String, Sendable, Codable {
        case balanced = "balanced_v2"
        case balancedAreaMatched = "balanced_area_v3"
    }

    let amount: Float
    let size: Float
    let chroma: Float
    /// Missing in older journals: keep their frozen, original grain rendering.
    let response: Response?

    init(amount: Float, size: Float, chroma: Float, response: Response? = nil) {
        self.amount = amount
        self.size = size
        self.chroma = chroma
        self.response = response
    }

    static let disabled = FilmGrainParameters(amount: 0, size: 1, chroma: 0)

    var isEnabled: Bool { amount > 0.0001 }
    var shaderResponse: Float { response == nil ? 0 : 1 }
    var responseIdentifier: String { response?.rawValue ?? "legacy_v1" }

    /// New captures use zero-mean texture in shadows/skin and area-matched preview
    /// amplitude. Frozen v1/v2 journals keep both their old tone and sampling.
    var forUnifiedCapture: Self {
        guard isEnabled else { return self }
        return Self(amount: amount, size: size, chroma: chroma, response: .balancedAreaMatched)
    }

    func renderAmount(forLongEdge longEdge: CGFloat) -> Float {
        guard isEnabled, response == .balancedAreaMatched else { return amount }
        return amount * FilmGrainSampling.amplitudeScale(size: size, longEdge: longEdge)
    }

    /// 颗粒代表胶片画幅上的结构，而不是固定像素噪声。预览最小为 1px，完整照片随长边放大。
    func pixelSize(forLongEdge longEdge: CGFloat) -> Float {
        max(1, size * Float(longEdge) / 4000)
    }
}

extension FilmPreset {
    private var grainResponse: FilmGrainParameters.Response? {
        switch self {
        case .kodakPortra400, .fujiPro400H: return .balanced
        default: return nil
        }
    }

    private var grainCharacter: FilmGrainCharacter {
        switch self {
        case .fujiProvia100F:
            return .ultraFine
        case .fujiPro400H, .kodakPortra400:
            return .fine
        case .fujiC200:
            return .balanced
        default:
            return .ultraFine
        }
    }

    /// 胶片原生色温响应（初版保守值，待真机在日光/阴影/钨丝灯三环境实拍校准）：
    /// 反转片响应较浅，现代消费负片居中偏克制；新拍摄不额外叠加此旧版响应。
    var chromaticResponse: FilmChromaticResponseParameters {
        switch self {
        case .kodakPortra400:   return FilmChromaticResponseParameters(nativeCCT: 5_500, strength: 0.42)
        case .fujiPro400H:      return FilmChromaticResponseParameters(nativeCCT: 5_500, strength: 0.46)
        case .fujiC200:         return FilmChromaticResponseParameters(nativeCCT: 5_500, strength: 0.38)
        case .fujiProvia100F:   return FilmChromaticResponseParameters(nativeCCT: 5_500, strength: 0.24)
        default: return .neutral
        }
    }

    var renderProfile: FilmRenderProfile {
        if rawSimulation != nil {
            return FilmRenderProfile(grain: .disabled, optics: .disabled, chromatic: .neutral)
        }
        return FilmRenderProfile(
            grain: AutomaticFilmProfile.grain(iso: iso, character: grainCharacter, response: grainResponse),
            optics: filmOptics,
            chromatic: chromaticResponse
        )
    }
}

extension FilmSource {
    var renderProfile: FilmRenderProfile {
        switch self {
        case .preset(let preset):
            return preset.renderProfile
        case .custom(_, _, let iso, _):
            // 自定义 LUT = 用户导入什么就出什么：保留颗粒的 ISO 自动性，光学与色温响应关闭。
            return FilmRenderProfile(
                grain: AutomaticFilmProfile.grain(iso: iso, character: .balanced),
                optics: .disabled,
                chromatic: nil
            )
        }
    }
}

// MARK: - Core Image 胶片颗粒

/// 静态图与 Live Photo 共用的确定性 Core Image kernel。
///
/// 以共享亮度颗粒为主、混入少量独立 RGB 结构。新的人像卷响应使用对称余量，
/// 避免暗部正噪声比负噪声更强而抬灰；旧任务保留原有余量算法。
enum FilmGrainRenderer {
    private static var kernel: CIColorKernel? { FilmImageKernels.shared[.grain] }

    static func applying(
        to image: CIImage,
        parameters: FilmGrainParameters,
        seed: UInt32
    ) -> CIImage {
        guard parameters.isEnabled,
              !image.extent.isEmpty,
              !image.extent.isInfinite,
              let kernel else {
            return image
        }

        let longEdge = max(image.extent.width, image.extent.height)
        let pixelSize = parameters.pixelSize(forLongEdge: longEdge)
        let floatSeed = Float(seed & 0x00FF_FFFF)
        return kernel.apply(
            extent: image.extent,
            arguments: [image, parameters.renderAmount(forLongEdge: longEdge), pixelSize, parameters.chroma, floatSeed,
                        parameters.shaderResponse]
        ) ?? image
    }

    /// Live Photo 使用 1/600 秒时间格生成 seed；静态帧与标记时刻的视频帧可得到同一颗粒。
    static func temporalSeed(base: UInt32, seconds: Double) -> UInt32 {
        let safeSeconds = seconds.isFinite ? max(seconds, 0) : 0
        let tick = UInt32(truncatingIfNeeded: Int64((safeSeconds * 600).rounded()))
        return mixedSeed(base: base, counter: tick)
    }

    static func mixedSeed(base: UInt32, counter: UInt32) -> UInt32 {
        var value = base ^ (counter &* 0x9E37_79B9)
        value ^= value >> 16
        value &*= 0x7FEB_352D
        value ^= value >> 15
        value &*= 0x846C_A68B
        value ^= value >> 16
        return value
    }
}
