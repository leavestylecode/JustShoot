#include <CoreImage/CoreImage.h>
#include "FilmOpticsMath.h"

using namespace metal;

// The CIContext working space is explicitly sRGB, matching the Metal preview.

/// 肩部保护（去饱和 + 软压余量）：LUT 之后逐像素应用。
[[stitchable]] float4 justShootHeadroom(
    coreimage::sample_t pixel,
    float amount,
    float shoulder
) {
    float3 encoded = pixel.rgb;
    float3 softened = justShootApplyHeadroom(encoded, amount, shoulder);
    return float4(softened, pixel.a);
}

/// 高光能量图：显示域 luma 的软阈值权重，输出灰度标量场供高斯扩散。
/// 下游（blur/composite）直接在这个标量场上运算，不再做域转换。
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
