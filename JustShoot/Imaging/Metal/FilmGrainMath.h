#ifndef FilmGrainMath_h
#define FilmGrainMath_h

#include <metal_stdlib>
using namespace metal;

inline uint justShootGrainHash(uint value)
{
    value ^= value >> 16;
    value *= 0x7FEB352Du;
    value ^= value >> 15;
    value *= 0x846CA68Bu;
    value ^= value >> 16;
    return value;
}

inline uint justShootGrainCoordinateHash(int2 cell, uint seed)
{
    uint combined = uint(cell.x) * 0x8DA6B343u;
    combined ^= uint(cell.y) * 0xD8163841u;
    combined ^= seed * 0xCB1AB31Fu;
    return justShootGrainHash(combined);
}

/// 一个 32-bit hash 同时拆出共享亮度噪声 + R/G/B 三个低相关分量，避免逐通道重复昂贵运算。
inline float4 justShootGrainComponents(uint hash)
{
    float4 bytes = float4(
        float(hash & 0xFFu),
        float((hash >> 8) & 0xFFu),
        float((hash >> 16) & 0xFFu),
        float((hash >> 24) & 0xFFu)
    );
    return bytes / 127.5 - 1.0;
}

inline float4 justShootGrainValueNoise(float2 point, uint seed)
{
    int2 cell = int2(floor(point));
    float2 fraction = fract(point);
    fraction = fraction * fraction * (3.0 - 2.0 * fraction);

    float4 a = justShootGrainComponents(justShootGrainCoordinateHash(cell, seed));
    float4 b = justShootGrainComponents(justShootGrainCoordinateHash(cell + int2(1, 0), seed));
    float4 c = justShootGrainComponents(justShootGrainCoordinateHash(cell + int2(0, 1), seed));
    float4 d = justShootGrainComponents(justShootGrainCoordinateHash(cell + int2(1, 1), seed));
    return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
}

inline float4 justShootGrainPattern(float2 pixelPosition, float grainSize, uint seed, float response)
{
    float2 point = pixelPosition / max(grainSize, 1.0);
    float4 broad = justShootGrainValueNoise(point, seed);
    int2 fineCell = int2(floor(pixelPosition));
    float4 fine = justShootGrainComponents(
        justShootGrainCoordinateHash(fineCell, seed ^ 0xA511E9B3u)
    );
    if (response > 0.5) return broad * 0.82 + fine * 0.18;
    return broad * 0.72 + fine * 0.28;
}

inline float justShootGrainChannel(float value, float noise, float amount, float visibility)
{
    float capacity = noise >= 0.0 ? 1.0 - value : value;
    return clamp(value + noise * amount * visibility * capacity, 0.0, 1.0);
}

inline float justShootBalancedGrainChannel(float value, float noise, float amplitude)
{
    float bounded = clamp(value, 0.0, 1.0);
    // Equal positive/negative amplitude retains the expected channel value.
    // The endpoint limit prevents clipping without adding a black floor.
    float capacity = min(bounded, 1.0 - bounded);
    return bounded + noise * min(amplitude, capacity);
}

inline float3 justShootFujifilmGrain(
    float3 color, float2 position, float amount, float size, float chroma, uint seed, float luminance,
    float3 bandSampling
) {
    // Neighboring pixels share both grain bands on the film plane.
    float4 broad = justShootGrainValueNoise(position / max(1.0, size) + bandSampling.x, seed);
    float4 fine = justShootGrainValueNoise(position / max(1.0, size * 0.65) + bandSampling.y, seed ^ 0xA511E9B3u);
    float4 pattern = broad * (1.0 - bandSampling.z) + fine * bandSampling.z;
    float3 noise = mix(float3(pattern.x), pattern.yzw, chroma);

    // Fade through the toe and shoulder with zero slope at each endpoint.
    float shadows = smoothstep(0.015, 0.34, luminance);
    float highlights = 1.0 - smoothstep(0.62, 1.0, luminance);
    float amplitude = amount * shadows * highlights * 0.5;
    float3 bounded = clamp(color, 0.0, 1.0);
    float3 capacity = min(bounded, 1.0 - bounded);
    // A symmetric soft limit keeps saturated channels in gamut without a clipping bias.
    float3 variation = amplitude * capacity / (capacity + amplitude + 1e-6);
    return bounded + noise * variation;
}

inline float3 justShootApplyFilmGrain(
    float3 color,
    float2 pixelPosition,
    float amount,
    float grainSize,
    float chroma,
    uint seedValue,
    float response,
    float3 bandSampling
) {
    if (amount <= 0.0001) return color;

    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    uint seed = seedValue & 0x00FFFFFFu;
    if (response > 1.5) {
        return justShootFujifilmGrain(color, pixelPosition, amount, grainSize, chroma, seed, luminance, bandSampling);
    }
    float density = clamp(4.0 * luminance * (1.0 - luminance), 0.0, 1.0);
    float visibility = 0.35 + 0.65 * sqrt(density);

    float4 pattern = justShootGrainPattern(pixelPosition, grainSize, seed, response);
    float3 noise = mix(float3(pattern.x), pattern.yzw, chroma);

    if (response > 0.5) {
        float shadowWeight = 0.80 + 0.20 * smoothstep(0.04, 0.22, luminance);
        float amplitude = amount * visibility * shadowWeight * 0.5;
        return float3(
            justShootBalancedGrainChannel(color.r, noise.r, amplitude),
            justShootBalancedGrainChannel(color.g, noise.g, amplitude),
            justShootBalancedGrainChannel(color.b, noise.b, amplitude)
        );
    }

    return float3(
        justShootGrainChannel(color.r, noise.r, amount, visibility),
        justShootGrainChannel(color.g, noise.g, amount, visibility),
        justShootGrainChannel(color.b, noise.b, amount, visibility)
    );
}

#endif
