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
    float edgeThreshold;          // reject a texel whose neighbour depth jumps
                                  // more than this fraction of its depth (a
                                  // silhouette "flying pixel"); 0 disables it
} ScanUniforms;

typedef struct {
    simd_float3 position;  // world
    simd_float3 color;     // 0...1 RGB
    float confidence;      // 0, 0.5, 1
} ScanPoint;

typedef struct {
    simd_float3 gridOrigin;       // bounding-box min minus one cell
    float cellSize;               // == search radius (3x3x3 block covers it)
    float radiusSquared;
    unsigned int pointCount;
    unsigned int cellCount;       // number of unique occupied cells
} NeighborUniforms;

typedef struct {
    simd_float3 gridOrigin;       // voxel-lattice-aligned, centred on the camera
    float voxelSize;              // recorder's voxel size
    unsigned int capacity;        // point-buffer capacity
    unsigned int hashCapacity;    // open-addressing table slots
} DedupUniforms;

typedef struct {
    simd_float3 gridOrigin;       // point grid origin (bbox min − support)
    float cellSize;               // grid cell == support radius (3x3x3 covers it)
    float supportSquared;         // support * support (kernel truncation)
    float inv2s2;                 // 1 / (2 * support^2), the Gaussian falloff
    unsigned int cornerCount;     // number of lattice corners to evaluate
    unsigned int cellCount;       // number of unique occupied point cells
} FieldUniforms;

// Per-keyframe projection for the GPU photo texture bake.
typedef struct {
    matrix_float4x4 worldToCamera;  // inverse of the camera-to-world pose
    simd_float3 gain;               // per-channel exposure harmonisation
    float fx; float fy; float cx; float cy;  // depth-scaled intrinsics
    float depthWidth; float depthHeight;     // projection bounds / normaliser
} BakeKeyframe;

typedef struct {
    unsigned int triangleCount;
    unsigned int texSize;           // atlas texture is texSize × texSize
} BakeUniforms;

#endif /* ScanComputeTypes_h */
