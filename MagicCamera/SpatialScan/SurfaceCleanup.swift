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
//    3. Adaptive decimation — flat regions become a few big triangles, curved
//       detail keeps its density, so triangle size follows the geometry instead
//       of being uniform everywhere (and the lighter mesh bakes faster).
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
        var trisBefore: Int
        var trisAfter: Int
        /// One-line diagnostics summary (`planes N · tris A→B`).
        var summary: String { "planes \(planes) · tris \(trisBefore)→\(trisAfter)" }
    }

    /// Cleans an open surface mesh. `baseResolution` is the reconstruction's fine
    /// grid resolution — it sets the *detail* density the adaptive decimation
    /// preserves, so the output never gets coarser than the scan supports.
    static func clean(_ mesh: MeshData, baseResolution: Int = 160) -> Result {
        let trisBefore = mesh.triangleCount
        // Too small to bother (and below the planar/decimation guards anyway).
        guard trisBefore >= 200 else {
            return Result(mesh: mesh, planes: 0, trisBefore: trisBefore, trisAfter: trisBefore)
        }
        let denoised = MeshOptimizer.smooth(mesh, iterations: 2)
        let (flattened, planes) = MeshPlanarRegularizer.regularize(denoised)
        let progressive = MeshDecimator.adaptiveDecimate(flattened, baseResolution: baseResolution)
        // Guard against a decimation that somehow gutted the mesh — keep the
        // flattened (un-decimated) result rather than shipping a sliver.
        let final = progressive.triangleCount >= trisBefore / 8 ? progressive : flattened
        return Result(mesh: final, planes: planes,
                      trisBefore: trisBefore, trisAfter: final.triangleCount)
    }
}
