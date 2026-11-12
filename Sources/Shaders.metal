//
//  Shaders.metal
//  NomoClone
//
//  Bit-faithful re-implementation of the NomoRaw 3.0.13 look stages.
//  Each kernel reproduces the corresponding AfryMetal.metallib AIR function
//  one-for-one, so results match the original app code path, not just visually.
//

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
static inline float3 rec709_luma3(float3 c) {
    return float3(dot(c, float3(0.2126f, 0.7152f, 0.0722f)));
}

// ---------------------------------------------------------------------------
// 1. exposureFragment
//      out.rgb = in.rgb * pow(2, exposure)          exposure = EV * 0.65
// ---------------------------------------------------------------------------
kernel void exposure_kernel(texture2d<float, access::read>  src     [[texture(0)]],
                            texture2d<float, access::write> dst     [[texture(1)]],
                            constant float                 &stops   [[buffer(0)]],
                            uint2                           gid     [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = src.read(gid);
    c.rgb *= pow(2.0f, stops);          // matches air.fast_pow.f32(2.0, t)
    dst.write(c, gid);
}

// ---------------------------------------------------------------------------
// 2. multiplyBlendFragment  (vignette, strength = darkCorner)
//      out = src * (1 - s + s * plate)
//    Transparency terms collapse to the above for opaque plate + opaque src;
//    the full form is kept so PNG masks with alpha behave like the original.
// ---------------------------------------------------------------------------
kernel void multiply_blend_kernel(texture2d<float, access::read>  src    [[texture(0)]],
                                  texture2d<float, access::sample> plate  [[texture(1)]],
                                  texture2d<float, access::write> dst    [[texture(2)]],
                                  constant float                 &s      [[buffer(0)]],
                                  uint2                           gid    [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 base = src.read(gid);
    float2 uv   = (float2(gid) + 0.5f) / float2(w, h);
    float4 blend = plate.sample(sampler(coord::normalized, filter::linear,
                                        address::clamp_to_edge), uv);

    float4 x  = s * blend;
    float4 y  = x * (1.0f - base.a);
    float4 z  = (1.0f - x.a + x) * base;
    dst.write(z + y, gid);
}

// ---------------------------------------------------------------------------
// 3. softLightBlendFragment  (grain, strength = grains)
//      out = src * (1 - s + s * plate * (2 - src))
// ---------------------------------------------------------------------------
kernel void soft_light_blend_kernel(texture2d<float, access::read>  src    [[texture(0)]],
                                    texture2d<float, access::sample> plate  [[texture(1)]],
                                    texture2d<float, access::write> dst    [[texture(2)]],
                                    constant float                 &s      [[buffer(0)]],
                                    constant float2                &phaseUV[[buffer(1)]],
                                    uint2                           gid    [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 base = src.read(gid);                      // %8
    float2 uv   = (float2(gid) + 0.5f) / float2(w, h) * phaseUV;   // offsets*uv
    uv          = fract(uv);                                       // %11
    float4 blend = plate.sample(sampler(coord::normalized, filter::linear,
                                        address::repeat), uv);     // %12

    float4 x  = s * blend;                            // %17
    float  a  = (base.a <= 0.0f) ? 1.0f : 0.0f;        // %19..%21
    float  da = base.a + a;
    float4 nz = base / da;                            // %26
    float4 aa = float4(x.a);                          // %23
    float4 p1 = aa * nz;                              // %27
    float4 p2 = (2.0f * x) * (1.0f - nz);             // %30
    float4 r1 = p2 + p1;                              // %31
    float4 r2 = x * (1.0f - base.a);                  // %35
    float4 r3 = (r1 + (1.0f - x.a)) * base;           // %40
    dst.write(r3 + r2, gid);                          // %41
}

// ---------------------------------------------------------------------------
// 4. LUTFragment  (3D cube, 64^3, red-fastest memory order)
//      out = mix(isBnW ? luma(src) : src,
//                trilinear(cube, src),
//                lutStrength)
// ---------------------------------------------------------------------------
kernel void lut_kernel(texture2d<float, access::read>  src      [[texture(0)]],
                       texture3d<float, access::sample> cube    [[texture(1)]],
                       texture2d<float, access::write> dst      [[texture(2)]],
                       constant float                 &intensity [[buffer(0)]],
                       constant int                   &isBnW     [[buffer(1)]],
                       uint2                           gid      [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    float4 c0 = src.read(gid);
    float3 c  = clamp(c0.rgb, 0.0f, 1.0f);
    float  n  = float(cube.get_width() - 1);       // 63

    // The .dat payload is laid out as  idx = B*1 + R*64 + G*4096, so the 3D
    // texture is built with x = B, y = R, z = G and needs no repacking.
    // Coordinates sit on texel centres: (i + 0.5) / N.
    float3 idx   = float3(c.b, c.r, c.g) * n;
    float3 coord = (idx + 0.5f) / float(cube.get_width());
    float3 lutRGB = cube.sample(sampler(coord::normalized, filter::linear,
                                        address::clamp_to_edge), coord).rgb;

    float3 base = (isBnW == 1) ? rec709_luma3(c0.rgb) : c0.rgb;
    float3 outRGB = mix(base, lutRGB, intensity);
    dst.write(float4(outRGB, c0.a), gid);
}

// ---------------------------------------------------------------------------
// 5. passthrough (used when a stage is disabled, keeps the chain uniform)
// ---------------------------------------------------------------------------
kernel void copy_kernel(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2                           gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(src.read(gid), gid);
}
