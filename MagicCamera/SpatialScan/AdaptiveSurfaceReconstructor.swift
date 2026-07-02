//
//  AdaptiveSurfaceReconstructor.swift
//  Magic Camera
//
//  Variable-resolution ("true adaptive") surface reconstruction — the opt-in
//  alternative to the uniform SmoothSurfaceReconstructor. It wires the three pieces:
//  an AdaptiveOctree partitions the cloud fine where the surface curves (objects) and
//  coarse on the flats (walls), an AdaptiveMesher marching-cubes each resolution level
//  and welds + stitches them, and a smooth, density-adaptive signed field (Gaussian-
//  weighted, oriented by the recorder's fusion rays) supplies the iso-surface. The
//  matching area-proportional texture atlas keeps the big flat leaves sharp.
//
//  (A first attempt used a nearest-point field and shattered on real LiDAR — sparse
//  coarse leaves returned an "outside" sentinel so marching cubes left holes + spurious
//  fragments. AdaptiveMesher.SmoothField fixes that: it averages over neighbours for a
//  continuous field and expands its search in sparse regions so a far wall still
//  resolves solid, returning nil only where there are genuinely no points.)
//
//  Off the main thread, ARKit-free. Cell bounds derive from the point spacing so the
//  finest cells match what the scan density supports. Returns nil when too sparse.
//

import simd

enum AdaptiveSurfaceReconstructor {
    struct Result {
        var mesh: MeshData
        /// One-line diagnostics (octree leaves / size range / fine count · tris).
        var summary: String
    }

    /// Reconstructs `cloud` at variable resolution. `normals` must be index-aligned to
    /// the cloud and consistently oriented outward (makeQuickModel supplies the negated
    /// fusion rays). `minCell` / `maxCell` default to the point-density limit and a
    /// coarse multiple of it; `flatnessTolerance` is the plane-residual (metres) below
    /// which a cell stops subdividing. Nil when too sparse.
    static func reconstruct(_ cloud: PointCloud,
                            normals: [SIMD3<Float>],
                            minCell: Float? = nil,
                            maxCell: Float? = nil,
                            flatnessTolerance: Float = 0.02) -> Result? {
        guard cloud.count >= 100, normals.count == cloud.count else { return nil }

        // Cell bounds from the point spacing: the finest cell at ~1.3× spacing (the
        // detail limit the scan supports), the coarsest several times larger so a flat
        // wall settles into a handful of big leaves.
        let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
        let minC = max(minCell ?? spacing * 1.3, 0.004)
        let maxC = max(maxCell ?? minC * 6, minC)

        let octree = AdaptiveOctree.partition(cloud, minCell: minC, maxCell: maxC,
                                              flatnessTolerance: flatnessTolerance)
        guard !octree.leaves.isEmpty else { return nil }

        // Smooth, density-adaptive field: hash cell = the fine spacing, search reach
        // 2× the coarsest cell so even a big leaf's corners find points (and go
        // undefined — not sentinel-"outside" — only in a genuine gap).
        let field = AdaptiveMesher.SmoothField(positions: cloud.positions, normals: normals,
                                               cell: minC, maxSupport: maxC * 2)
        guard let mesh = AdaptiveMesher.mesh(octree, sdf: { field.value(at: $0) }),
              !mesh.isEmpty else { return nil }
        return Result(mesh: mesh, summary: "\(octree.summary) · tris \(mesh.triangleCount)")
    }
}
