//
//  AdaptiveSurfaceReconstructor.swift
//  Magic Camera
//
//  DEPRECATED / UNWIRED (2026-07-02): the octree + nearest-point-field mesher this
//  drives shattered on real LiDAR room scans — sparse coarse leaves found no points
//  so the field returned its "outside" sentinel and marching cubes left holes, and
//  noisy walls never coarsened (variation stayed above the curvature threshold). The
//  live variable-resolution path instead reconstructs with the proven
//  SmoothSurfaceReconstructor and coarsens flats via SurfaceCleanup's adaptiveDecimate
//  (kept sharp by AreaProportionalAtlas). This file + AdaptiveOctree + AdaptiveMesher
//  are kept only for reference and are safe to delete; reviving them needs a smooth
//  (Gaussian/TSDF) field, not nearest-point.
//
//  Variable-resolution surface reconstruction — the opt-in alternative to the
//  uniform SmoothSurfaceReconstructor. It wires the three isolated pieces
//  together: an AdaptiveOctree partitions the cloud fine where the surface curves
//  and coarse on flats, an AdaptiveMesher marching-cubes each resolution level and
//  welds them, and the signed field is the oriented cloud's nearest-point distance
//  (the recorder's fusion rays give a globally consistent sign). The matching
//  area-proportional texture atlas keeps the big flat leaves sharp — without it the
//  variable geometry would blur, which is why all three ship together.
//
//  Off the main thread, ARKit-free. Cell bounds derive from the point spacing so
//  the finest cells never fall below what the scan density supports (sub-spacing
//  cells hole the mesh). Returns nil when the cloud is too sparse to mesh.
//

import simd

enum AdaptiveSurfaceReconstructor {
    struct Result {
        var mesh: MeshData
        /// One-line diagnostics (octree leaves / size range / fine count · tris).
        var summary: String
    }

    /// Reconstructs `cloud` at variable resolution. `normals` must be index-aligned
    /// to the cloud and consistently oriented outward (makeQuickModel supplies the
    /// negated fusion rays). `minCell` / `maxCell` default to the point-density
    /// limit and a coarse multiple of it; `curvatureThreshold` is the surface-
    /// variation level above which a cell keeps subdividing. Nil when too sparse.
    static func reconstruct(_ cloud: PointCloud,
                            normals: [SIMD3<Float>],
                            minCell: Float? = nil,
                            maxCell: Float? = nil,
                            curvatureThreshold: Float = 0.04) -> Result? {
        guard cloud.count >= 100, normals.count == cloud.count else { return nil }

        // Cell bounds from the point spacing: the finest cell sits at ~1.3× spacing
        // (the same anti-hole floor the uniform surface path uses); the coarsest a
        // few times larger, so a flat wall settles into a handful of big leaves.
        let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
        let minC = max(minCell ?? spacing * 1.3, 0.004)
        let maxC = max(maxCell ?? minC * 6, minC)

        let octree = AdaptiveOctree.partition(cloud, minCell: minC, maxCell: maxC,
                                              curvatureThreshold: curvatureThreshold)
        guard !octree.leaves.isEmpty else { return nil }

        // Nearest-point signed field. Its lookup cell must comfortably exceed the
        // coarsest leaf so a big leaf's corners still find the cloud points inside
        // it — the 3×3×3 hash search spans ±cell, and a corner can sit up to
        // maxCell·√3 from a same-leaf point, so 2× maxCell guarantees coverage. A
        // smaller cell would read empty at those corners and hole the flat regions.
        let field = AdaptiveMesher.NearestPointField(positions: cloud.positions,
                                                     normals: normals, cell: maxC * 2)
        guard let mesh = AdaptiveMesher.mesh(octree, sdf: { field.value(at: $0) }),
              !mesh.isEmpty else { return nil }
        return Result(mesh: mesh, summary: "\(octree.summary) · tris \(mesh.triangleCount)")
    }
}
