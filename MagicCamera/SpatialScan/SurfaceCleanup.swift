//
//  SurfaceCleanup.swift
//  Magic Camera
//
//  Turns a raw marching-cubes surface into a clean, progressive one — the
//  automatic finish applied to room/area ("Textured surface") scans so the model
//  comes out looking intentional without the user reaching for any tool:
//
//    1. Light Taubin denoise — sheds the high-frequency LiDAR noise that makes a
//       fresh surface look pebbled (boundary rim pinned, so it stays crisp).
//    2. Planar regularisation — snaps walls / floor / ceiling flat, killing the
//       wavy "bumps" the reconstruction bakes from a noisy cloud.
//
//    3. Optional variable-resolution coarsening (adaptiveDecimate, opt-in) — the
//       now-flattened flat walls collapse to a few big triangles while detail keeps
//       its density. This was dropped once because the uniform atlas starved big
//       triangles of texels and blurred the walls; it's back, gated on the
//       "Variable-resolution surfaces" flag, because the area-proportional atlas now
//       sizes each triangle's chart by its area, so a big wall triangle stays sharp.
//       (The alternative — an octree + nearest-point mesher — shattered on real
//       LiDAR noise; smooth-reconstruct then decimate reuses the proven surface.)
//
//  Scene-safe: an organic shape with no large plane sails through the planar step
//  untouched, and anything below a small triangle floor is returned as-is. Pure
//  value math, ARKit-free — runs off the main thread.
//

import simd

enum SurfaceCleanup {
    struct Result {
        var mesh: MeshData
        var planes: Int
        /// The size-scaled RANSAC tolerance the regulariser used (m) — surfaced so a
        /// device diagnostic shows whether a big scan actually relaxed the tolerance.
        var tolerance: Float
        var trisBefore: Int
        var trisAfter: Int
        /// One-line diagnostics summary (`planes N · tol Xcm · tris A→B`).
        var summary: String {
            "planes \(planes) · tol \(String(format: "%.1f", tolerance * 100))cm · tris \(trisBefore)→\(trisAfter)"
        }
    }

    /// Cleans an open surface mesh: light denoise → flatten the large planes
    /// (walls / floor) → optional variable-resolution coarsening.
    ///
    /// - baseResolution: the reconstruction resolution the coarsening levels off.
    /// - adaptiveDecimate: when true (the opt-in "Variable-resolution surfaces"
    ///   path), coarsen the flattened flat regions to big triangles. Only paired
    ///   with the area-proportional atlas, which keeps those big triangles sharp.
    static func clean(_ mesh: MeshData, baseResolution: Int = 160,
                      adaptiveDecimate: Bool = false) -> Result {
        let trisBefore = mesh.triangleCount
        // Too small to bother (below the planar guard anyway).
        guard trisBefore >= 200 else {
            return Result(mesh: mesh, planes: 0, tolerance: 0,
                          trisBefore: trisBefore, trisAfter: trisBefore)
        }
        let denoised = MeshOptimizer.smooth(mesh, iterations: 2)
        let regularized = MeshPlanarRegularizer.regularize(denoised)
        var flattened = regularized.mesh
        // Coarsen after the walls are flat, so the flatness signal is clean: flat
        // regions collapse to big triangles, detail keeps its density. Nested
        // power-of-two cells → crack-free. Gated (needs the area-proportional atlas).
        if adaptiveDecimate {
            let coarsened = MeshDecimator.adaptiveDecimate(flattened, baseResolution: baseResolution)
            if !coarsened.isEmpty { flattened = coarsened }
        }
        return Result(mesh: flattened, planes: regularized.planes, tolerance: regularized.tolerance,
                      trisBefore: trisBefore, trisAfter: flattened.triangleCount)
    }
}
