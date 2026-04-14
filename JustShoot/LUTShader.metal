#include <metal_stdlib>
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
};

// Single-pass compute kernel: rotation + aspect-fill crop + 3D LUT color grading
// Replaces the CIImage pipeline (orient → CIColorCube → scale → CIContext.render)
kernel void previewLUT(
    texture2d<half, access::read>    input  [[texture(0)]],
    texture3d<float, access::sample> lut    [[texture(1)]],
    texture2d<half, access::write>   output [[texture(2)]],
    constant PreviewParams &params          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint outW = output.get_width();
    uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    // Inverse aspect-fill: output pixel → position in rotated virtual image
    float rx = (float(gid.x) - params.offsetX) / params.scale;
    float ry = (float(gid.y) - params.offsetY) / params.scale;

    // Inverse rotation: rotated coords → original input coords
    float srcX, srcY;
    float inW = float(params.inputWidth);
    float inH = float(params.inputHeight);

    switch (params.rotation) {
        case 1: // 90 CW (.right) — landscape buffer displayed as portrait
            srcX = ry;
            srcY = inH - 1.0 - rx;
            break;
        case 2: // 180 (.down)
            srcX = inW - 1.0 - rx;
            srcY = inH - 1.0 - ry;
            break;
        case 3: // 270 CW (.left)
            srcX = inW - 1.0 - ry;
            srcY = rx;
            break;
        default: // 0 — no rotation
            srcX = rx;
            srcY = ry;
            break;
    }

    // Bounds check — pixels outside the source image are black
    if (srcX < 0.0 || srcX >= inW || srcY < 0.0 || srcY >= inH) {
        output.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
        return;
    }

    // Read input pixel (bgra8Unorm → half4 RGBA by hardware swizzle)
    half4 color = input.read(uint2(uint(srcX), uint(srcY)));

    // 3D LUT lookup with correct texel-center mapping
    // Maps input [0,1] → texture coords [0.5/dim, (dim-0.5)/dim] for accurate sampling
    float dim = float(params.lutDimension);
    float3 lutCoord = float3(color.rgb) * ((dim - 1.0) / dim) + 0.5 / dim;

    constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);
    float4 graded = lut.sample(lutSampler, lutCoord);

    output.write(half4(half3(graded.rgb), 1.0h), gid);
}
