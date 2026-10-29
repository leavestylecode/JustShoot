#include <CoreImage/CoreImage.h>
#include "FilmMaterialMath.h"
using namespace metal;

float3 materialNode(coreimage::sampler table, float3 index, float dim) {
    float2 p = float2(index.x, dim * dim - 1.0 - index.y - index.z * dim) + 0.5;
    return table.sample(table.transform(p)).rgb;
}
float3 materialLookup(coreimage::sampler table, float3 rgb, float dim) {
    // Identity tables still clamp their domain; preserve this for HDR/RAW inputs
    // and for energy added before density development.
    if (dim == 0.0) return clamp(rgb, 0.0, 1.0);
    float3 pos = clamp(rgb, 0.0, 1.0) * (dim - 1.0);
    float3 lo = floor(pos), hi = min(lo + 1.0, dim - 1.0), f = pos - lo;
    float3 a = mix(materialNode(table, lo, dim), materialNode(table, float3(hi.x, lo.y, lo.z), dim), f.x);
    float3 b = mix(materialNode(table, float3(lo.x, hi.y, lo.z), dim), materialNode(table, float3(hi.x, hi.y, lo.z), dim), f.x);
    float3 c = mix(materialNode(table, float3(lo.x, lo.y, hi.z), dim), materialNode(table, float3(hi.x, lo.y, hi.z), dim), f.x);
    float3 d = mix(materialNode(table, float3(lo.x, hi.y, hi.z), dim), materialNode(table, hi, dim), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}
[[stitchable]] float4 justShootMaterialInput(coreimage::sampler image, coreimage::sampler table, float dim) {
    float4 pixel = image.sample(image.coord());
    return float4(materialLookup(table, pixel.rgb / max(pixel.a, 0.000001), dim) * pixel.a, pixel.a);
}
[[stitchable]] float4 justShootMaterialComposite(coreimage::sample_t base,
    coreimage::sample_t halo, coreimage::sample_t bloom, float amount, float hue, float bloomAmount) {
    return float4(justShootMaterialExposure(base.rgb, halo.r, bloom.r, amount, hue, bloomAmount), base.a);
}
[[stitchable]] float4 justShootMaterialFinish(coreimage::sampler image, coreimage::sampler density,
    coreimage::sampler paper, coreimage::sampler finish, float3 dimensions, float3 maximum,
    float4 refinement, float4 grain, float seed, float2 headroom, coreimage::destination destination) {
    float4 pixel = image.sample(image.coord());
    float3 source = pixel.rgb / max(pixel.a, 0.000001);
    float3 d = materialLookup(density, source, dimensions.x);
    d = justShootMaterialGrain(d, maximum, destination.coord(), grain.x, grain.y, grain.z, uint(seed));
    float3 color = materialLookup(paper, d, dimensions.y);
    color = justShootMaterialRefine(clamp(source, 0.0, 1.0), color, refinement);
    color = materialLookup(finish, color, dimensions.z);
    return float4(justShootApplyHeadroom(color, headroom.x, headroom.y) * pixel.a, pixel.a);
}
