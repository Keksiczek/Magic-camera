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
//  (An adaptive decimation step used to follow — flat walls collapsed to a few big
//  triangles. It was dropped: the per-triangle texture atlas gives every triangle a
//  fixed-size chart, so a big wall triangle got too few texels and the wall texture
//  went soft/blurry. The uniform `cappedForBake` decimation before the bake spreads
//  triangles evenly instead, keeping the texture sharp. MeshDecimator.adaptiveDecimate
//  is still available for a geometry-only / export use where texel budget isn't the
//  constraint.)
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

    /// Cleans an open surface mesh: light denoise + flatten the large planes
    /// (walls / floor). `baseResolution` is kept for API stability (callers pass
    /// the reconstruction resolution) but no longer drives a decimation — that
    /// step blurred textures (see the header note).
    static func clean(_ mesh: MeshData, baseResolution: Int = 160) -> Result {
        _ = baseResolution
        let trisBefore = mesh.triangleCount
        // Too small to bother (below the planar guard anyway).
        guard trisBefore >= 200 else {
            return Result(mesh: mesh, planes: 0, tolerance: 0,
                          trisBefore: trisBefore, trisAfter: trisBefore)
        }
        let denoised = MeshOptimizer.smooth(mesh, iterations: 2)
        let (flattened, planes, tolerance) = MeshPlanarRegularizer.regularize(denoised)
        return Result(mesh: flattened, planes: planes, tolerance: tolerance,
                      trisBefore: trisBefore, trisAfter: flattened.triangleCount)
    }
}
