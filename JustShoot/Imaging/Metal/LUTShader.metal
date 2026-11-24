#include <metal_stdlib>
#include "FilmGrainMath.h"
#include "FilmOpticsMath.h"
#include "FilmMaterialMath.h"
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
    // 胶片色温响应（未校白）：线性域每通道增益，CPU 按场景色温 + 胶片原生平衡算好并已平滑。
    float chromaticGainR;
    float chromaticGainG;
    float chromaticGainB;
    float chromaticHighlightProtection;
    float grainResponse;
    float materialDensityDimension;
    float materialPrintDimension;
    float materialFinishDimension;
    float materialMaximumR;
    float materialMaximumG;
    float materialMaximumB;
    float materialMinimumR;
    float materialMinimumG;
    float materialMinimumB;
    float materialRefineX;
    float materialRefineY;
    float materialRefineZ;
    float materialRefineW;
    float materialNeutralRetention;
    float materialSkinHueRetention;
    float materialSkinChromaRetention;
    float materialSkinResponse;
    float materialExposureResponse;
    float materialShadowLift;
    float materialToneCeiling;
    float materialGrainScale;
    uint materialIdentityFlags; // bit 0: input, bit 1: finish
    float lutIntensity;
    float grainBroadOffset;
    float grainFineOffset;
    float grainFineWeight;
};

float2 previewSourcePosition(uint2 pixel, constant PreviewParams &params) {
    float2 position = (float2(pixel) - float2(params.offsetX, params.offsetY)) / params.scale;
    float inW = float(params.inputWidth), inH = float(params.inputHeight);
    switch (params.rotation) {
        case 1: return float2(position.y, inH - 1.0 - position.x);
        case 2: return float2(inW - 1.0 - position.x, inH - 1.0 - position.y);
        case 3: return float2(inW - 1.0 - position.y, position.x);
        default: return position;
    }
}

float3 applyingPreviewLUTIntensity(float3 looked, texture2d<float, access::sample> input,
    uint2 pixel, constant PreviewParams &params) {
    if (params.lutIntensity >= 1.0) return looked;
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 size = float2(params.inputWidth, params.inputHeight);
    float2 source = previewSourcePosition(pixel, params);
    float3 original = any(source < 0.0) || any(source >= size)
        ? float3(0.0) : input.sample(linearSampler, (source + 0.5) / size).rgb;
    return mix(original, looked, params.lutIntensity);
}

// Stage 1: geometry + material input mapping, or legacy RGB grading/headroom.
// Extract highlight energy from that branch's output before spatial diffusion.
kernel void previewLUT(
    texture2d<float, access::sample> input [[texture(0)]],
    texture3d<float, access::sample> lut [[texture(1)]],
    texture2d<half, access::write> graded [[texture(2)]],
    texture2d<half, access::write> energy [[texture(3)]],
    constant PreviewParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= graded.get_width() || gid.y >= graded.get_height()) return;
    float2 source = previewSourcePosition(gid, params);
    float2 size = float2(params.inputWidth, params.inputHeight);
    if (any(source < 0.0) || any(source >= size)) {
        graded.write(half4(0, 0, 0, 1), gid);
        energy.write(half4(0), gid);
        return;
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    // Decode the 8-bit camera texture directly to float. Rounding it to half before
    // a steep shadow/toe LUT magnifies quantization, especially on night images.
    float3 color = input.sample(linearSampler, (source + 0.5) / size).rgb;
    // 胶片色温响应先于 LUT：真实胶片是"乳剂先响应、显影定色"，校白模拟必须在色彩映射之前。
    color = justShootApplyChromaticGain(
        color,
        float3(params.chromaticGainR, params.chromaticGainG, params.chromaticGainB),
        params.chromaticHighlightProtection
    );
    float dim = float(params.lutDimension);
    float3 coordinate = color * ((dim - 1.0) / dim) + 0.5 / dim;
    float3 looked = (params.materialIdentityFlags & 1u) != 0
        ? clamp(color, 0.0, 1.0) : lut.sample(linearSampler, coordinate).rgb;
    float3 display = params.materialDensityDimension > 0 ? looked
        : justShootApplyHeadroom(looked, params.headroomAmount, params.headroomShoulder);
    float luminance = dot(display, float3(0.2126, 0.7152, 0.0722));
    float weight = justShootOpticsHighlightWeight(luminance, params.highlightThreshold);
    graded.write(half4(half3(display), 1), gid);
    energy.write(half4(half(weight)), gid);
}

kernel void previewMaterialFinish(
    texture2d<half, access::read> exposed [[texture(0)]],
    texture2d<half, access::sample> halo [[texture(1)]],
    texture2d<half, access::sample> bloom [[texture(2)]],
    texture2d<half, access::write> output [[texture(3)]],
    texture3d<float, access::sample> density [[texture(4)]],
    texture3d<float, access::sample> paper [[texture(5)]],
    texture3d<float, access::sample> finish [[texture(6)]],
    texture2d<float, access::sample> input [[texture(7)]],
    constant PreviewParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 source = justShootMaterialExposure(float3(exposed.read(gid).rgb),
        float(halo.sample(s, uv).r), float(bloom.sample(s, uv).r), p.halationAmount, p.halationHue, p.bloomAmount,
        p.materialExposureResponse);
    float dim = p.materialDensityDimension;
    float3 d = density.sample(s, clamp(source, 0.0, 1.0) * ((dim - 1.0) / dim) + 0.5 / dim).rgb;
    d = justShootMaterialGrain(d, float3(p.materialMinimumR, p.materialMinimumG, p.materialMinimumB),
        float3(p.materialMaximumR, p.materialMaximumG, p.materialMaximumB),
        float2(gid) + 0.5, p.grainAmount * p.materialGrainScale, p.grainSize, p.grainChroma, p.grainSeed & 0x00FFFFFFu);
    dim = p.materialPrintDimension;
    float3 color = paper.sample(s, d * ((dim - 1.0) / dim) + 0.5 / dim).rgb;
    color = justShootMaterialRefine(clamp(source, 0.0, 1.0), color,
        float4(p.materialRefineX, p.materialRefineY, p.materialRefineZ, p.materialRefineW));
    color = justShootMaterialColorBalance(clamp(source, 0.0, 1.0), color,
        float4(p.materialNeutralRetention, p.materialSkinHueRetention, p.materialSkinChromaRetention,
            p.materialSkinResponse));
    color = justShootMaterialTone(clamp(source, 0.0, 1.0), color, p.materialShadowLift, p.materialToneCeiling);
    dim = p.materialFinishDimension;
    color = (p.materialIdentityFlags & 2u) != 0 ? clamp(color, 0.0, 1.0)
        : finish.sample(s, color * ((dim - 1.0) / dim) + 0.5 / dim).rgb;
    color = justShootApplyHeadroom(color, p.headroomAmount, p.headroomShoulder);
    output.write(half4(half3(applyingPreviewLUTIntensity(color, input, gid, p)), 1), gid);
}

// Stage 2 follows the same Gaussian energy diffusion/composite/grain order as Core Image.
kernel void previewFinish(
    texture2d<half, access::read> graded [[texture(0)]],
    texture2d<half, access::sample> halation [[texture(1)]],
    texture2d<half, access::sample> bloom [[texture(2)]],
    texture2d<half, access::write> output [[texture(3)]],
    texture2d<float, access::sample> input [[texture(7)]],
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
        params.grainAmount, params.grainSize, params.grainChroma, params.grainSeed, params.grainResponse,
        float3(params.grainBroadOffset, params.grainFineOffset, params.grainFineWeight));
    output.write(half4(half3(applyingPreviewLUTIntensity(textured, input, gid, params)), 1), gid);
}
