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
    // +0.5: the ray passes through the texel centre (matches the colour
    // sampling below and DepthMath.cameraLocalPoint on the CPU path).
    float x = (float(gid.x) + 0.5f - u.cx) / max(u.fx, 1e-3) * depth;
    float y = (float(gid.y) + 0.5f - u.cy) / max(u.fy, 1e-3) * depth;
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

// MARK: - GPU radius-neighbour counting (point-cloud denoising)
//
// One thread per point counts neighbours within `radiusSquared` using a
// CPU-prebuilt sorted uniform grid: points are sorted by packed cell key;
// each thread binary-searches the 27 surrounding cells and tests distances.
// The CPU then drops points with too few neighbours (radius outlier removal).

static inline ulong packedCellKey(int3 c) {
    // 21 bits per axis with a 2^20 bias keeps coordinates positive and unique.
    return (ulong(uint(c.x + 1048576)) << 42)
         | (ulong(uint(c.y + 1048576)) << 21)
         |  ulong(uint(c.z + 1048576));
}

kernel void neighborCountKernel(
    device const float3 *positions [[buffer(0)]],   // sorted by cell key
    device const ulong  *cellKeys  [[buffer(1)]],   // unique keys, ascending
    device const uint   *cellStarts[[buffer(2)]],
    device const uint   *cellCounts[[buffer(3)]],
    constant NeighborUniforms &u   [[buffer(4)]],
    device uint *outCounts         [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {

    if (gid >= u.pointCount) return;
    float3 p = positions[gid];
    int3 base = int3(floor((p - u.gridOrigin) / u.cellSize));

    uint count = 0;
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                ulong key = packedCellKey(base + int3(dx, dy, dz));
                uint lo = 0, hi = u.cellCount;
                while (lo < hi) {
                    uint mid = (lo + hi) >> 1;
                    if (cellKeys[mid] < key) { lo = mid + 1; } else { hi = mid; }
                }
                if (lo >= u.cellCount || cellKeys[lo] != key) continue;
                uint start = cellStarts[lo];
                uint n = cellCounts[lo];
                for (uint i = 0; i < n; ++i) {
                    float3 d = positions[start + i] - p;
                    if (dot(d, d) <= u.radiusSquared) count++;
                }
            }
        }
    }
    outCounts[gid] = count;   // includes the point itself
}

// MARK: - GPU signed-distance field evaluation (smooth/Fusion reconstruction)
//
// One thread per lattice corner evaluates the Hoppe-style Gaussian-weighted
// signed distance to the local plane of nearby points — the heavy inner loop of
// SmoothSurfaceReconstructor. Same CPU-prebuilt sorted uniform grid as
// neighborCountKernel (cell = support radius): binary-search the 27 surrounding
// cells, accumulate weighted dot(x − pᵢ, nᵢ). The CPU then polygonises the field
// with marching cubes. Undefined corners (no points in range) return +INF, which
// the CPU treats as the "outside the narrow band" sentinel.

kernel void sdfFieldKernel(
    device const float3 *points    [[buffer(0)]],   // sorted by cell key
    device const float3 *normals   [[buffer(1)]],   // sorted to match `points`
    device const ulong  *cellKeys  [[buffer(2)]],   // unique keys, ascending
    device const uint   *cellStarts[[buffer(3)]],
    device const uint   *cellCounts[[buffer(4)]],
    device const float3 *queries   [[buffer(5)]],   // lattice-corner world positions
    constant FieldUniforms &u      [[buffer(6)]],
    device float *outField         [[buffer(7)]],
    uint gid [[thread_position_in_grid]]) {

    if (gid >= u.queryCount) return;
    float3 x = queries[gid];
    int3 base = int3(floor((x - u.gridOrigin) / u.cellSize));

    float weightSum = 0.0;
    float valueSum = 0.0;
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                ulong key = packedCellKey(base + int3(dx, dy, dz));
                uint lo = 0, hi = u.cellCount;
                while (lo < hi) {
                    uint mid = (lo + hi) >> 1;
                    if (cellKeys[mid] < key) { lo = mid + 1; } else { hi = mid; }
                }
                if (lo >= u.cellCount || cellKeys[lo] != key) continue;
                uint start = cellStarts[lo];
                uint n = cellCounts[lo];
                for (uint i = 0; i < n; ++i) {
                    float3 diff = x - points[start + i];
                    float d2 = dot(diff, diff);
                    if (d2 < u.supportSquared) {
                        float w = exp(-d2 * u.inv2s2);
                        weightSum += w;
                        valueSum += w * dot(diff, normals[start + i]);
                    }
                }
            }
        }
    }
    outField[gid] = weightSum > 1e-6 ? (valueSum / weightSum) : INFINITY;
}

// MARK: - GPU intra-frame voxel dedup
//
// At pixel stride 1 a close-up surface lands many depth pixels in the same
// recorder voxel; the CPU then rejects them one by one through its dictionary.
// This pass collapses a frame's candidates to one point per voxel on the GPU
// (open-addressing hash, atomic CAS) so the CPU sees far fewer candidates.
// The lattice is aligned to the recorder's absolute voxel grid, so dedup here
// agrees with the cross-frame dedup on the CPU.

kernel void voxelDedupKernel(
    device const ScanPoint *inPoints [[buffer(0)]],
    device const uint *inCount       [[buffer(1)]],   // counter from unprojectKernel
    device ScanPoint *outPoints      [[buffer(2)]],
    device atomic_uint *outCounter   [[buffer(3)]],
    device atomic_uint *hashTable    [[buffer(4)]],   // pre-filled with 0xFFFFFFFF
    constant DedupUniforms &u        [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {

    uint count = min(*inCount, u.capacity);
    if (gid >= count) return;
    ScanPoint p = inPoints[gid];

    // 11/11/10-bit packed voxel key. The wrap from masking can only alias
    // voxels ≥1024 cells (≥5 m) apart — beyond a frame's depth range.
    int3 c = int3(floor((p.position - u.gridOrigin) / u.voxelSize));
    uint key = ((uint(c.x) & 0x7FFu) << 21)
             | ((uint(c.y) & 0x7FFu) << 10)
             |  (uint(c.z) & 0x3FFu);
    if (key == 0xFFFFFFFFu) { key = 0xFFFFFFFEu; }    // keep the empty sentinel unique

    uint slot = (key * 2654435761u) % u.hashCapacity;
    for (uint probe = 0; probe < 64u; ++probe) {
        uint expected = 0xFFFFFFFFu;
        if (atomic_compare_exchange_weak_explicit(&hashTable[slot], &expected, key,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
            uint index = atomic_fetch_add_explicit(outCounter, 1u, memory_order_relaxed);
            if (index < u.capacity) { outPoints[index] = p; }
            return;
        }
        if (expected == key) return;                   // duplicate in this frame
        slot = (slot + 1u) % u.hashCapacity;
    }
    // Crowded table: pass the point through rather than drop it.
    uint index = atomic_fetch_add_explicit(outCounter, 1u, memory_order_relaxed);
    if (index < u.capacity) { outPoints[index] = p; }
}

// MARK: - GPU photo texture bake
//
// One thread per triangle bakes its atlas chart: rasterise the chart (port of
// TextureAtlas.forEachTexel), interpolate world space, project into the
// triangle's chosen keyframe (port of PhotoTextureBaker.View.project, minus the
// per-texel depth occlusion — the best-keyframe choice was already occlusion-
// aware), sample the photo and write the gained colour. Charts are disjoint, so
// threads never write the same texel; triangles with no keyframe (view < 0) are
// left for the CPU fallback.

kernel void bakeTextureKernel(
    device const float3 *triWorld   [[buffer(0)]],   // 3 per triangle
    device const float2 *triUV      [[buffer(1)]],   // 3 per triangle, pixel space
    device const int    *triView    [[buffer(2)]],   // keyframe index or -1
    device const BakeKeyframe *kf   [[buffer(3)]],
    constant BakeUniforms &u        [[buffer(4)]],
    device uchar4 *outPixels        [[buffer(5)]],
    texture2d_array<float> photos   [[texture(0)]],
    uint gid [[thread_position_in_grid]]) {

    if (gid >= u.triangleCount) return;
    int view = triView[gid];
    if (view < 0) return;

    float3 w0 = triWorld[gid * 3 + 0];
    float3 w1 = triWorld[gid * 3 + 1];
    float3 w2 = triWorld[gid * 3 + 2];
    float2 a = triUV[gid * 3 + 0];
    float2 b = triUV[gid * 3 + 1];
    float2 c = triUV[gid * 3 + 2];
    BakeKeyframe k = kf[view];

    int texMax = int(u.texSize) - 1;
    int minX = max(int(floor(min(min(a.x, b.x), c.x))) - 1, 0);
    int maxX = min(int(ceil(max(max(a.x, b.x), c.x))) + 1, texMax);
    int minY = max(int(floor(min(min(a.y, b.y), c.y))) - 1, 0);
    int maxY = min(int(ceil(max(max(a.y, b.y), c.y))) + 1, texMax);
    if (minX > maxX || minY > maxY) return;

    float2 e0 = b - a, e1 = c - a;
    float denom = e0.x * e1.y - e1.x * e0.y;
    if (fabs(denom) < 1e-9) return;
    float invDenom = 1.0 / denom;
    const float margin = -0.18;
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge, coord::normalized);

    for (int py = minY; py <= maxY; ++py) {
        for (int px = minX; px <= maxX; ++px) {
            float2 q = float2(float(px) + 0.5, float(py) + 0.5) - a;
            float l1 = (q.x * e1.y - e1.x * q.y) * invDenom;
            float l2 = (e0.x * q.y - q.x * e0.y) * invDenom;
            float l0 = 1.0 - l1 - l2;
            if (l0 < margin || l1 < margin || l2 < margin) continue;
            l0 = max(l0, 0.0); l1 = max(l1, 0.0); l2 = max(l2, 0.0);
            float sum = l0 + l1 + l2;
            if (sum < 1e-9) continue;
            l0 /= sum; l1 /= sum; l2 /= sum;

            float3 world = w0 * l0 + w1 * l1 + w2 * l2;
            float4 pc = k.worldToCamera * float4(world, 1.0);
            float depth = -pc.z;
            if (depth <= 0.05) continue;
            float pu = pc.x / depth * k.fx + k.cx;
            float pv = -pc.y / depth * k.fy + k.cy;
            if (pu < 1.0 || pv < 1.0 || pu >= k.depthWidth - 1.0 || pv >= k.depthHeight - 1.0) continue;

            float2 uv = float2(pu / k.depthWidth, pv / k.depthHeight);
            float3 color = saturate(photos.sample(s, uv, uint(view)).rgb * k.gain);
            outPixels[py * int(u.texSize) + px] = uchar4(uchar(color.r * 255.0 + 0.5),
                                                         uchar(color.g * 255.0 + 0.5),
                                                         uchar(color.b * 255.0 + 0.5), 255);
        }
    }
}
