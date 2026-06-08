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
    EffectTypeNone    = 0,
    EffectTypeHeatmap = 1,
    EffectTypeBokeh   = 2,
    EffectTypeOutline = 3,
    EffectTypeFog     = 4,
    EffectTypeNormals = 5,
    EffectTypeRelight = 6,
} EffectType;

typedef struct {
    // Maps a fullscreen view UV (homogeneous, origin top-left) to the
    // normalized sample UV of the camera image / depth map.
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
    simd_float2 depthTexel;     // 1 / depthMapSize, for gradient sampling
    simd_float4 depthIntrinsics; // fx, fy, cx, cy in depth-map pixel units
    simd_float2 depthSize;       // depth map width, height (pixels)
    simd_float3 lightDir;        // normalized light direction (image space)
} EffectUniforms;

#endif /* ShaderTypes_h */
