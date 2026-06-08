//
//  ScanCompute.metal
//  Magic Camera
//
//  GPU depth-unprojection: one thread per depth pixel back-projects to a world
//  point, samples colour, filters by depth/confidence/stride, and appends to an
//  output buffer via an atomic counter. CPU then does voxel dedup + capping.
//

#include <metal_stdlib>
#include "ScanComputeTypes.h"

using namespace metal;

constant float4x4 kYCbCrToRGB = float4x4(
    float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
    float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
    float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
    float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
);

kernel void unprojectKernel(
    texture2d<float, access::read>   depthTex [[texture(0)]],
    texture2d<uint,  access::read>   confTex  [[texture(1)]],
    texture2d<float, access::sample> yTex     [[texture(2)]],
    texture2d<float, access::sample> cbcrTex  [[texture(3)]],
    constant ScanUniforms &u                  [[buffer(0)]],
    device ScanPoint *outPoints               [[buffer(1)]],
    device atomic_uint *counter               [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= uint(u.depthWidth) || gid.y >= uint(u.depthHeight)) return;
    if (u.stride > 1u && ((gid.x % u.stride) != 0u || (gid.y % u.stride) != 0u)) return;

    float depth = depthTex.read(gid).r;
    if (depth <= 0.0 || !isfinite(depth) || depth > u.maxDepth) return;

    uint confidence = confTex.read(gid).r;
    if (confidence < u.minConfidence) return;

    // Image convention (+x right, +y down, +z forward) -> ARKit camera local.
    float x = (float(gid.x) - u.cx) / max(u.fx, 1e-3) * depth;
    float y = (float(gid.y) - u.cy) / max(u.fy, 1e-3) * depth;
    float4 world = u.cameraTransform * float4(x, -y, -depth, 1.0);

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = float2((float(gid.x) + 0.5) / u.depthWidth,
                       (float(gid.y) + 0.5) / u.depthHeight);
    float yv = yTex.sample(s, uv).r;
    float2 cbcr = cbcrTex.sample(s, uv).rg;
    float3 rgb = saturate((kYCbCrToRGB * float4(yv, cbcr.x, cbcr.y, 1.0)).rgb);

    uint index = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
    if (index >= u.capacity) return;

    ScanPoint p;
    p.position = world.xyz;
    p.color = rgb;
    p.confidence = float(confidence) / 2.0;
    outPoints[index] = p;
}
