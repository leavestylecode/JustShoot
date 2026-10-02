#include <metal_stdlib>
#include "FilmGrainMath.h"
#include "FilmOpticsMath.h"
using namespace metal;

// Parameters passed from CPU for preview rendering
struct PreviewParams {
    float scale;      // aspect-fill scale factor
    float offsetX;    // horizontal offset after scaling
    float offsetY;    // vertical offset after scaling
    uint inputWidth;  // original camera buffer width
    uint inputHeight; // original camera buffer height
    uint rotation;    // 0=none, 1=90CW, 2=180, 3=270CW
    uint lutDimension; // LUT grid size (e.g. 25)
    float grainAmount;
    float grainSize;   // actual grain diameter in output pixels
    float grainChroma;
    uint grainSeed;
    // 光学模块（halation/bloom/headroom）。半径已由 CPU 按预览输出长边换算为像素。
    float halationAmount;
    float halationRadiusPx;
    float halationHue;
    float bloomAmount;
    float bloomRadiusPx;
    float highlightThreshold;
    float headroomAmount;
    float headroomShoulder;
};


// Stage 1: geometry + LUT + headroom. Energy is extracted AFTER grading in every renderer.
kernel void previewLUT(
    texture2d<half, access::sample> input [[texture(0)]],
    texture3d<float, access::sample> lut [[texture(1)]],
    texture2d<half, access::write> graded [[texture(2)]],
    texture2d<half, access::write> energy [[texture(3)]],
    constant PreviewParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= graded.get_width() || gid.y >= graded.get_height()) return;
    float rx = (float(gid.x) - params.offsetX) / params.scale;
    float ry = (float(gid.y) - params.offsetY) / params.scale;
    float inW = float(params.inputWidth), inH = float(params.inputHeight);
    float2 source;
    switch (params.rotation) {
        case 1: source = float2(ry, inH - 1.0 - rx); break;
        case 2: source = float2(inW - 1.0 - rx, inH - 1.0 - ry); break;
        case 3: source = float2(inW - 1.0 - ry, rx); break;
        default: source = float2(rx, ry); break;
    }
    if (source.x < 0 || source.y < 0 || source.x >= inW || source.y >= inH) {
        graded.write(half4(0, 0, 0, 1), gid);
        energy.write(half4(0), gid);
        return;
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float3 color = float3(input.sample(linearSampler, (source + 0.5) / float2(inW, inH)).rgb);
    float dim = float(params.lutDimension);
    float3 coordinate = color * ((dim - 1.0) / dim) + 0.5 / dim;
    float3 display = justShootApplyHeadroom(lut.sample(linearSampler, coordinate).rgb,
                                           params.headroomAmount, params.headroomShoulder);
    float luminance = dot(display, float3(0.2126, 0.7152, 0.0722));
    float weight = justShootOpticsHighlightWeight(luminance, params.highlightThreshold);
    graded.write(half4(half3(display), 1), gid);
    energy.write(half4(half(weight)), gid);
}

// Stage 2 follows the same Gaussian energy diffusion/composite/grain order as Core Image.
kernel void previewFinish(
    texture2d<half, access::read> graded [[texture(0)]],
    texture2d<half, access::sample> halation [[texture(1)]],
    texture2d<half, access::sample> bloom [[texture(2)]],
    texture2d<half, access::write> output [[texture(3)]],
    constant PreviewParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler energySampler(filter::linear, address::clamp_to_edge);
    float2 coordinate = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 display = justShootCompositeOptics(float3(graded.read(gid).rgb),
        float(halation.sample(energySampler, coordinate).r), float(bloom.sample(energySampler, coordinate).r),
        params.halationAmount, params.halationHue, params.bloomAmount);
    float3 textured = justShootApplyFilmGrain(display, float2(gid) + 0.5,
        params.grainAmount, params.grainSize, params.grainChroma, params.grainSeed);
    output.write(half4(half3(textured), 1), gid);
}
