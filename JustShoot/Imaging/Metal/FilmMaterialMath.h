#ifndef JustShootFilmMaterialMath
#define JustShootFilmMaterialMath
#include "FilmGrainMath.h"
#include "FilmOpticsMath.h"
#include "FilmColorBalanceMath.h"
using namespace metal;

// v1 input is developed sRGB. Linearize for energy addition, never claim recovered scene radiance.
inline float3 justShootMaterialExposure(float3 base, float halo, float bloom,
    float haloAmount, float haloHue, float bloomAmount, float response) {
    float3 tint = mix(float3(1, 0.26, 0.10), float3(1, 0.60, 0.22), clamp(haloHue, 0.0, 1.0));
    float3 energy = justShootSrgbToLinear(base);
    float3 scattered = tint * (1.0 - exp(-max(halo, 0.0))) * haloAmount * 0.5;
    scattered += float3(1, 0.985, 0.95) * (1.0 - exp(-max(bloom, 0.0))) * bloomAmount * 0.38;
    if (response > 0.5) {
        // The schema-2 model accepts developed SDR, not unbounded radiance.
        // Approach source white smoothly instead of clipping summed energy
        // at the next table, which merges distinct near-white source levels.
        energy = clamp(energy, 0.0, 1.0);
        energy += (1.0 - energy) * (1.0 - exp(-scattered));
    } else {
        // Keep schema-1's operation order for frozen rendering compatibility.
        energy += tint * (1.0 - exp(-max(halo, 0.0))) * haloAmount * 0.5;
        energy += float3(1, 0.985, 0.95) * (1.0 - exp(-max(bloom, 0.0))) * bloomAmount * 0.38;
    }
    return justShootLinearToSrgb(energy);
}

// Normalized layer activation is decoded to actual density units before stochastic variation.
inline float3 justShootMaterialGrain(float3 normalized, float3 minimum, float3 maximum, float2 position,
    float amount, float size, float chroma, uint seed) {
    if (amount <= 0.0001) return normalized;
    float4 pattern = justShootGrainPattern(position, size, seed, 1.0);
    float3 noise = mix(float3(pattern.x), pattern.yzw, chroma);
    if (all(minimum == float3(0.0))) {
        // Schema 1 retains its original arithmetic, including rounding order.
        float3 d = clamp(normalized, 0.0, 1.0);
        float3 visibility = sqrt(max(d * (1.0 - d), float3(0.0)));
        return clamp((d * maximum + noise * amount * 0.55 * visibility) / maximum, 0.0, 1.0);
    }
    float3 span = maximum - minimum;
    float3 code = clamp(normalized, 0.0, 1.0);
    float3 density = code * span + minimum;
    float3 activation = clamp(density / maximum, 0.0, 1.0);
    float3 visibility = sqrt(max(activation * (1.0 - activation), float3(0.0)));
    // Empirical texture amplitude in density units; not a measured Portra grain calibration.
    return clamp((density + noise * amount * 0.55 * visibility - minimum) / span, 0.0, 1.0);
}

// C1-continuous display-luma lift, identity above the ceiling and at black.
// dY'/dY >= 1-lift/3 > 0 for the validated range; no exposure or white clipping.
// Interpolation toward white reaches the target luma inside the RGB gamut and
// preserves the chroma direction. This is an aesthetic SDR calibration.
inline float3 justShootMaterialTone(float3 input, float3 color, float lift, float ceiling) {
    if (lift <= 0.0) return color;
    float y = dot(color, float3(0.2126, 0.7152, 0.0722));
    float x = clamp(y / ceiling, 0.0, 1.0);
    // Preserve the model's printed black/fog for black input. The increasing
    // source gate also retains the deepest toe instead of raising it to gray.
    float sourceY = dot(input, float3(0.2126, 0.7152, 0.0722));
    float toe = smoothstep(0.0, 0.12, sourceY);
    float delta = lift * toe * y * (1.0 - x) * (1.0 - x);
    return color + (1.0 - color) * (delta / max(1.0 - y, 0.000001));
}

// Same bounded display refinement as FilmLookRefinement.swift, after printing, before user curves.
inline float3 justShootMaterialRefine(float3 input, float3 graded, float4 p) {
    float y = dot(input, float3(0.2126, 0.7152, 0.0722));
    float outY = dot(graded, float3(0.2126, 0.7152, 0.0722));
    float2 uv = float2((input.b - y) / 1.8556, (input.r - y) / 1.5748);
    float2 outUV = float2((graded.b - outY) / 1.8556, (graded.r - outY) / 1.5748);
    float sourceChroma = length(uv), outputChroma = length(outUV);
    float ratio = -uv.x / max(uv.y, 0.000001);
    float gate = smoothstep(0.35, 0.55, ratio) * (1.0 - smoothstep(1.10, 1.40, ratio))
        * smoothstep(0.005, 0.025, uv.y) * (1.0 - smoothstep(-0.015, 0.005, uv.x));
    float skin = gate * smoothstep(0.015, 0.045, sourceChroma) * (1.0 - smoothstep(0.20, 0.28, sourceChroma))
        * smoothstep(0.025, 0.07, y) * (1.0 - smoothstep(0.80, 0.98, y));
    float shadow = max(0.0, y * p.x - outY) * (1.0 - smoothstep(0.15, 0.40, y));
    float2 pulled = outUV + skin * p.y * (uv / max(sourceChroma, 0.000001) * outputChroma - outUV);
    pulled *= outputChroma / max(length(pulled), 0.000001);
    float targetChroma = max(0.0, outputChroma - max(0.0, outputChroma - sourceChroma * 1.35) * skin * p.z);
    pulled *= targetChroma / max(outputChroma, 0.000001);
    float luminance = outY + max(shadow, max(0.0, y - outY) * skin * p.w);
    float red = luminance + 1.5748 * pulled.y;
    float blue = luminance + 1.8556 * pulled.x;
    return clamp(float3(red, (luminance - 0.2126 * red - 0.0722 * blue) / 0.7152, blue), 0.0, 1.0);
}
#endif
