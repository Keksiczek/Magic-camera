//
//  PointCloud.metal
//  Magic Camera
//
//  Point rendering with a separate eye-space depth target, then an eye-dome
//  lighting (EDL) post-pass that darkens points on the far side of depth edges
//  for much better shape readability.
//

#include <metal_stdlib>
#include "PointCloudTypes.h"

using namespace metal;

struct PointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
    float eyeDepth;   // positive distance from camera
};

struct PointFragOut {
    float4 color    [[color(0)]];
    float eyeDepth  [[color(1)]];
};

vertex PointOut pointVertex(uint vid [[vertex_id]],
                            const device float3 *positions [[buffer(0)]],
                            const device float3 *colors    [[buffer(1)]],
                            constant PointVertexUniforms &u [[buffer(2)]]) {
    float4 viewPos = u.modelView * float4(positions[vid], 1.0);
    PointOut out;
    out.position = u.projection * viewPos;
    out.pointSize = u.pointSize;
    out.color = colors[vid];
    out.eyeDepth = -viewPos.z;
    return out;
}

fragment PointFragOut pointFragment(PointOut in [[stage_in]],
                                    float2 pc [[point_coord]]) {
    // Round the square point sprite.
    if (length(pc - float2(0.5)) > 0.5) discard_fragment();
    PointFragOut out;
    out.color = float4(in.color, 1.0);
    out.eyeDepth = in.eyeDepth;
    return out;
}

struct EDLVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex EDLVertexOut edlVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    EDLVertexOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment float4 edlFragment(EDLVertexOut in [[stage_in]],
                            constant EDLUniforms &u [[buffer(0)]],
                            texture2d<float> colorTex    [[texture(0)]],
                            texture2d<float> eyeDepthTex [[texture(1)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);

    float3 color = colorTex.sample(s, in.uv).rgb;
    float d0 = eyeDepthTex.sample(s, in.uv).r;
    if (d0 <= 0.0 || u.edlStrength <= 0.0) {
        return float4(color, 1.0);
    }

    float l0 = log2(d0 + 1e-3);
    const float2 dirs[8] = {
        float2( 1, 0), float2(-1, 0), float2(0, 1), float2(0,-1),
        float2( 0.7071, 0.7071), float2(-0.7071, 0.7071),
        float2( 0.7071,-0.7071), float2(-0.7071,-0.7071)
    };

    float sum = 0.0;
    int n = 0;
    for (int i = 0; i < 8; i++) {
        float2 off = dirs[i] * u.edlRadius * u.inverseResolution;
        float dn = eyeDepthTex.sample(s, in.uv + off).r;
        if (dn > 0.0) {
            sum += max(0.0, l0 - log2(dn + 1e-3));
            n++;
        }
    }
    float response = (n > 0) ? sum / float(n) : 0.0;
    float shade = exp(-u.edlStrength * response * 80.0);
    return float4(color * shade, 1.0);
}
