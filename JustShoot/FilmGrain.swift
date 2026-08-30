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

/// 所有“胶片自身”的技术参数统一从这里输出。后续 Bloom、Halation、微反差等会继续加入，
/// CameraView 只消费结果，不暴露一排用户开关。
struct FilmRenderProfile: Sendable, Equatable {
    let grain: FilmGrainParameters
}

private enum AutomaticFilmProfile {
    /// 以 ISO 50 为基线、按曝光档数平滑增长，再由乳剂结构修正。避免为每种胶片散落魔法数。
    static func grain(iso: Float, character: FilmGrainCharacter) -> FilmGrainParameters {
        let clampedISO = min(max(iso, 50), 3200)
        let normalizedStops = log2(clampedISO / 50) / 6
        let baseAmount = 0.034 + normalizedStops * 0.032
        let baseSize = 0.95 + normalizedStops * 0.70
        return FilmGrainParameters(
            amount: baseAmount * character.amountScale,
            size: baseSize * character.sizeScale,
            chroma: character.chroma
        )
    }
}

struct FilmGrainParameters: Sendable, Equatable {
    let amount: Float
    let size: Float
    let chroma: Float

    static let disabled = FilmGrainParameters(amount: 0, size: 1, chroma: 0)

    var isEnabled: Bool { amount > 0.0001 }

    /// 颗粒代表胶片画幅上的结构，而不是固定像素噪声。预览最小为 1px，完整照片随长边放大。
    func pixelSize(forLongEdge longEdge: CGFloat) -> Float {
        max(1, size * Float(longEdge) / 4000)
    }
}

extension FilmPreset {
    private var grainCharacter: FilmGrainCharacter {
        switch self {
        case .fujiProvia100F, .kodakVision5203:
            return .ultraFine
        case .fujiPro400H, .kodakPortra400, .kodakVision5219, .kodak5207:
            return .fine
        case .fujiC200:
            return .balanced
        case .harmanPhoenix200:
            return .expressive
        }
    }

    var renderProfile: FilmRenderProfile {
        FilmRenderProfile(
            grain: AutomaticFilmProfile.grain(iso: iso, character: grainCharacter)
        )
    }
}

extension FilmSource {
    var renderProfile: FilmRenderProfile {
        switch self {
        case .preset(let preset):
            return preset.renderProfile
        case .custom(_, _, let iso, _):
            return FilmRenderProfile(
                grain: AutomaticFilmProfile.grain(iso: iso, character: .balanced)
            )
        }
    }
}

// MARK: - Core Image 胶片颗粒

/// 静态图与 Live Photo 共用的确定性 Core Image kernel。
///
/// 噪声不是简单覆盖：以共享亮度颗粒为主、混入少量独立 RGB 结构，并用当前像素到黑/白端点
/// 的余量调制正负扰动，避免在纯黑/纯白处硬剪切。影调权重让中间调最明显、两端更克制。
enum FilmGrainRenderer {
    private static let kernel: CIColorKernel? = {
        do {
            guard let url = Bundle.main.url(
                forResource: "default",
                withExtension: "metallib"
            ) else {
                Log.lut.error("film_grain_kernel_missing")
                return nil
            }
            let libraryData = try Data(contentsOf: url)
            return try CIColorKernel(
                functionName: "justShootFilmGrain",
                fromMetalLibraryData: libraryData
            )
        } catch {
            Log.lut.error("film_grain_kernel_load_failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

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
            arguments: [image, parameters.amount, pixelSize, parameters.chroma, floatSeed]
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
