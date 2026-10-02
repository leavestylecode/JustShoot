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
    // All three render paths use an explicitly configured sRGB working space.
    float3 encoded = pixel.rgb;
    float3 textured = justShootApplyFilmGrain(
        encoded,
        destination.coord(),
        amount,
        grainSize,
        chroma,
        uint(seed)
    );
    return float4(textured, pixel.a);
}
