#ifndef FilmOpticsMath_h
#define FilmOpticsMath_h

// 胶片光学模块（halation / bloom / headroom）的共享数学，被两处包含：
//   - LUTShader.metal（实时预览，单 pass）
//   - FilmOpticsKernel.ci.metal（静态图 / Live Photo，CI sRGB 工作空间）
//
// 域约定：光传输模块（高光能量提取、加色合成）工作在场景线性光域——halation/bloom
// 是光子能量的扩散，gamma 编码值上做高斯模糊会按错误的比例分配晕能量（中调晕被夸大、
// 暗部晕被压低）。风格化模块（LUT、headroom、颗粒）保持 sRGB 显示域，它们模拟的是
// 影调/密度响应，本来就是显示相关的。跨域边界在函数内部完成（sRGB↔linear EOTF），
// 调用方永远只见显示值。
//
// 高光保护的总原则：合成前先把亮度软压出余量，合成后用单调软肩把浮点和映射回 [0,1)。
// 任何两个不同亮度在输出端仍是两个可区分的值——1.05 与 1.20 不再被截成同一个 1.0，
// 事后降曝光 / 提编码质量都救不回的层次在源头就保住。
#include <metal_stdlib>
using namespace metal;

/// sRGB EOTF（IEC 61966-2-1 精确分段式，非 2.2 幂近似）。光学链跨域边界的唯一通道。
inline float justShootSrgbToLinearValue(float x)
{
    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}

/// sRGB 逆 EOTF（OETF）。合成结果回到显示域后仍可大于 1（如 base 1.0 + 光晕能量），
/// 函数不截断、保持单调，白电平收敛交给下游软肩。
inline float justShootLinearToSrgbValue(float x)
{
    return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(max(x, 0.0), 1.0 / 2.4) - 0.055;
}

inline float3 justShootSrgbToLinear(float3 c)
{
    return float3(
        justShootSrgbToLinearValue(c.r),
        justShootSrgbToLinearValue(c.g),
        justShootSrgbToLinearValue(c.b)
    );
}

inline float3 justShootLinearToSrgb(float3 c)
{
    return float3(
        justShootLinearToSrgbValue(c.r),
        justShootLinearToSrgbValue(c.g),
        justShootLinearToSrgbValue(c.b)
    );
}

/// C1 shoulder with a rational tail: even strongly saturated highlights retain
/// more precision than an exponential tail that rapidly rounds to its ceiling.
inline float justShootInputShoulder(float x, float start)
{
    if (x <= start) return x;
    float range = max(1.0 - start, 1e-6);
    float excess = x - start;
    return start + range * excess / (excess + range);
}

/// 胶片色温响应（未校白）：线性光域的每通道增益（von Kries 对角近似，Swift 侧
/// FilmChromaticResponseParameters.responseGain 用同一数学算出增益传入）。
/// 跨域边界在函数内部完成，调用方只见显示域像素。
inline float3 justShootApplyChromaticGain(float3 display, float3 gain, float protectHighlights)
{
    if (gain.r >= 0.9999 && gain.r <= 1.0001
        && gain.g >= 0.9999 && gain.g <= 1.0001
        && gain.b >= 0.9999 && gain.b <= 1.0001) return display;
    float3 linear = justShootSrgbToLinear(display) * gain;
    float maximumGain = max(gain.r, max(gain.g, gain.b));
    if (protectHighlights <= 0.5 || maximumGain <= 1.0) return justShootLinearToSrgb(linear);

    // Protect the LUT's SDR input BEFORE its edge sampler can clip a channel.
    // Map luminance and the largest channel through the SAME monotone shoulder.
    // Interpolate the remaining channels around the neutral axis. This preserves
    // hue direction and gives the boosted channel a real gradient in half-float
    // intermediates too; an asymptote extremely close to 1 would quantize flat.
    const float3 weights = float3(0.2126, 0.7152, 0.0722);
    float luminance = dot(linear, weights);
    float knee = 1.0 - min(maximumGain - 1.0, 0.5) * 0.4;
    float maximum = max(linear.r, max(linear.g, linear.b));
    float mapped = justShootInputShoulder(luminance, knee);
    float mappedMaximum = justShootInputShoulder(maximum, knee);
    float spread = maximum - luminance;
    float chromaScale = spread > 1e-6 ? (mappedMaximum - mapped) / spread : 1.0;
    float3 chroma = (linear - luminance) * chromaScale;
    return justShootLinearToSrgb(mapped + chroma);
}

/// 高光能量提取：threshold 之上 0.18 的软肩内平滑爬升，只让"光源"而非"亮面"发光晕。
/// luma 与 threshold 均以显示域定义（参数直觉域），内部 decode 到线性域做 smoothstep——
/// 扩散的是线性光能量：光源（显示 luma≈1）权重不变，亮面的权重比显示域版本更低，
/// 大面积白墙不再像旧版那样把晕推得过白。
inline float justShootOpticsHighlightWeight(float displayLuma, float threshold)
{
    float lo = justShootSrgbToLinearValue(threshold);
    float hi = justShootSrgbToLinearValue(min(threshold + 0.18, 1.0));
    return smoothstep(lo, hi, justShootSrgbToLinearValue(displayLuma));
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

/// 光晕增益常数在这里单点定义——Metal 预览与 CI 成片必须共用同一组数值。
/// 线性域合成的初值推导：中调（显示 0.5）处 sRGB 编码导数 ≈ 1.08，旧显示域增益
/// 0.55/0.42 换算 0.55/1.08 ≈ 0.51、0.42/1.08 ≈ 0.39；halation 主体是点光源
/// （提取权重≈1，只吃编码导数修正）取 0.50，bloom 主体是亮面（线性域提取权重还
/// 整体偏低）再往下补，取 0.38。待真机夜景对照图校准。
constant float justShootOpticsHalationGain = 0.50;
constant float justShootOpticsBloomGain = 0.38;

/// 光晕合成（线性光域）：底图与染色能量按光子比例叠加，再编码回显示域。
/// tint 常数是显示域调定的观感色，decode 后参与线性叠加——色相与旧显示域版本一致，
/// 变化的只是能量-亮度映射：亮面晕收敛、点光源晕的衰减梯度与物理一致。
///
/// 能量走饱和响应 1-exp(-E)：小能量近似线性，点光源的发光观感与旧版一致；
/// 大面积亮面（扩散后局部能量趋于 1 以上）贡献次线性衰减，整片亮墙不再被继续推白。
///
/// 合成结果先编码回显示域（不截断、保持单调），再由软肩把超过 knee 的部分压回 [0, 1)。
inline float3 justShootCompositeOptics(
    float3 baseDisplay,
    float halationEnergy,
    float bloomEnergy,
    float halationAmount,
    float halationHue,
    float bloomAmount
) {
    if (halationAmount <= 0.0001 && bloomAmount <= 0.0001) return baseDisplay;

    float3 baseLinear = justShootSrgbToLinear(baseDisplay);
    float halationResponse = 1.0 - exp(-max(halationEnergy, 0.0));
    float bloomResponse = 1.0 - exp(-max(bloomEnergy, 0.0));
    float3 halationAdd = justShootSrgbToLinear(justShootOpticsHalationTint(halationHue))
        * halationResponse * halationAmount * justShootOpticsHalationGain;
    float3 bloomAdd = justShootSrgbToLinear(float3(1.000, 0.985, 0.955))
        * bloomResponse * bloomAmount * justShootOpticsBloomGain;

    float3 composedLinear = max(baseLinear + halationAdd + bloomAdd, 0.0);
    return justShootShoulderCompress3(
        justShootLinearToSrgb(composedLinear),
        justShootOpticsCompositeKnee,
        1.0
    );
}

#endif
