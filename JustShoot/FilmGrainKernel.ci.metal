#include <CoreImage/CoreImage.h>
#include "FilmGrainMath.h"

using namespace metal;

[[stitchable]] float4 justShootFilmGrain(
    coreimage::sample_t pixel,
    float amount,
    float grainSize,
    float chroma,
    float seed,
    coreimage::destination destination
) {
    // CIColorKernel 接收线性工作空间像素。用 gamma≈2 的快速编解码把颗粒放到接近显示域：
    // 相比逐通道精确 sRGB pow，48MP 静态图与逐帧 Live Photo 的 GPU 成本低得多。
    float3 encoded = sqrt(max(pixel.rgb, 0.0));
    float3 textured = justShootApplyFilmGrain(
        encoded,
        destination.coord(),
        amount,
        grainSize,
        chroma,
        uint(seed)
    );
    return float4(textured * textured, pixel.a);
}
