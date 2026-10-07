import Foundation
import CoreImage

// MARK: - 胶片光学参数（halation / bloom / headroom）
//
// 建模自胶片光化学过程，参数与颗粒一样按胶片性格固定，不暴露用户开关：
//   - halation：强光穿透乳剂层、经片基反射后**选择性再曝光红层**——高光周围的橙红光晕
//     （CineStill 800T / Harman Phoenix 的招牌特征）。hue 控制红→橙的能量色偏。
//   - bloom：光源的宽域辉光（镜头内散射 + 乳剂前向散射），近中性微暖。
//   - headroom：肩部保护——高光先去饱和向暖白褪色（Portra / Pro 400H 的奶油高光），
//     再把亮度软压到 0.90 以内腾出余量，让光晕加亮后仍走单调软肩收尾，高光层次不被
//     硬截断成同一片白（详见 FilmOpticsMath.h 的高光保护总原则）。
//
// 三条渲染路径（Metal 预览 / 静态图 / Live Photo 视频）共享同一参数集与 4000px 基准的
// 半径归一，保证预览所见与成片一致（半径 = 各自图像长边的同一比例 → FOV 一致）。
struct FilmOpticsParameters: Sendable, Equatable, Codable {
    /// halation 强度（0 关闭）。
    var halationAmount: Float
    /// halation 光晕半径，以 4000px 长边为基准的像素数。
    var halationRadius: Float
    /// 0 = 纯红，1 = 橙。
    var halationHue: Float

    /// bloom 强度（0 关闭）。
    var bloomAmount: Float
    /// bloom 半径，基准同 halationRadius。
    var bloomRadius: Float

    /// 肩部保护深度（去饱和 + 亮度软压，0 关闭）。
    var headroomAmount: Float
    /// 肩部起始的显示域 luma（去饱和与软压共用同一渐入区间）。
    var headroomShoulder: Float

    static let disabled = FilmOpticsParameters(
        halationAmount: 0, halationRadius: 0, halationHue: 0,
        bloomAmount: 0, bloomRadius: 0,
        headroomAmount: 0, headroomShoulder: 0
    )

    var hasLightDiffusion: Bool { halationAmount > 0.0001 || bloomAmount > 0.0001 }
    var isEnabled: Bool { hasLightDiffusion || headroomAmount > 0.0001 }

    /// 高光能量提取的共享阈值（halation 与 bloom 共用一张能量图）。
    static let highlightThreshold: Float = 0.72

    /// 半径归一：渲染管线各自以图像长边换算成该管线的像素半径，跨分辨率 FOV 一致
    /// （预览视频流、48MP 静态图、Live Photo 帧的光晕占比画面比例相同）。
    func radiusPixels(_ radius: Float, forLongEdge longEdge: CGFloat) -> Float {
        max(2, radius * Float(longEdge) / 4000)
    }
}

// MARK: - 每片默认参数

extension FilmPreset {
    /// 光学性格与颗粒同源：电影负片（去碳背防光晕层）halation 最强，现代彩色负片肩部柔和，
    /// 反转片保饱和。数值以保守可发布为基准，后续可按实拍校准微调。
    var filmOptics: FilmOpticsParameters {
        switch self {
        case .kodakVision5219: // 500T：电影卷 + T 灯光片，夜景点光源 halation 标志性
            return FilmOpticsParameters(
                halationAmount: 0.42, halationRadius: 36, halationHue: 0.35,
                bloomAmount: 0.30, bloomRadius: 70,
                headroomAmount: 0.55, headroomShoulder: 0.62
            )
        case .kodakVision5203: // 50D：日光电影卷，细颗粒高分辨率，halation 适中
            return FilmOpticsParameters(
                halationAmount: 0.24, halationRadius: 30, halationHue: 0.40,
                bloomAmount: 0.22, bloomRadius: 58,
                headroomAmount: 0.55, headroomShoulder: 0.62
            )
        case .kodak5207: // 250D
            return FilmOpticsParameters(
                halationAmount: 0.28, halationRadius: 32, halationHue: 0.40,
                bloomAmount: 0.24, bloomRadius: 60,
                headroomAmount: 0.55, headroomShoulder: 0.62
            )
        case .kodakPortra400: // 人像负片：柔和 bloom + 奶油肩部
            return FilmOpticsParameters(
                halationAmount: 0.20, halationRadius: 30, halationHue: 0.50,
                bloomAmount: 0.28, bloomRadius: 62,
                headroomAmount: 0.62, headroomShoulder: 0.60
            )
        case .fujiPro400H: // pastel 高光是本体：肩部最深
            return FilmOpticsParameters(
                halationAmount: 0.12, halationRadius: 26, halationHue: 0.50,
                bloomAmount: 0.26, bloomRadius: 60,
                headroomAmount: 0.68, headroomShoulder: 0.58
            )
        case .fujiC200: // 消费负片
            return FilmOpticsParameters(
                halationAmount: 0.16, halationRadius: 28, halationHue: 0.45,
                bloomAmount: 0.20, bloomRadius: 55,
                headroomAmount: 0.55, headroomShoulder: 0.62
            )
        case .fujiProvia100F: // 反转片：保饱和、肩部浅、光晕克制
            return FilmOpticsParameters(
                halationAmount: 0.10, halationRadius: 22, halationHue: 0.40,
                bloomAmount: 0.14, bloomRadius: 48,
                headroomAmount: 0.28, headroomShoulder: 0.70
            )
        case .harmanPhoenix200: // 无防光晕层的新派负片，halation 是卖点
            return FilmOpticsParameters(
                halationAmount: 0.45, halationRadius: 34, halationHue: 0.55,
                bloomAmount: 0.22, bloomRadius: 58,
                headroomAmount: 0.50, headroomShoulder: 0.64
            )
        }
    }
}

// MARK: - Core Image 光学渲染（静态图与 Live Photo 共用）

/// 与 FilmGrainRenderer 同一模式：从 default.metallib 加载 stitchable CIColorKernel，
/// 失败时静默跳过（绝不因光学模块缺失而丢片）。链路顺序与 Metal 预览一致：
/// LUT → headroom → halation/bloom → grain。
///
/// halation/bloom 的空间扩散用 CIGaussianBlur：能量图（CIColorKernel 逐像素提取）
/// → 高斯模糊 → 与底图做加色合成（自定义 composite kernel 染色），全 GPU、无自研
/// 采样坐标换算，48MP 一次渲染下成本远小于 HEIF 编码本身。
enum FilmOpticsRenderer {
    private static let metalLibraryData: Data? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            Log.lut.error("film_optics_kernel_missing")
            return nil
        }
        return try? Data(contentsOf: url)
    }()

    private static func kernel(_ name: String) -> CIColorKernel? {
        guard let data = metalLibraryData else { return nil }
        return try? CIColorKernel(functionName: name, fromMetalLibraryData: data)
    }

    private static let headroomKernel = kernel("justShootHeadroom")
    private static let highlightKernel = kernel("justShootHighlightEnergy")
    private static let compositeKernel = kernel("justShootHaloComposite")

    /// 肩部保护（去饱和 + 软压余量）：逐像素，可与 LUT 输出直接串接。
    static func applyingHeadroom(to image: CIImage, parameters: FilmOpticsParameters) -> CIImage {
        guard parameters.headroomAmount > 0.0001,
              !image.extent.isEmpty,
              !image.extent.isInfinite,
              let headroomKernel else {
            return image
        }
        return headroomKernel.apply(
            extent: image.extent,
            arguments: [image, parameters.headroomAmount, parameters.headroomShoulder]
        ) ?? image
    }

    /// halation + bloom：高光能量 → 双半径高斯扩散 → 饱和响应 + 加色染色合成。
    /// 合成内核保留浮点并用软肩收尾（见 FilmOpticsMath.h），此处无需再夹值。
    static func applyingLightDiffusion(to image: CIImage, parameters: FilmOpticsParameters) -> CIImage {
        guard parameters.hasLightDiffusion,
              !image.extent.isEmpty,
              !image.extent.isInfinite,
              let highlightKernel,
              let compositeKernel else {
            return image
        }

        let extent = image.extent
        let longEdge = max(extent.width, extent.height)

        // 能量图：显示域 luma 的高光软阈值，halation 与 bloom 共用。
        guard let energy = highlightKernel.apply(
            extent: extent,
            arguments: [image, FilmOpticsParameters.highlightThreshold]
        ) else { return image }

        // 双半径扩散。CIGaussianBlur 的 extent 会向四周扩张，裁回原 extent 保持 DOD 有限
        // （下游 FilmGrainRenderer 对 infinite extent 直接跳过）。
        func blurredEnergy(radius: Float) -> CIImage {
            energy
                .applyingGaussianBlur(sigma: CGFloat(radius))
                .cropped(to: extent)
        }
        let halationBlur = parameters.halationAmount > 0.0001
            ? blurredEnergy(radius: parameters.radiusPixels(parameters.halationRadius, forLongEdge: longEdge) * 0.55)
            : nil
        let bloomBlur = parameters.bloomAmount > 0.0001
            ? blurredEnergy(radius: parameters.radiusPixels(parameters.bloomRadius, forLongEdge: longEdge) * 0.45)
            : nil
        guard halationBlur != nil || bloomBlur != nil else { return image }

        return compositeKernel.apply(
            extent: extent,
            arguments: [
                image,
                halationBlur ?? image,
                bloomBlur ?? image,
                parameters.halationAmount,
                parameters.halationHue,
                parameters.bloomAmount
            ]
        ) ?? image
    }

    /// 完整光学链（headroom → 光扩散）。三条渲染路径统一入口。
    static func applying(to image: CIImage, parameters: FilmOpticsParameters) -> CIImage {
        guard parameters.isEnabled,
              !image.extent.isEmpty,
              !image.extent.isInfinite else {
            return image
        }
        var output = applyingHeadroom(to: image, parameters: parameters)
        output = applyingLightDiffusion(to: output, parameters: parameters)
        return output
    }
}
