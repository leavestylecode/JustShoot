#ifndef JustShootFilmColorBalanceMath
#define JustShootFilmColorBalanceMath
using namespace metal;

// Encoded-sRGB color preference, not spectral calibration. Input-color gates
// may include warm objects; this is not semantic skin detection or automatic WB.
inline float3 justShootMaterialColorBalance(float3 input, float3 graded, float4 p) {
    if (all(p.xyz == float3(0.0))) return graded;
    const float3 weights = float3(0.2126, 0.7152, 0.0722);
    float y = dot(input, weights), outY = dot(graded, weights);
    float2 uv = float2((input.b - y) / 1.8556, (input.r - y) / 1.5748);
    float2 outUV = float2((graded.b - outY) / 1.8556, (graded.r - outY) / 1.5748);
    float sourceChroma = length(uv), outputChroma = length(outUV);
    // Keep endpoint colors and bright warm light; remove most introduced cast
    // only from low-chroma shadows/midtones, retaining actual input cool/warm hues.
    float tone = smoothstep(0.012, 0.05, y) * (1.0 - smoothstep(0.55, 0.85, y));
    float neutral = (1.0 - smoothstep(0.008, 0.065, sourceChroma)) * tone;
    float ratio = -uv.x / max(uv.y, 0.000001);
    // v2 includes muted red/pink skin hues missed by v1, including deep skin.
    // The response is frozen per recipe; both versions keep the warm-light taper.
    float skin = smoothstep(mix(0.35, 0.08, p.w), mix(0.55, 0.35, p.w), ratio)
        * (1.0 - smoothstep(1.10, 1.40, ratio))
        * smoothstep(0.005, 0.025, uv.y) * (1.0 - smoothstep(-0.015, 0.005, uv.x))
        * smoothstep(0.015, 0.045, sourceChroma) * (1.0 - smoothstep(0.20, 0.28, sourceChroma))
        * smoothstep(0.025, 0.07, y) * (1.0 - smoothstep(0.65, 0.90, y));
    if (neutral <= 0.0 && skin <= 0.0) return graded;

    float2 pulled = mix(outUV, uv / max(sourceChroma, 0.000001) * outputChroma, skin * p.y);
    pulled *= outputChroma / max(length(pulled), 0.000001);
    float targetChroma = outputChroma - max(0.0, outputChroma - sourceChroma * 1.05) * skin * p.z;
    pulled *= targetChroma / max(outputChroma, 0.000001);
    pulled = mix(pulled, uv, neutral * p.x);
    // Retaining a source shadow hue must not boost saturation in dark skin.
    pulled *= min(1.0, outputChroma / max(length(pulled), 0.000001));
    float red = outY + 1.5748 * pulled.y, blue = outY + 1.8556 * pulled.x;
    float3 offset = float3(red, (outY - weights.r * red - weights.b * blue) / weights.g, blue) - outY;
    // Compress chroma toward the same output luma instead of clipping channels,
    // so the adjustment cannot lift black, flatten contrast or darken faces.
    float3 limits = select(float3(outY) / max(-offset, float3(0.000001)),
        float3(1.0 - outY) / max(offset, float3(0.000001)), offset > 0.0);
    float scale = min(1.0, min(limits.r, min(limits.g, limits.b)));
    return clamp(outY + offset * scale, 0.0, 1.0);
}
#endif
