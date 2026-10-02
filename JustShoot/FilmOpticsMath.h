#ifndef FilmOpticsMath_h
#define FilmOpticsMath_h

// 胶片光学模块（halation / bloom / headroom）的共享数学，被两处包含：
//   - LUTShader.metal（实时预览，显示域单 pass）
//   - FilmOpticsKernel.ci.metal（静态图 / Live Photo，CI sRGB 工作空间）
// 与 FilmGrainMath.h 同一约定：所有函数工作在 sRGB 显示值 [0,1]。
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

/// headroom：肩部去饱和。真实负片高光密度增长时染料通道趋同——亮部向保留亮度的暖白褪色，
/// 而不是数码的硬白剪切。amount 控制深度，shoulder 是起落点（显示域 luma）。
inline float3 justShootApplyHeadroom(float3 color, float amount, float shoulder)
{
    if (amount <= 0.0001) return color;

    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    float weight = smoothstep(shoulder, 1.0, luminance) * amount;
    // 目标是"同亮度的暖白"：l=1 时收敛到 (1, 0.992, 0.972)，保留一丝暖调而非中性灰。
    float3 warmWhite = luminance * float3(1.000, 0.992, 0.972);
    return mix(color, warmWhite, weight);
}

/// 光晕合成（显示域）：halation 按能量染橙红、bloom 近中性微暖，加色混合。
/// 增益常数在这里单点定义——Metal 预览与 CI 成片必须共用同一组数值。
inline float3 justShootCompositeOptics(
    float3 baseDisplay,
    float halationEnergy,
    float bloomEnergy,
    float halationAmount,
    float halationHue,
    float bloomAmount
) {
    if (halationAmount <= 0.0001 && bloomAmount <= 0.0001) return baseDisplay;

    float3 halationAdd = justShootOpticsHalationTint(halationHue)
        * max(halationEnergy, 0.0) * halationAmount * 0.55;
    float3 bloomAdd = float3(1.000, 0.985, 0.955)
        * max(bloomEnergy, 0.0) * bloomAmount * 0.42;
    return clamp(baseDisplay + halationAdd + bloomAdd, 0.0, 1.0);
}

#endif
