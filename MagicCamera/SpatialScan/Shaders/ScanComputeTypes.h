//
//  ScanComputeTypes.h
//  Magic Camera
//
//  Swift/Metal shared types for the GPU depth-unprojection kernel.
//

#ifndef ScanComputeTypes_h
#define ScanComputeTypes_h

#include <simd/simd.h>

typedef struct {
    matrix_float4x4 cameraTransform; // camera-to-world
    float fx; float fy; float cx; float cy; // intrinsics in depth-pixel units
    float depthWidth; float depthHeight;
    float maxDepth;
    unsigned int stride;
    unsigned int minConfidence;   // 0 low, 1 medium, 2 high
    unsigned int capacity;        // max output points
} ScanUniforms;

typedef struct {
    simd_float3 position;  // world
    simd_float3 color;     // 0...1 RGB
    float confidence;      // 0, 0.5, 1
} ScanPoint;

#endif /* ScanComputeTypes_h */
