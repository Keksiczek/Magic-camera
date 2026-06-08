//
//  ShaderTypes.h
//  Magic Camera
//
//  Types shared between Swift and Metal. Using simd types guarantees the
//  memory layout matches on both sides, so the same header is included from
//  Swift (via the bridging header) and from the .metal sources.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Keep raw values in sync with the Swift `DepthEffectKind` enum.
typedef enum EffectType {
    EffectTypeNone       = 0,
    EffectTypeHeatmap    = 1,
    EffectTypeBokeh      = 2,
    EffectTypeOutline    = 3,
    EffectTypeFog        = 4,
    EffectTypeNormals    = 5,
    EffectTypeRelight    = 6,
    EffectTypePortrait   = 7,
    EffectTypeColorPop   = 8,
    EffectTypeDepthGrade = 9,
} EffectType;

typedef struct {
    matrix_float3x3 viewToImage;

    int   effect;          // EffectType
    float focusDistance;   // metres (bokeh focal plane)
    float focusRange;      // metres (bokeh transition width)
    float intensity;       // 0...1 blend of effect vs. raw image
    float fogDensity;      // exponential fog coefficient
    float depthMin;        // metres mapped to 0 in colour ramps
    float depthMax;        // metres mapped to 1 in colour ramps
    float bokehMaxRadius;  // max blur radius in image-UV units

    simd_float3 fogColor;
    simd_float2 depthTexel;      // 1 / depthMapSize
    simd_float4 depthIntrinsics; // fx, fy, cx, cy in depth-map pixel units
    simd_float2 depthSize;       // depth map width, height (pixels)
    simd_float3 lightDir;        // normalized light direction (image space)
    float hasSegmentation;       // 1 if a person matte is bound, else 0

    // Global tone grade applied after every effect.
    float saturation;            // 1 = unchanged
    float contrast;              // 1 = unchanged
    float vignette;              // 0 = none, 1 = strong
    float grain;                 // 0 = none, film-grain amount
    float grainSeed;             // per-frame seed so grain animates
} EffectUniforms;

#endif /* ShaderTypes_h */
