#include <CoreImage/CoreImage.h>
using namespace metal;

[[stitchable]] float4 justShootHDRHighlights(coreimage::sample_t grade, coreimage::sample_t source) {
    float luminance = dot(source.rgb, float3(0.2627, 0.6780, 0.0593));
    float excess = max(0.0, luminance - 1.0);
    // Preserve midtones and roll the captured highlight gain toward a fourfold limit.
    float gain = 1.0 + 3.0 * excess / (3.0 + excess);
    return float4(grade.rgb * gain, grade.a);
}
