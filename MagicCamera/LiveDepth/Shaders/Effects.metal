//
//  Effects.metal
//  Magic Camera
//
//  Fullscreen depth-effect pass. Samples the ARKit captured image (YCbCr,
//  two planes), the LiDAR depth map, and (when available) the person
//  segmentation matte, then applies the selected effect.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 viewUV;
};

vertex VertexOut effectVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.viewUV = uv;
    return out;
}

constant float4x4 kYCbCrToRGB = float4x4(
    float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
    float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
    float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
    float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
);

static inline float3 sampleRGB(texture2d<float> yTex, texture2d<float> cbcrTex,
                               sampler s, float2 uv) {
    float  y    = yTex.sample(s, uv).r;
    float2 cbcr = cbcrTex.sample(s, uv).rg;
    return saturate((kYCbCrToRGB * float4(y, cbcr.x, cbcr.y, 1.0)).rgb);
}

static inline float sampleDepth(texture2d<float> depthTex, sampler s, float2 uv) {
    return depthTex.sample(s, uv).r;
}

static inline float3 heatRamp(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 c;
    c.r = clamp(1.5 - abs(4.0 * t - 1.5), 0.0, 1.0);
    c.g = clamp(1.5 - abs(4.0 * t - 2.5), 0.0, 1.0);
    c.b = clamp(1.5 - abs(4.0 * t - 3.5), 0.0, 1.0);
    return c;
}

static inline float3 viewPosition(float2 imageUV, float depth, constant EffectUniforms &u) {
    float px = imageUV.x * u.depthSize.x;
    float py = imageUV.y * u.depthSize.y;
    float x = (px - u.depthIntrinsics.z) / max(u.depthIntrinsics.x, 1e-3) * depth;
    float y = (py - u.depthIntrinsics.w) / max(u.depthIntrinsics.y, 1e-3) * depth;
    return float3(x, y, depth);
}

static inline float3 surfaceNormal(texture2d<float> depthTex, sampler s,
                                   float2 uv, float depth, constant EffectUniforms &u) {
    float2 tx = u.depthTexel;
    float dR = sampleDepth(depthTex, s, uv + float2(tx.x, 0));
    float dD = sampleDepth(depthTex, s, uv + float2(0, tx.y));
    if (dR <= 0.0 || dD <= 0.0) return float3(0, 0, -1);
    float3 pC = viewPosition(uv, depth, u);
    float3 pR = viewPosition(uv + float2(tx.x, 0), dR, u);
    float3 pD = viewPosition(uv + float2(0, tx.y), dD, u);
    return normalize(cross(pD - pC, pR - pC));
}

// Disc blur (golden-angle spiral) over the camera image.
static inline float3 discBlur(texture2d<float> yTex, texture2d<float> cbcrTex,
                              sampler s, float2 uv, float radius) {
    float3 sum = sampleRGB(yTex, cbcrTex, s, uv);
    float count = 1.0;
    const int taps = 12;
    for (int i = 0; i < taps; i++) {
        float a = float(i) * 2.3999632;
        float r = radius * sqrt(float(i + 1) / float(taps));
        sum += sampleRGB(yTex, cbcrTex, s, uv + float2(cos(a), sin(a)) * r);
        count += 1.0;
    }
    return sum / count;
}

fragment float4 effectFragment(VertexOut in [[stage_in]],
                               constant EffectUniforms &u [[buffer(0)]],
                               texture2d<float> yTex     [[texture(0)]],
                               texture2d<float> cbcrTex  [[texture(1)]],
                               texture2d<float> depthTex [[texture(2)]],
                               texture2d<float> segTex   [[texture(3)]]) {
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear,
                                    address::clamp_to_edge);

    float3 mapped = u.viewToImage * float3(in.viewUV, 1.0);
    float2 imageUV = mapped.xy / mapped.z;

    if (imageUV.x < 0.0 || imageUV.x > 1.0 || imageUV.y < 0.0 || imageUV.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float3 rgb = sampleRGB(yTex, cbcrTex, linearSampler, imageUV);
    float depth = sampleDepth(depthTex, linearSampler, imageUV);
    bool hasDepth = depth > 0.0 && isfinite(depth);

    float3 outColor = rgb;

    switch (u.effect) {
        case EffectTypeHeatmap: {
            float t = (depth - u.depthMin) / max(u.depthMax - u.depthMin, 0.001);
            float3 heat = hasDepth ? heatRamp(t) : float3(0.05);
            outColor = mix(rgb, heat, u.intensity);
            break;
        }
        case EffectTypeBokeh: {
            if (!hasDepth) { outColor = rgb; break; }
            float coc = clamp(abs(depth - u.focusDistance) / max(u.focusRange, 0.01), 0.0, 1.0);
            float radius = coc * u.bokehMaxRadius * u.intensity;
            outColor = radius < 1e-4 ? rgb : discBlur(yTex, cbcrTex, linearSampler, imageUV, radius);
            break;
        }
        case EffectTypeOutline: {
            float2 tx = u.depthTexel;
            float dl = sampleDepth(depthTex, linearSampler, imageUV - float2(tx.x, 0));
            float dr = sampleDepth(depthTex, linearSampler, imageUV + float2(tx.x, 0));
            float dt = sampleDepth(depthTex, linearSampler, imageUV - float2(0, tx.y));
            float db = sampleDepth(depthTex, linearSampler, imageUV + float2(0, tx.y));
            float grad = length(float2(dr - dl, db - dt));
            float edge = smoothstep(0.01, 0.06, grad / max(depth, 0.3));
            edge *= clamp(u.intensity * 1.5, 0.0, 1.0);
            outColor = mix(rgb, float3(0.1, 1.0, 0.85), edge);
            break;
        }
        case EffectTypeFog: {
            float d = hasDepth ? depth : u.depthMax;
            float f = clamp((1.0 - exp(-u.fogDensity * d)) * u.intensity, 0.0, 1.0);
            outColor = mix(rgb, u.fogColor, f);
            break;
        }
        case EffectTypeNormals: {
            if (!hasDepth) { outColor = float3(0.05); break; }
            float3 n = surfaceNormal(depthTex, linearSampler, imageUV, depth, u);
            outColor = mix(rgb, n * 0.5 + 0.5, u.intensity);
            break;
        }
        case EffectTypeRelight: {
            if (!hasDepth) { outColor = rgb; break; }
            float3 n = surfaceNormal(depthTex, linearSampler, imageUV, depth, u);
            float ndotl = max(dot(n, normalize(u.lightDir)), 0.0);
            outColor = mix(rgb, rgb * (0.2 + 0.8 * ndotl), u.intensity);
            break;
        }
        case EffectTypePortrait: {
            if (u.hasSegmentation < 0.5) { outColor = rgb; break; }
            float matte = segTex.sample(linearSampler, imageUV).r; // 1 person, 0 background
            float radius = mix(0.004, 0.03, clamp(u.intensity, 0.0, 1.0));
            float3 background = discBlur(yTex, cbcrTex, linearSampler, imageUV, radius);
            float person = smoothstep(0.35, 0.65, matte);
            outColor = mix(background, rgb, person);
            break;
        }
        default:
            outColor = rgb;
            break;
    }

    return float4(outColor, 1.0);
}
