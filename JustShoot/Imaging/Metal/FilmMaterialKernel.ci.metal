#include <CoreImage/CoreImage.h>
#include "FilmMaterialMath.h"
using namespace metal;

float4 cubeNode(coreimage::sampler table, float3 index, float dim, float2 size) {
    float offset = index.x + index.y * dim + index.z * dim * dim;
    float2 p = float2(fmod(offset, size.x), size.y - 1.0 - floor(offset / size.x)) + 0.5;
    return table.sample(table.transform(p));
}
float4 cubeLookup(coreimage::sampler table, float3 rgb, float dim, float2 size) {
    float3 pos = clamp(rgb, 0.0, 1.0) * (dim - 1.0);
    float3 lo = floor(pos), hi = min(lo + 1.0, dim - 1.0), f = pos - lo;
    float4 a = mix(cubeNode(table, lo, dim, size), cubeNode(table, float3(hi.x, lo.y, lo.z), dim, size), f.x);
    float4 b = mix(cubeNode(table, float3(lo.x, hi.y, lo.z), dim, size), cubeNode(table, float3(hi.x, hi.y, lo.z), dim, size), f.x);
    float4 c = mix(cubeNode(table, float3(lo.x, lo.y, hi.z), dim, size), cubeNode(table, float3(hi.x, lo.y, hi.z), dim, size), f.x);
    float4 d = mix(cubeNode(table, float3(lo.x, hi.y, hi.z), dim, size), cubeNode(table, hi, dim, size), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}
float3 materialLookup(coreimage::sampler table, float3 rgb, float dim) {
    // Identity tables still clamp HDR/RAW and energy added before development.
    return dim == 0.0 ? clamp(rgb, 0.0, 1.0) : cubeLookup(table, rgb, dim, float2(dim, dim * dim)).rgb;
}
[[stitchable]] float4 justShootColorCube(coreimage::sampler image, coreimage::sampler table, float3 shape) {
    float4 pixel = image.sample(image.coord());
    // LUT entries contain premultiplied RGBA, as required by CIColorCube.
    return cubeLookup(table, pixel.rgb / max(pixel.a, 0.000001), shape.x, shape.yz) * pixel.a;
}
[[stitchable]] float4 justShootMaterialInput(coreimage::sampler image, coreimage::sampler table, float dim) {
    float4 pixel = image.sample(image.coord());
    return float4(materialLookup(table, pixel.rgb / max(pixel.a, 0.000001), dim) * pixel.a, pixel.a);
}
[[stitchable]] float4 justShootMaterialComposite(coreimage::sample_t base,
    coreimage::sample_t halo, coreimage::sample_t bloom, float amount, float hue, float bloomAmount, float response) {
    return float4(justShootMaterialExposure(base.rgb, halo.r, bloom.r, amount, hue, bloomAmount, response), base.a);
}
[[stitchable]] float4 justShootMaterialFinish(coreimage::sampler image, coreimage::sampler density,
    coreimage::sampler paper, coreimage::sampler finish, float3 dimensions, float3 maximum, float3 minimum,
    float4 refinement, float4 colorBalance, float3 calibration, float4 grain, float seed, float2 headroom, coreimage::destination destination) {
    float4 pixel = image.sample(image.coord());
    float3 source = pixel.rgb / max(pixel.a, 0.000001);
    float3 d = materialLookup(density, source, dimensions.x);
    d = justShootMaterialGrain(d, minimum, maximum, destination.coord(), grain.x * calibration.z, grain.y, grain.z, uint(seed));
    float3 color = materialLookup(paper, d, dimensions.y);
    color = justShootMaterialRefine(clamp(source, 0.0, 1.0), color, refinement);
    color = justShootMaterialColorBalance(clamp(source, 0.0, 1.0), color, colorBalance);
    color = justShootMaterialTone(clamp(source, 0.0, 1.0), color, calibration.x, calibration.y);
    color = materialLookup(finish, color, dimensions.z);
    return float4(justShootApplyHeadroom(color, headroom.x, headroom.y) * pixel.a, pixel.a);
}
