#include <CoreImage/CoreImage.h>
using namespace metal;

float rawTableValue(coreimage::sampler table, float index) {
    // CI bitmap rows run top to bottom; sampler.transform uses bottom-left world coordinates.
    float2 p = float2(fmod(index, 256.0), 255.0 - floor(index / 256.0)) + 0.5;
    return table.sample(table.transform(p)).r;
}

// CLF half-domain interpolation, including negative scene values and HDR values.
// The integer coordinates are IEEE-754 half bit patterns, not a unit-domain ramp.
float rawHalfLookup(coreimage::sampler table, float value) {
    value = isfinite(value) ? clamp(value, -65504.0, 65504.0) : 0.0;
    float magnitude = abs(value);
    float position;
    if (magnitude < 0.00006103515625) {
        position = magnitude * 16777216.0;
    } else {
        float exponent = floor(log2(magnitude));
        position = (exponent + 15.0) * 1024.0 + (magnitude * exp2(-exponent) - 1.0) * 1024.0;
    }
    position = clamp(position, 0.0, 31743.0);
    float lower = floor(position);
    float sign = value < 0.0 ? 32768.0 : 0.0;
    return mix(rawTableValue(table, sign + lower), rawTableValue(table, sign + min(lower + 1.0, 31743.0)), position - lower);
}

float3 rawCubeNode(coreimage::sampler cube, float3 index) {
    float2 p = float2(index.x, 4224.0 - (index.y + index.z * 65.0)) + 0.5;
    return cube.sample(cube.transform(p)).rgb;
}

// Some devices cannot linearly filter a full-precision curve texture.
float rawCurveValue(coreimage::sampler curves, float value, uint channel) {
    float position = clamp(value, 0.0, 1.0) * 255.0;
    float lower = floor(position);
    float2 start = float2(lower + 0.5, 0.5);
    float2 end = float2(min(lower + 1.0, 255.0) + 0.5, 0.5);
    return mix(curves.sample(curves.transform(start))[channel],
               curves.sample(curves.transform(end))[channel], position - lower);
}

[[stitchable]] float4 justShootRawFilm(coreimage::sampler image, coreimage::sampler inputTable,
    coreimage::sampler cube, coreimage::sampler outputTable, coreimage::sampler curves) {
    float4 pixel = image.sample(image.coord());
    float3 input = pixel.a > 0.0 ? pixel.rgb / pixel.a : float3(0.0);
    float3 shaped = float3(rawHalfLookup(inputTable, input.r), rawHalfLookup(inputTable, input.g), rawHalfLookup(inputTable, input.b));
    float3 pos = clamp(shaped, 0.0, 1.0) * 64.0;
    float3 lo = floor(pos), hi = min(lo + 1.0, 64.0), f = pos - lo;
    float3 a = mix(rawCubeNode(cube, lo), rawCubeNode(cube, float3(hi.x, lo.y, lo.z)), f.x);
    float3 b = mix(rawCubeNode(cube, float3(lo.x, hi.y, lo.z)), rawCubeNode(cube, float3(hi.x, hi.y, lo.z)), f.x);
    float3 c = mix(rawCubeNode(cube, float3(lo.x, lo.y, hi.z)), rawCubeNode(cube, float3(hi.x, lo.y, hi.z)), f.x);
    float3 d = mix(rawCubeNode(cube, float3(lo.x, hi.y, hi.z)), rawCubeNode(cube, hi), f.x);
    float3 look = mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
    float3 srgb = float3(rawHalfLookup(outputTable, look.r), rawHalfLookup(outputTable, look.g), rawHalfLookup(outputTable, look.b));
    float3 result = float3(rawCurveValue(curves, srgb.r, 0),
                           rawCurveValue(curves, srgb.g, 1),
                           rawCurveValue(curves, srgb.b, 2));
    return float4(result * pixel.a, pixel.a);
}
