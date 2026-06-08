//
//  PointCloudTypes.h
//  Magic Camera
//
//  Swift/Metal shared types for the point-cloud renderer.
//

#ifndef PointCloudTypes_h
#define PointCloudTypes_h

#include <simd/simd.h>

typedef struct {
    matrix_float4x4 projection;
    matrix_float4x4 modelView;
    float pointSize;
} PointVertexUniforms;

typedef struct {
    simd_float2 inverseResolution;
    float edlStrength;   // 0 disables eye-dome lighting
    float edlRadius;     // sample radius in pixels
} EDLUniforms;

#endif /* PointCloudTypes_h */
