#ifndef FilmOpticsMath_h
#define FilmOpticsMath_h

// 胶片光学模块（halation / bloom / headroom）的共享数学，被两处包含：
//   - LUTShader.metal（实时预览，显示域单 pass）
//   - FilmOpticsKernel.ci.metal（静态图 / Live Photo，CI sRGB 工作空间）
// 与 FilmGrainMath.h 同一约定：所有函数工作在 sRGB 显示值 [0,1]。
//
// 高光保护的总原则：合成前先把亮度软压出余量，合成后用单调软肩把浮点和映射回 [0,1)。
// 任何两个不同亮度在输出端仍是两个可区分的值——1.05 与 1.20 不再被截成同一个 1.0，
// 事后降曝光 / 提编码质量都救不回的层次在源头就保住。
#include <metal_stdlib>
using namespace metal;

/// 高光能量提取：threshold 之上 0.18 的软肩内平滑爬升，只让"光源"而非"亮面"发光晕。
inline float justShootOpticsHighlightWeight(float luma, float threshold)
{
    return smoothstep(threshold, min(threshold + 0.18, 1.0), luma);
}

/// halation 色相：0 = 纯红（片基反射只再曝红层），1 = 橙（绿层也被打到）。
/// 负片物理上随光源能量从边缘橙过渡到远处红，参数取中间值即得自然混合。
inline float3 justShootOpticsHalationTint(float hue)
{
    const float3 red = float3(1.00, 0.26, 0.10);
    const float3 orange = float3(1.00, 0.60, 0.22);
    return mix(red, orange, hue);
}

/// 指数软肩压缩：start 以下恒等，以上向 ceiling 渐近。C1 连续、严格单调、无硬剪切。
/// 两处使用：headroom 把高光亮度压向 ceiling < 1 腾出光晕余量；合成末端把可能超过 1 的
/// 浮点和压回 [0, 1)，超限亮度彼此仍可区分。
inline float justShootShoulderCompress(float x, float start, float ceiling)
{
    if (x <= start) return max(x, 0.0);
    float range = max(ceiling - start, 1e-4);
    return start + range * (1.0 - exp(-(x - start) / range));
}

inline float3 justShootShoulderCompress3(float3 x, float start, float ceiling)
{
    return float3(
        justShootShoulderCompress(x.r, start, ceiling),
        justShootShoulderCompress(x.g, start, ceiling),
        justShootShoulderCompress(x.b, start, ceiling)
    );
}

/// headroom 压缩的渐近亮度：低于 1.0，halation/bloom 的加色混合才有真实余量可进。
constant float justShootOpticsHeadroomCeiling = 0.90;
/// 合成末端软肩的起点：该亮度以下完全不触碰，以上平滑收进 1 以内。
constant float justShootOpticsCompositeKnee = 0.85;

/// headroom：肩部保护，两件事用同一 weight 渐入：
///   1) 去饱和——真实负片高光密度增长时染料通道趋同，亮部向保留亮度的暖白褪色；
///   2) 亮度软压——肩部以上向 headroomCeiling 渐近压缩。没有这一步，去饱和只是"变色"，
///      后续光晕加亮仍会把高光顶过 1 再截断；有了它，光晕能量有地方可去。
/// amount 控制深度，shoulder 是起落点（显示域 luma）。
inline float3 justShootApplyHeadroom(float3 color, float amount, float shoulder)
{
    if (amount <= 0.0001) return color;

    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    float weight = smoothstep(shoulder, 1.0, luminance) * amount;
    // 去饱和目标是"同亮度的暖白"：l=1 时收敛到 (1, 0.992, 0.972)，保留一丝暖调而非中性灰。
    float3 warmWhite = luminance * float3(1.000, 0.992, 0.972);
    float3 desaturated = mix(color, warmWhite, weight);

    float compressed = justShootShoulderCompress(luminance, shoulder, justShootOpticsHeadroomCeiling);
    float3 withHeadroom = desaturated * (compressed / max(luminance, 1e-4));
    return mix(desaturated, withHeadroom, weight);
}

/// 光晕合成（显示域）：halation 按能量染橙红、bloom 近中性微暖，加色混合。
/// 增益常数在这里单点定义——Metal 预览与 CI 成片必须共用同一组数值。
///
/// 能量走饱和响应 1-exp(-E)：小能量近似线性，点光源的发光观感与旧版一致；
/// 大面积亮面（扩散后局部能量趋于 1 以上）贡献次线性衰减，整片亮墙不再被继续推白。
///
/// 合成结果不做硬截断：先保留浮点，再用软肩把超过 knee 的部分单调压回 [0, 1)。
inline float3 justShootCompositeOptics(
    float3 baseDisplay,
    float halationEnergy,
    float bloomEnergy,
    float halationAmount,
    float halationHue,
    float bloomAmount
) {
    if (halationAmount <= 0.0001 && bloomAmount <= 0.0001) return baseDisplay;

    float halationResponse = 1.0 - exp(-max(halationEnergy, 0.0));
    float bloomResponse = 1.0 - exp(-max(bloomEnergy, 0.0));
    float3 halationAdd = justShootOpticsHalationTint(halationHue)
        * halationResponse * halationAmount * 0.55;
    float3 bloomAdd = float3(1.000, 0.985, 0.955)
        * bloomResponse * bloomAmount * 0.42;

    float3 composed = max(baseDisplay + halationAdd + bloomAdd, 0.0);
    return justShootShoulderCompress3(composed, justShootOpticsCompositeKnee, 1.0);
}

#endif
