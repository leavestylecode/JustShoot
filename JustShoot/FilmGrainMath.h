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

inline float4 justShootGrainPattern(float2 pixelPosition, float grainSize, uint seed)
{
    float2 point = pixelPosition / max(grainSize, 1.0);
    float4 broad = justShootGrainValueNoise(point, seed);
    int2 fineCell = int2(floor(pixelPosition));
    float4 fine = justShootGrainComponents(
        justShootGrainCoordinateHash(fineCell, seed ^ 0xA511E9B3u)
    );
    return broad * 0.72 + fine * 0.28;
}

inline float justShootGrainChannel(float value, float noise, float amount, float visibility)
{
    float capacity = noise >= 0.0 ? 1.0 - value : value;
    return clamp(value + noise * amount * visibility * capacity, 0.0, 1.0);
}

inline float3 justShootApplyFilmGrain(
    float3 color,
    float2 pixelPosition,
    float amount,
    float grainSize,
    float chroma,
    uint seedValue
) {
    if (amount <= 0.0001) return color;

    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    float density = clamp(4.0 * luminance * (1.0 - luminance), 0.0, 1.0);
    float visibility = 0.35 + 0.65 * sqrt(density);

    uint seed = seedValue & 0x00FFFFFFu;
    float4 pattern = justShootGrainPattern(pixelPosition, grainSize, seed);
    float3 noise = mix(float3(pattern.x), pattern.yzw, chroma);

    return float3(
        justShootGrainChannel(color.r, noise.r, amount, visibility),
        justShootGrainChannel(color.g, noise.g, amount, visibility),
        justShootGrainChannel(color.b, noise.b, amount, visibility)
    );
}

#endif
