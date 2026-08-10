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
        /// How many of `planes` came from ARKit plane anchors captured during the
        /// sweep (vs found by RANSAC) — the "did the seeding engage" diagnostic.
        var seeded: Int
        /// Seeds the bird's-eye density map supplied because the sweep carried
        /// (almost) no anchors — counted separately so a device diagnostic shows
        /// which source actually fed the flattening.
        var bevSeeds: Int = 0
        /// The size-scaled RANSAC tolerance the regulariser used (m) — surfaced so a
        /// device diagnostic shows whether a big scan actually relaxed the tolerance.
        var tolerance: Float
        /// How many of `planes` the Manhattan step locked onto the room's orthogonal
        /// frame — the "did the squaring engage" diagnostic (planes further than 20°
        /// off an axis are deliberately left alone).
        var locked: Int
        var trisBefore: Int
        var trisAfter: Int
        /// One-line diagnostics summary
        /// (`planes N (M seeded, K bev, L manhattan) · tol Xcm · tris A→B`).
        var summary: String {
            "planes \(planes) (\(seeded) seeded, \(bevSeeds) bev, \(locked) manhattan)"
                + " · tol \(String(format: "%.1f", tolerance * 100))cm"
                + " · tris \(trisBefore)→\(trisAfter)"
        }
    }

    /// Cleans an open surface mesh: light denoise → flatten the large planes
    /// (walls / floor) → optional variable-resolution coarsening.
    ///
    /// - baseResolution: the reconstruction resolution the coarsening levels off.
    /// - adaptiveDecimate: when true (the opt-in "Variable-resolution surfaces"
    ///   path), coarsen the flattened flat regions to big triangles. Only paired
    ///   with the area-proportional atlas, which keeps those big triangles sharp.
    /// - flattenPlanes: run the planar regulariser. TRUE for a scene, FALSE for a
    ///   subject. The step flattens the large planes of a *room*, and it is
    ///   self-gating only while the mesh is a room: an organic shape with no large
    ///   plane sails through, but a shallow one does not, because a shallow shape
    ///   IS a large plane. An Object scan of a small lamp reached it as a dished
    ///   patch — isolation had already cut the lamp down to the top of itself —
    ///   one plane claimed the lot, and the delivered model was a 108 × 125 mm
    ///   rectangle 1 mm thick, 99.8% of its area in that plane. No inlier cap can
    ///   separate these cases: geometrically a lone wall and a lamp's shade are
    ///   the same mesh. What differs is what the user was scanning.
    static func clean(_ mesh: MeshData, baseResolution: Int = 160,
                      adaptiveDecimate: Bool = false,
                      seedPlanes: [SeedPlane] = [],
                      flattenPlanes: Bool = true) -> Result {
        let trisBefore = mesh.triangleCount
        // Too small to bother (below the planar guard anyway).
        guard trisBefore >= 200 else {
            return Result(mesh: mesh, planes: 0, seeded: 0, tolerance: 0, locked: 0,
                          trisBefore: trisBefore, trisAfter: trisBefore)
        }
        // One Taubin pass, not two: the reconstruction is already smooth, and the
        // second pass rounded off the relief the user wants kept ("mazlavé"). One
        // pass still sheds the high-frequency pebbling; the planar step handles walls.
        let denoised = MeshOptimizer.smooth(mesh, iterations: 1)
        // A sweep that carried no plane anchors (a plain point scan, or a room
        // ARKit never resolved a wall in) used to hand the regulariser nothing,
        // leaving it to guess walls from random RANSAC triples. Fall back to the
        // bird's-eye density map: dense, full-height columns in a straight run
        // are a wall, geometrically, with no classification needed. Only when the
        // anchors are genuinely thin — a sweep with real anchors keeps them, they
        // are the better evidence.
        guard flattenPlanes else {
            return Result(mesh: denoised, planes: 0, seeded: 0, tolerance: 0, locked: 0,
                          trisBefore: trisBefore, trisAfter: denoised.triangleCount)
        }
        let bevSeeds = seedPlanes.count >= 2
            ? []
            : (OccupancyGrid.build(from: denoised.vertices)?.wallSeeds() ?? [])
        let regularized = MeshPlanarRegularizer.regularize(denoised,
                                                           seeds: seedPlanes + bevSeeds)
        var flattened = regularized.mesh
        // Coarsen after the walls are flat, so the flatness signal is clean: flat
        // regions collapse to big triangles, detail keeps its density. Nested
        // power-of-two cells → crack-free. Gated (needs the area-proportional atlas).
        if adaptiveDecimate {
            let coarsened = MeshDecimator.adaptiveDecimate(flattened, baseResolution: baseResolution)
            if !coarsened.isEmpty { flattened = coarsened }
        }
        return Result(mesh: flattened, planes: regularized.planes, seeded: regularized.seeded,
                      bevSeeds: bevSeeds.count,
                      tolerance: regularized.tolerance, locked: regularized.locked,
                      trisBefore: trisBefore, trisAfter: flattened.triangleCount)
    }
}
