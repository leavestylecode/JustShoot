#include <CoreImage/CoreImage.h>
#include "FilmOpticsMath.h"

using namespace metal;

// The CIContext working space is explicitly sRGB, matching the Metal preview.

/// 肩部保护（去饱和 + 软压余量）：LUT 之后逐像素应用。影调风格模块，保持显示域。
[[stitchable]] float4 justShootHeadroom(
    coreimage::sample_t pixel,
    float amount,
    float shoulder
) {
    float3 encoded = pixel.rgb;
    float3 softened = justShootApplyHeadroom(encoded, amount, shoulder);
    return float4(softened, pixel.a);
}

/// 高光能量图：输入显示域像素，输出**线性域**能量标量场供高斯扩散。
/// 能量图自产自销——CI 的模糊与合成 kernel 都消费这个场，域语义由本函数与
/// justShootCompositeOptics 共同约定，CIContext 配置无需感知。
[[stitchable]] float4 justShootHighlightEnergy(
    coreimage::sample_t pixel,
    float threshold
) {
    float3 encoded = pixel.rgb;
    float luminance = dot(encoded, float3(0.2126, 0.7152, 0.0722));
    float energy = justShootOpticsHighlightWeight(luminance, threshold);
    return float4(float3(energy), 1.0);
}

/// 光晕合成：底图 + 两个扩散后的能量图加色混合。未启用的能量图槽位由调用方传底图占位，
/// 对应 amount 为 0 时数学上不产生贡献。
[[stitchable]] float4 justShootHaloComposite(
    coreimage::sample_t base,
    coreimage::sample_t halation,
    coreimage::sample_t bloom,
    float halationAmount,
    float halationHue,
    float bloomAmount
) {
    float3 encodedBase = base.rgb;
    float3 composed = justShootCompositeOptics(
        encodedBase,
        halation.r,
        bloom.r,
        halationAmount,
        halationHue,
        bloomAmount
    );
    return float4(composed, base.a);
}

/// 胶片色温响应（未校白）：LUT 之前的线性域每通道增益。静态图与 Live Photo 共用；
/// Metal 预览在 LUTShader.metal 的 previewLUT 内联同一段数学（FilmOpticsMath.h 共享）。
[[stitchable]] float4 justShootChromaticGain(
    coreimage::sample_t pixel,
    float3 gain
) {
    return float4(justShootApplyChromaticGain(pixel.rgb, gain), pixel.a);
}
