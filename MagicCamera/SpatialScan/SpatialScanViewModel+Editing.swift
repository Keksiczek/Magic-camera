//
//  SpatialScanViewModel+Editing.swift
//  Magic Camera
//
//  Review-time editing operations — every one runs its heavy work on a
//  detached background task and reports back through the observable state.
//

import SwiftUI

extension SpatialScanViewModel {

    /// Hard triangle ceiling for the per-triangle photo bake. The bake cost (and
    /// its atlas size) scales with triangles, and on a big un-isolated surface it
    /// ran for minutes — long enough to trip the ~90 s CPU-resource watchdog (seen
    /// as MetricKit cpu_resource exceptions on device). Any mesh over this is
    /// decimated first (`cappedForBake`); the texture carries the visual detail, so
    /// the result looks the same but bakes in bounded time. Isolated objects stay
    /// well under it, so they're never touched.
    nonisolated static let photoBakeTriangleBudget = 80_000
    /// The variable-resolution path affords more: its budget is spent by the
    /// curvature-aware decimation (flats stay cheap, the extra triangles all go
    /// to detail), the GPU bake's cost scales with atlas texels not triangles,
    /// and the area-proportional atlas assigns texels by area — so more detail
    /// triangles subdivide the same texel share instead of diluting it.
    nonisolated static let adaptiveBakeTriangleBudget = 120_000

    /// Decimates `mesh` until it fits `budget` triangles, coarsening the cluster
    /// grid until it does (or a floor is hit). Vertex-clustering decimation
    /// self-heals soup/atlas geometry (see [[soup-mesh-weld-rule]]), so it's safe
    /// to run on any mesh. A no-op when already under budget. Off-main, pure value
    /// math — bounds the heaviest review-time op so it can't run the CPU watchdog.
    nonisolated static func cappedForBake(_ mesh: MeshData, budget: Int) -> MeshData {
        guard mesh.triangleCount > budget else { return mesh }
        var result = mesh
        var grid = 140
        while result.triangleCount > budget && grid >= 48 {
            result = MeshDecimator.decimate(mesh, gridResolution: grid)
            grid -= 24
        }
        return result
    }

    /// Bake budget for the variable-resolution path. The uniform `cappedForBake`
    /// grid-clusters everything equally, which re-coarsens exactly the fine detail
    /// the adaptive pipeline just preserved and spends the removal where it shows;
    /// here the budget is met by re-running the curvature-aware decimation at
    /// progressively coarser bases (flats collapse further, detail keeps its
    /// density), with the planes re-snapped afterwards (self-gating — a no-op on
    /// organic shapes). Falls back to the uniform cap if the adaptive loop stalls,
    /// because the bound itself is the CPU-watchdog guarantee and must hold.
    nonisolated static func boundedForBake(_ mesh: MeshData, budget: Int,
                                           preservingDetail: Bool) -> MeshData {
        guard mesh.triangleCount > budget else { return mesh }
        guard preservingDetail else { return cappedForBake(mesh, budget: budget) }
        var result = mesh
        var base = 160
        while result.triangleCount > budget && base >= 24 {
            let coarsened = MeshDecimator.adaptiveDecimate(mesh, baseResolution: base)
            if coarsened.isEmpty { break }
            result = coarsened
            base = base * 3 / 4
        }
        if result.triangleCount > budget {
            result = cappedForBake(result, budget: budget)
        }
        return MeshPlanarRegularizer.regularize(result).mesh
    }

    /// Closes the small interior pinholes reconstruction can still leave on the
    /// variable-resolution path (a cell whose corner sits in a genuine data gap is
    /// skipped, and edge trimming can nick a marginal triangle) while leaving every
    /// real opening alone: only loops that are both short (≤ 96 edges) and
    /// physically small (≤ 1.5 m around) qualify — a window is ≥ 3 m of perimeter
    /// and a doorway ≥ 5 m, so those and the outer scan boundary never close.
    nonisolated static func fillingInteriorPinholes(_ mesh: MeshData) -> MeshData {
        let before = mesh.indices.count
        let filled = MeshHoleFiller.fill(mesh, maxHoleEdges: 96) { loop, vertices in
            var perimeter: Float = 0
            for (i, v) in loop.enumerated() {
                let next = vertices[Int(loop[(i + 1) % loop.count])]
                perimeter += simd_distance(vertices[Int(v)], next)
            }
            return perimeter <= 1.5
        }
        let added = (filled.indices.count - before) / 3
        if added > 0 {
            Diagnostics.shared.log("solid fill", "+\(added) tris · pinholes ≤1.5m")
        }
        return filled
    }

    /// Lattice resolution driven by the cloud's actual point density instead of a
    /// flat detail tier: a fixed tier divided a whole room's extent into coarse
    /// cells regardless of how densely it was scanned, so "changing detail barely
    /// helped". Here the cell size tracks the sampled surface density — finer where
    /// the scan is dense — capped by `cap` (per tier) so a large dense cloud can't
    /// blow the CPU/memory watchdog. Uses a cheap surface-area/count spacing
    /// estimate (O(1) after the bounding box) rather than a kd-tree pass, which on
    /// a multi-million-point cloud is exactly what tripped the watchdog before.
    nonisolated static func densityResolution(for cloud: PointCloud,
                                              fallback: Int, cap: Int) -> Int {
        guard cloud.count > 0, let box = cloud.boundingBox() else { return min(fallback, cap) }
        let extent = box.max - box.min
        let maxExtent = max(extent.x, extent.y, extent.z, 0.01)
        let area = max(2 * (extent.x * extent.y + extent.y * extent.z + extent.x * extent.z), 1e-4)
        let spacing = (area / Float(cloud.count)).squareRoot()
        let supported = Int((maxExtent / max(spacing * 1.4, 1e-4)).rounded())
        return max(24, min(supported, cap))
    }

    /// True when a cloud is essentially a flat sheet — its thinnest extent is a
    /// tiny fraction of its largest. Used to catch isolation collapsing a 3-D
    /// subject to a floor-parallel slice (the squashed-model bug).
    nonisolated static func isFlat(_ cloud: PointCloud) -> Bool {
        guard let box = cloud.boundingBox() else { return false }
        let e = box.max - box.min
        let dims = [e.x, e.y, e.z].sorted()
        return dims[2] > 0.03 && dims[0] < dims[2] * 0.15
    }

    /// Recovers index-aligned view directions for a cloud that is a pure subset
    /// of `source`. The masking / isolation steps (`SurfaceMask.cleaned`,
    /// `KeyframeSubjectFilter.filter`, `PointCloudSegmenter.isolateMainSubject`)
    /// only ever *remove* points — they append `source.positions[i]` verbatim —
    /// so every kept point still sits at its original position and its measured
    /// camera direction can be looked up by position. That is what lets the
    /// one-tap model reuse Fusion's view rays (the robust outward orientation
    /// Build Surface uses) even though isolation returns a fresh cloud with no
    /// index map. Returns nil — caller falls back to estimated normals — when the
    /// source has no usable rays or, defensively, when most points fail to match
    /// (the subset assumption broke, e.g. a transformed cloud).
    nonisolated static func recoverViewDirections(for subset: PointCloud,
                                                  from source: PointCloud,
                                                  directions: [SIMD3<Float>]?) -> [SIMD3<Float>]? {
        guard let directions, directions.count == source.count,
              source.count > 0, subset.count > 0 else { return nil }
        // Manual / surface mode passes the cloud through verbatim — already aligned.
        if subset.count == source.count { return directions }
        guard let box = source.boundingBox() else { return nil }

        // Cheap density-derived cell (no kd-tree / grid pass): ~one source point
        // per cell on average, so the 3×3×3 search around each subset point finds
        // its verbatim copy at distance ~0.
        let extent = box.max - box.min
        let volume = max(extent.x, 0.005) * max(extent.y, 0.005) * max(extent.z, 0.005)
        let cell = max(cbrtf(volume / Float(source.count)) * 1.5, 1e-4)
        @inline(__always) func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        buckets.reserveCapacity(source.count)
        for i in 0..<source.count { buckets[key(source.positions[i]), default: []].append(i) }

        var out = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, -1), count: subset.count)
        var matched = 0
        for i in 0..<subset.count {
            let p = subset.positions[i]
            let base = key(p)
            var bestD = Float.infinity
            var bestIdx = -1
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        guard let bucket = buckets[base &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                        for idx in bucket {
                            let d = simd_distance_squared(source.positions[idx], p)
                            if d < bestD { bestD = d; bestIdx = idx }
                        }
                    }
                }
            }
            if bestIdx >= 0 {
                out[i] = directions[bestIdx]
                if bestD <= cell * cell { matched += 1 }
            }
        }
        // A genuine subset matches (almost) every point at distance ~0; if it
        // doesn't, the positions were moved and the rays no longer apply.
        guard matched >= (subset.count * 9) / 10 else { return nil }
        return out
    }

    // MARK: - Surface reconstruction (point cloud → mesh)

    /// Reconstructs a surface mesh from the captured cloud on a background task
    /// using the selected method (voxel / Poisson-style smooth / ball-pivoting),
    /// then switches the review over to the mesh (with its AR / export tooling).
    /// The source cloud is kept aside as the colour source for texture baking.
    func reconstructMesh(thenFinish: Bool = false) {
        guard let cloud = capturedCloud else { return }
        let cloudBox = UncheckedSendableBox(cloud)
        let normalsBox = UncheckedSendableBox(capturedCloudNormals)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let scenePlanesBox = UncheckedSendableBox(capturedScenePlanes)
        let resolution = reconstructDetail.resolution
        let detailCap = reconstructDetail.densityCap
        let method = reconstructMethod
        let prepass = adaptiveDensityPrepass
        runOperation(.reconstructing,
                     startingToast: "Reconstructing surface…",
                     failureToast: "Couldn't build a surface — scan more densely")
        { () -> MeshData? in
            var cloud = cloudBox.value
            var normals = normalsBox.value
            var directions = directionsBox.value
            // Drop the least-reliable points first: low fused confidence is where
            // bleed/ghosts that survived carving sit, and they pull the surface.
            // Carry normals/rays through the same subsample; guarded so a
            // low-confidence scan isn't gutted.
            let confident = cloud.confidentIndices(min: 0.25)
            if confident.count >= 100, confident.count < cloud.count,
               Float(confident.count) >= Float(cloud.count) * 0.6 {
                if let n = normals, n.count == cloud.count { normals = confident.map { n[$0] } }
                if let d = directions, d.count == cloud.count { directions = confident.map { d[$0] } }
                cloud = cloud.subset(confident)
            }
            // Density-driven resolution: size the lattice from the cloud's actual
            // point density so the mesh is as fine as the scan supports — a flat
            // tier coarsened a whole room uniformly ("changing detail barely
            // helped"). Bounded by the tier's densityCap to stay off the watchdog.
            let effectiveResolution = SpatialScanViewModel.densityResolution(
                for: cloud, fallback: resolution + 16, cap: detailCap)
            // Hard bound first: a room-scale cloud (millions of points) fed
            // straight into normal estimation + the signed field is what tripped
            // the CPU/memory watchdog. Keep one representative point per
            // half-cell — the surface is unchanged but the job becomes finite —
            // and carry normals/rays through the same subsample so Fusion's rays
            // stay valid. The caller keeps the full cloud as the colour source.
            let sample = cloud.reconstructionSampleIndices(resolution: effectiveResolution)
            if sample.count >= 100 && sample.count < cloud.count {
                if let n = normals, n.count == cloud.count { normals = sample.map { n[$0] } }
                if let d = directions, d.count == cloud.count { directions = sample.map { d[$0] } }
                cloud = cloud.subset(sample)
            }
            if Task.isCancelled { return nil }
            // Optional curvature pre-pass: thin flat regions before meshing,
            // carrying the index-aligned normals/directions through the same
            // subsample so Fusion's rays stay valid.
            if prepass, cloud.count > 2_000,
               let spacing = BallPivotingMesher.meanSpacing(cloud.positions) {
                let curvature = PointCloudCurvature.estimate(cloud)
                let kept = PointCloudAdaptiveDownsampler.keptIndices(
                    cloud, curvatures: curvature, spacing: spacing)
                if kept.count >= 1_000 && kept.count < cloud.count {
                    if let n = normals, n.count == cloud.count { normals = kept.map { n[$0] } }
                    if let d = directions, d.count == cloud.count { directions = kept.map { d[$0] } }
                    cloud = cloud.subset(kept)
                }
            }
            if Task.isCancelled { return nil }
            // Shed the flying-pixel bleed halo before meshing — same as the one-tap
            // model. Build Surface skipped this, so it kept all the silhouette/shake
            // floaters ("still some bleed" on a Build-Surface result). Statistical
            // outlier removal drops sparse-neighbourhood points (it keeps dense
            // disconnected geometry, so it's safe on multi-object scenes); rays
            // re-align by position, normals re-estimate on the denoised cloud.
            if cloud.count > 1_000 {
                var denoised = PointCloudDenoiser.removeOutliers(cloud, neighbors: 8, stdRatio: 1.5)
                // Then shed detached flying-pixel blobs SOR keeps (it preserves
                // dense disconnected geometry), before reconstruction bridges them
                // into the surface where mesh small-component removal can't reach.
                denoised = PointCloudSegmenter.removeStrayClusters(denoised)
                if denoised.count >= 1_000, denoised.count < cloud.count {
                    directions = SpatialScanViewModel.recoverViewDirections(
                        for: denoised, from: cloud, directions: directions)
                    normals = nil   // re-estimated by meshNormals() on the denoised cloud
                    cloud = denoised
                }
            }
            if Task.isCancelled { return nil }
            // Surface methods need oriented normals. Re-orient supplied
            // normals (or estimate fresh) *consistently* via the MST
            // flood-fill — independently-flipped normals tear ball-pivot and
            // pock the signed-field smooth surface. Computed once, lazily.
            func meshNormals() -> [SIMD3<Float>] {
                if let n = normals, n.count == cloud.count {
                    return PointCloudNormals.orientConsistently(n, positions: cloud.positions)
                }
                return PointCloudNormals.estimateConsistent(cloud)
            }
            let built: MeshData?
            switch method {
            case .voxel:
                built = PointCloudMesher.reconstruct(cloud, resolution: min(resolution, effectiveResolution))
            case .smooth:
                built = SmoothSurfaceReconstructor.reconstruct(
                    cloud, resolution: effectiveResolution, normals: meshNormals(),
                    adaptiveSupport: ReconstructionSettings.adaptiveEnabled)
            case .ballPivot:
                built = BallPivotingMesher.reconstruct(cloud, normals: meshNormals())
            case .fusion:
                // Ray-carved TSDF: the recorder's measured view rays replace
                // estimated normals in the signed field — the outward side is
                // simply "toward the camera that saw the point". Falls back
                // to consistently-oriented estimated normals when the rays
                // are gone (edited / gallery-loaded clouds).
                if let directions, directions.count == cloud.count {
                    built = SmoothSurfaceReconstructor.reconstruct(
                        cloud, resolution: effectiveResolution,
                        normals: directions.map { -$0 },
                        adaptiveSupport: ReconstructionSettings.adaptiveEnabled)
                } else {
                    built = SmoothSurfaceReconstructor.reconstruct(
                        cloud, resolution: effectiveResolution, normals: meshNormals(),
                        adaptiveSupport: ReconstructionSettings.adaptiveEnabled)
                }
            }
            // Drop the disconnected floaters reconstruction leaves around the
            // surface (the bleed bubbles the SOR above didn't catch). Build Surface
            // kept these; the one-tap model already strips them. Stays open — no
            // base capping here, that's the model path.
            guard let built, !built.isEmpty else { return built }
            var assembled = built.removingSmallComponents().trimmingLongEdges()
            if ReconstructionSettings.adaptiveEnabled {
                assembled = assembled.erodingBoundaryFlakes()
                assembled = Self.fillingInteriorPinholes(assembled)
            }
            if Task.isCancelled { return nil }
            // Same automatic clean finish as the one-tap surface: flatten walls,
            // denoise, make triangle density adaptive. Self-gating on organic shapes.
            let cleaned = SurfaceCleanup.clean(assembled, baseResolution: effectiveResolution,
                                               adaptiveDecimate: ReconstructionSettings.adaptiveEnabled,
                                               seedPlanes: scenePlanesBox.value)
            Diagnostics.shared.log("surface cleanup", cleaned.summary)
            return cleaned.mesh
        } completion: { [weak self, cloudBox] mesh in
            guard let self else { return }
            // A non-empty mesh is the only success; an empty one reads the same
            // as "couldn't build" (runOperation already handled the nil path).
            guard !mesh.isEmpty else {
                self.showToast("Couldn't build a surface — scan more densely")
                return
            }
            self.capturedCloud = nil
            self.textureSourceCloud = cloudBox.value
            self.capturedMesh = mesh
            self.removeStructure = false
            self.scanKind = .mesh
            self.meshColorMode = .shaded
            self.pointCount = mesh.triangleCount
            if thenFinish {
                // Chain the scene-aware finish so cloud review reaches a completed
                // model in one tap. endOperation already ran (runOperation ends the
                // op before this completion), so smartFinish's beginOperation succeeds.
                self.smartFinish()
            } else {
                self.showToast("Surface ready · \(mesh.triangleCount) tris")
            }
        }
    }

    // MARK: - One-tap model

    /// The whole pipeline in one tap: isolate the subject (floor removal +
    /// clustering, falling back to the full cloud when nothing isolates),
    /// reconstruct a smooth surface, and bake the texture (photos when
    /// keyframes exist, cloud colours otherwise).
    /// One-tap result from the cloud. `surface: false` → a clean, closed object
    /// (isolate the subject + cap the base); `surface: true` → an open textured
    /// surface kept as-is (rooms / outdoors, where there's nothing to close and
    /// you just want the textured geometry).
    func makeQuickModel(surface: Bool = false) {
        guard let cloud = capturedCloud else { return }
        let cloudBox = UncheckedSendableBox(cloud)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let keyframesBox = UncheckedSendableBox(textureKeyframes)
        let surfaceBox = UncheckedSendableBox(captureSceneMesh)
        let scenePlanes = capturedScenePlanes
        let resolution = reconstructDetail.resolution
        let prepass = adaptiveDensityPrepass
        let anchor = subjectAnchor   // the tapped subject, for trust-the-selection isolation
        let manual = userIsolated    // user already lassoed/cropped — skip auto isolation
        let cropTrusted = capturedSupportCropped   // capture already removed the support
        runOperation(surface ? .makingSurface : .makingModel,
                     startingToast: surface ? "Building textured surface…"
                        : (manual ? "Building model from your selection…" : "Making 3D model…"),
                     failureToast: "Couldn't build a model — scan more densely")
        { () -> (PointCloud, MeshData, TexturedMesh?)? in
            // ARKit scene-mesh cleanup first (floaters + classified floor), then
            // the photo-mask visual hull, then the geometric isolation.
            let isolated: PointCloud
            // Which isolation branch decided the input — surfaced in the `object
            // model` breadcrumb because every hard-subject failure so far (mat
            // kept, subject lost) came down to WHICH of these fired, and that was
            // invisible in the diagnostics.
            var isolationPath = "kept"
            // When the support plane was already cut at the cloud level, the
            // mesh-level base removal must NOT run again — on a mat-free subject
            // it would find the subject's own flattest feature and cut into it.
            var matCutApplied = false
            if manual || surface {
                // Manual lasso/crop pick, or surface mode (keep the whole open
                // scan) — trust it verbatim instead of re-running auto isolation.
                isolated = cloudBox.value
                isolationPath = manual ? "manual" : "whole"
            } else if cropTrusted {
                // The live support crop already removed the pad/table at capture:
                // the cloud IS the subject. Keep the bleed cleanups (mask + visual
                // hull) but skip the geometric isolation and every support lift —
                // re-guessing a clean cloud is what decimated the mouse/plate.
                let cleaned = SurfaceMask.cleaned(cloudBox.value, using: surfaceBox.value)
                isolated = KeyframeSubjectFilter.filter(
                    cleaned, keyframes: keyframesBox.value)?.cloud ?? cleaned
                isolationPath = "crop-trusted"
                matCutApplied = true   // support handled at capture → no mesh-level cut
            } else {
                let cleaned = SurfaceMask.cleaned(cloudBox.value, using: surfaceBox.value)
                let masked = KeyframeSubjectFilter.filter(cleaned,
                                                          keyframes: keyframesBox.value)?.cloud
                let working = masked ?? cleaned
                let cut = PointCloudSegmenter.isolateMainSubject(working, anchor: anchor)?.cloud
                    ?? working
                // Safety net against the "post-process squashes the model flat"
                // bug. Two failure modes, two different fixes:
                let gutted = cut.count < max(800, working.count / 5)
                if gutted {
                    // Isolation gutted the subject to a sliver (e.g. kept 1066 of
                    // 47689) — the masked cloud is the safer 3-D fallback. But the
                    // fallback still carries the support (the 07-03 mouse diag:
                    // `isolate gutted-fallback` = the pad bled into the model), so
                    // lift a clear support off it first; same guards as the other
                    // lift sites — a flat or tiny remainder keeps the fallback.
                    let up = SIMD3<Float>(0, 1, 0)
                    if let plane = PointCloudSegmenter.detectDominantPlane(
                        working, minInlierFraction: 0.25, up: up, horizontalBias: 0.8) {
                        let lifted = PointCloudSegmenter.removingPlaneAndBelow(
                            working, plane: plane, up: up)
                        let liftedOK = lifted.count > max(800, working.count / 10)
                            && !Self.isFlat(lifted)
                        isolated = liftedOK ? lifted : working
                        if liftedOK { isolationPath = "gutted-lift"; matCutApplied = true }
                        else { isolationPath = "gutted-fallback" }
                    } else {
                        isolated = working
                        isolationPath = "gutted-fallback"
                    }
                } else if Self.isFlat(cut) {
                    // The isolate came back flat. Reverting to `working` makes it
                    // WORSE: `working` still carries the support surface, so a
                    // top-down scan of an object on a flat mat/table reconstructs
                    // as a flat disc (the placemat dominates, the object collapses
                    // into it). Instead recognise the support and lift the object
                    // off it — detect the horizontal plane it rests on and drop
                    // that plane plus everything below. Only when a clear support
                    // plane is found and a real object stands on it; otherwise keep
                    // the isolate, never the mat-laden cloud.
                    let up = SIMD3<Float>(0, 1, 0)
                    if let plane = PointCloudSegmenter.detectDominantPlane(
                        working, minInlierFraction: 0.15, up: up, horizontalBias: 0.8) {
                        let lifted = PointCloudSegmenter.removingPlaneAndBelow(
                            working, plane: plane, up: up)
                        let liftedOK = lifted.count > max(800, working.count / 10)
                            && !Self.isFlat(lifted)
                        isolated = liftedOK ? lifted : cut
                        if liftedOK { isolationPath = "flat-lift"; matCutApplied = true }
                        else { isolationPath = "flat-kept" }
                    } else {
                        isolated = cut
                        isolationPath = "flat-kept"
                    }
                } else {
                    // Healthy isolate — but it can still carry the support disc
                    // (subject on a mat/table: the isolate keeps both, the mat
                    // dominates the mesh, and the mesh-level removingBasePlane
                    // then refuses to cut a majority — the "object still bleeds"
                    // case). When one horizontal plane holds ≥25% of the isolate
                    // and a substantial subject stands above it, lift it here at
                    // the cloud level. Flat subjects are safe: their own top IS
                    // the dominant plane, so the remainder fails the size guard
                    // and the isolate is kept unchanged.
                    let up = SIMD3<Float>(0, 1, 0)
                    if let plane = PointCloudSegmenter.detectDominantPlane(
                           cut, minInlierFraction: 0.25, up: up, horizontalBias: 0.8) {
                        let lifted = PointCloudSegmenter.removingPlaneAndBelow(
                            cut, plane: plane, up: up)
                        // A lift must free a substantial 3-D subject; a flat
                        // remainder means the plane cut kept the support (or a
                        // slice of it), not the subject — keep the isolate.
                        let liftedOK = lifted.count > max(800, cut.count / 6)
                            && !Self.isFlat(lifted)
                        isolated = liftedOK ? lifted : cut
                        if liftedOK { isolationPath = "mat-cut"; matCutApplied = true }
                    } else {
                        isolated = cut
                    }
                }
            }
            if Task.isCancelled { return nil }
            // Geometry runs on a bounded subsample (one point per half-cell);
            // the full `isolated` cloud stays the colour source so the texture
            // is unaffected. This is the cap that keeps a dense scan's one-tap
            // model off the CPU/memory watchdog. An optional curvature pre-pass
            // then thins flat regions further. Consistently-oriented normals
            // raise the smooth surface quality.
            var meshInput = isolated
            // Recover the recorder's measured view rays for the isolated subset.
            // Isolation/masking only remove points, so each kept point can be
            // matched back to its source direction; these give the same robust
            // outward orientation Build Surface uses (see `recoverViewDirections`).
            // nil for ray-less clouds (gallery-loaded / hand-edited) → estimated
            // normals below. Carried through every subsample, index-aligned.
            var directions = SpatialScanViewModel.recoverViewDirections(
                for: isolated, from: cloudBox.value, directions: directionsBox.value)
            // Drop the least-reliable points before meshing: low fused confidence
            // is where bleed/ghosts that survived carving sit, and they pull the
            // surface around. Guarded so a dark/glossy (low-confidence) scan isn't
            // gutted. `isolated` itself is kept full as the texture colour source.
            let confident = meshInput.confidentIndices(min: 0.25)
            if confident.count >= 100, confident.count < meshInput.count,
               Float(confident.count) >= Float(meshInput.count) * 0.6 {
                if let d = directions, d.count == meshInput.count { directions = confident.map { d[$0] } }
                meshInput = meshInput.subset(confident)
            }
            // Edge-preserving bilateral denoise on the DENSE cloud, BEFORE the
            // reconstruction subsample — here it has enough neighbours (~12 mm spacing)
            // to actually average out the ~1 cm LiDAR noise; denoising the coarse
            // subsampled cloud just smeared it. Range sigma is the absolute noise
            // (1.2 cm), so features above it survive; positions shift along the
            // fusion-ray normals, colours/rays untouched. Variable-resolution path only.
            if surface, ReconstructionSettings.adaptiveEnabled,
               let d = directions, d.count == meshInput.count, meshInput.count > 1_000,
               let spacing = BallPivotingMesher.meanSpacing(meshInput.positions), spacing > 0 {
                let sigmaS = min(spacing * 2.5, 0.03)
                let smoothed = PointCloudBilateralDenoiser.denoise(
                    meshInput.positions, normals: d.map { -$0 },
                    spatialSigma: sigmaS, rangeSigma: 0.012, iterations: 1)
                var rebuilt = PointCloud()
                rebuilt.reserveCapacity(smoothed.count)
                for i in 0..<smoothed.count {
                    rebuilt.append(position: smoothed[i], color: meshInput.colors[i],
                                   confidence: meshInput.confidences[i])
                }
                meshInput = rebuilt
                Diagnostics.shared.log("bilateral denoise",
                    "\(smoothed.count) pts · σs \(Int((sigmaS * 1000).rounded()))mm · σr 12mm")
                if Task.isCancelled { return nil }
            }
            let sample = meshInput.reconstructionSampleIndices(resolution: resolution + 16)
            if sample.count >= 100 && sample.count < meshInput.count {
                if let d = directions, d.count == meshInput.count { directions = sample.map { d[$0] } }
                meshInput = meshInput.subset(sample)
            }
            if prepass, meshInput.count > 2_000,
               let spacing = BallPivotingMesher.meanSpacing(meshInput.positions) {
                let curvature = PointCloudCurvature.estimate(meshInput)
                let kept = PointCloudAdaptiveDownsampler.keptIndices(
                    meshInput, curvatures: curvature, spacing: spacing)
                if kept.count >= 1_000 && kept.count < meshInput.count {
                    if let d = directions, d.count == meshInput.count { directions = kept.map { d[$0] } }
                    meshInput = meshInput.subset(kept)
                }
            }
            if Task.isCancelled { return nil }
            // Shed the hand-shake flying-pixel halo before meshing. On close object
            // scans ARKit holds the anchor steady (drift ≈ 0), so the residual
            // bleed is per-frame depth noise carving can't reach, not anchor drift.
            // Statistical outlier removal drops points whose neighbourhood is too
            // sparse to be real surface (isolated floaters always go); guarded so a
            // thin/sparse subject isn't gutted, and directions re-align by position
            // (a pure subset). The full `isolated` cloud stays the colour source.
            if meshInput.count > 1_000 {
                var denoised = PointCloudDenoiser.removeOutliers(meshInput, neighbors: 8, stdRatio: 1.5)
                // Shed detached flying-pixel blobs before they get bridged into the
                // surface (same de-snowstorm as Build Surface above).
                denoised = PointCloudSegmenter.removeStrayClusters(denoised)
                if denoised.count >= 1_000, denoised.count < meshInput.count {
                    directions = SpatialScanViewModel.recoverViewDirections(
                        for: denoised, from: meshInput, directions: directions)
                    meshInput = denoised
                }
            }
            if Task.isCancelled { return nil }
            // Surface orientation. Prefer the recorder's measured view rays — the
            // outward side is simply "toward the camera that saw the point"
            // (normal = −ray). They are globally consistent by construction, so
            // the signed field forms a closed volume; this is the robust path
            // Build Surface (reconstructMesh `.fusion`) uses, now shared here.
            // Only when the rays are gone (gallery-loaded / hand-edited cloud) fall
            // back to estimated normals — which on a hollow orbit shell can settle
            // on a globally inconsistent sign and collapse the field to a flat
            // sheet (the "post-process squashes the model" bug), so for objects we
            // coerce a consistent outward-from-centroid sign as the best fallback.
            let usedRays = (directions?.count == meshInput.count)
            let normals: [SIMD3<Float>]
            if let directions, directions.count == meshInput.count {
                normals = directions.map { -$0 }
            } else {
                var estimated = PointCloudNormals.estimateConsistent(meshInput)
                if !surface {
                    // Object only — a room/façade scanned from inside faces the
                    // other way, so outward-from-centroid would be wrong there.
                    let meshCentroid = meshInput.centroid()
                    for i in 0..<estimated.count
                    where simd_dot(estimated[i], meshInput.positions[i] - meshCentroid) < 0 {
                        estimated[i] = -estimated[i]
                    }
                }
                normals = estimated
            }
            // Variable-resolution surfaces (opt-in via Settings, surface only).
            let usedAdaptive = surface && ReconstructionSettings.adaptiveEnabled
            // Lattice resolution vs point density: fine cells over sparse points
            // interpolate into a holed, over-tessellated blob. Objects ≈1.5× the mean
            // spacing; the uniform surface path ≈1.3×. The variable-resolution path
            // runs ≈1.5× (finer than the old 2.5× solid-but-coarse base): the
            // bilateral denoise above handles the NOISE, and the reconstructor's
            // adaptiveSupport handles the SPARSITY (far walls 2-3× sparser than the
            // mean holed at 1.8× on device even after denoising — the two are
            // independent failure modes; 1.8× ran solid on device, 1.5× is the
            // detail step the user asked for on top of it). SurfaceCleanup coarsens the flats and the
            // area-proportional texture keeps the big wall triangles sharp.
            let spacingMul: Float = usedAdaptive ? 1.5 : (surface ? 1.3 : 1.5)
            // The adaptive path lets the DENSITY term below drive the lattice: a
            // 9.7 m outdoor scan with 1.8M points was capped at ~224 cells (43 mm)
            // by the fixed ceiling while its point spacing supported ~320 — the
            // "big scans come out coarse with illogical big triangles" report.
            // The density term and the reconstructor's band guard still bound it.
            var fineResolution = resolution + (usedAdaptive ? 128 : (surface ? 32 : 16))
            if let box = meshInput.boundingBox(),
               let spacing = BallPivotingMesher.meanSpacing(meshInput.positions), spacing > 0 {
                let extent = box.max - box.min
                let maxExtent = max(extent.x, extent.y, extent.z, 0.01)
                fineResolution = max(24, min(fineResolution, Int(maxExtent / (spacing * spacingMul))))
            }
            // Variable-resolution surfaces: reconstruct with the proven smooth
            // reconstructor (clean, hole-free) at the coarse-solid base, then let
            // SurfaceCleanup coarsen the flattened walls to big triangles kept sharp by
            // the area-proportional atlas. (A true-adaptive octree + smooth field was
            // tried and, on noisy LiDAR, meshed everything uniform-coarse at ~50 mm with
            // MORE, irregular triangles → softer texture + more facets than this. The
            // depth-noise floor caps meaningful geometric detail at ~cm, so the octree
            // couldn't actually go finer — texture carries the detail instead.)
            // adaptiveSupport: the fine (1.8×) lattice holes wherever the LOCAL
            // spacing exceeds the mean-derived cell — far walls of a big room. The
            // reconstructor now widens its band + field support just there (the
            // 07-02 device round: confetti holes across well-scanned walls), so
            // the surface stays solid at the finer base; denoise handles the
            // noise, this handles the sparsity. Windows stay open (no data at all).
            guard let reconstructed = SmoothSurfaceReconstructor.reconstruct(
                        meshInput, resolution: fineResolution, normals: normals,
                        adaptiveSupport: usedAdaptive)
                    ?? PointCloudMesher.reconstruct(meshInput, resolution: min(resolution, fineResolution)),
                  !reconstructed.isEmpty else { return nil }
            // Drop the floating blobs reconstruction leaves around the subject
            // before texturing, so the atlas isn't spent on specks in the air —
            // the snowstorm of disconnected bleed triangles that made "Textured
            // surface" look spoiled. This runs for surface mode too now: dropping
            // disconnected components keeps the open surface intact (it doesn't
            // close anything — that's `closeBase`, still model-only below), it just
            // removes the floaters. Model mode additionally caps the base.
            var mesh = reconstructed.removingSmallComponents().trimmingLongEdges()
            if Task.isCancelled { return nil }
            if usedAdaptive {
                mesh = mesh.erodingBoundaryFlakes()
                mesh = Self.fillingInteriorPinholes(mesh)
            }
            if surface {
                // Automatic clean finish for open surfaces: flatten the walls/floor,
                // shed reconstruction noise, and — on the variable-resolution path —
                // coarsen the flat regions to big triangles (kept sharp by the
                // area-proportional atlas). Self-gating — organic shapes with no large
                // plane pass through untouched. Object mode caps the base (below).
                let cleaned = SurfaceCleanup.clean(mesh, baseResolution: fineResolution,
                                                   adaptiveDecimate: usedAdaptive,
                                                   seedPlanes: scenePlanes)
                mesh = cleaned.mesh
                Diagnostics.shared.log("surface cleanup", cleaned.summary)
                if usedAdaptive {
                    // Plane snapping + decimation can leave slivers and small
                    // gaps of their own (the black triangle holes in the 07-03
                    // round-4 screenshot) — sweep them the same way as after
                    // reconstruction: drop slivers, close what that opened.
                    mesh = Self.fillingInteriorPinholes(mesh.trimmingLongEdges())
                }
            } else {
                // Shed the support surface the isolation kept (the mat/table disc
                // around the subject) — but only when the cloud-level lift did
                // NOT already cut it: running both cascades the guards (each is
                // individually safe, in sequence they can slice the subject's own
                // flattest feature). Self-gating: no clear horizontal support, or
                // removal would gut the mesh, returns it unchanged; then closeBase
                // seals the bottom the removal opened.
                // Never base-cut a thin/flat mesh either: a plate IS the
                // dominant horizontal plane, and cutting "below it" guts the
                // subject itself (the 350-tri plate).
                if !matCutApplied && !mesh.isThinOpenSurface {
                    mesh = mesh.removingBasePlane()
                }
                mesh = MeshHoleFiller.closeBase(mesh)
            }
            // Bound the per-triangle bake so it can't run for minutes and trip the
            // CPU watchdog. The whole un-isolated scan (surface mode) can mesh into
            // hundreds of thousands of triangles; the photo texture carries the
            // detail, so a decimated mesh looks the same but bakes in a fraction of
            // the time. Isolated objects are already small — a no-op for them.
            mesh = Self.boundedForBake(
                mesh,
                budget: usedAdaptive ? Self.adaptiveBakeTriangleBudget : Self.photoBakeTriangleBudget,
                preservingDetail: usedAdaptive)
            if Task.isCancelled { return nil }
            let textured: TexturedMesh?
            if keyframesBox.value.isEmpty {
                // Point-colour fallback — visibly softer than a photo bake. Logged
                // because a scan that HAD keyframes can lose them (they're not
                // persisted): the 07-03 object diag showed no multi-view/GPU bake
                // line at all, and this is the only silent path.
                Diagnostics.shared.log("texture-bake", "cloud colours — no keyframes")
                textured = MeshTextureBaker.bake(mesh: mesh, cloud: isolated)
            } else {
                // Even-lighting multi-view blend (smoothLighting) cancels specular
                // glints on a close object but is a pure-CPU per-texel pass — far
                // too slow on a big open surface. Open surfaces (rooms/façades) take
                // the GPU best-view path instead; objects keep the even blend.
                textured = PhotoTextureBaker.bake(mesh: mesh,
                                                  keyframes: keyframesBox.value,
                                                  fallbackCloud: isolated,
                                                  smoothLighting: !surface,
                                                  areaProportional: usedAdaptive)
                    ?? MeshTextureBaker.bake(mesh: mesh, cloud: isolated)
            }
            // Cleanup funnel for diagnostics: if `kept` stays close to `raw`,
            // isolation/masking isn't stripping the support-surface/background
            // bleed — which would explain "the model still bleeds".
            Diagnostics.shared.log("object model", "raw \(cloudBox.value.count)"
                + " → kept \(isolated.count) → mesh \(mesh.triangleCount) tris"
                + " · isolate \(isolationPath)"
                + (usedRays ? " · fusion-rays" : " · est-normals")
                + (textured != nil ? " · textured" : ""))
            return (isolated, mesh, textured)
        } completion: { [weak self] result in
            guard let self else { return }
            let (isolated, mesh, textured) = result
            self.capturedCloud = nil
            self.textureSourceCloud = isolated
            self.capturedMesh = mesh          // didSet clears texturedMesh
            self.texturedMesh = textured
            self.removeStructure = false
            self.scanKind = .mesh
            self.meshColorMode = .shaded
            self.pointCount = mesh.triangleCount
            self.showToast(textured != nil
                           ? "Model ready · \(mesh.triangleCount) tris · textured"
                           : "Model ready · \(mesh.triangleCount) tris")
        }
    }

    // MARK: - Object isolation

    /// Isolates the scanned subject. When the scan captured keyframe photos,
    /// their Vision subject silhouettes pre-filter the cloud (a coarse visual
    /// hull) — the geometric pass (plane removal + clustering) then only has
    /// to clean up what's left.
    func isolateSubject() {
        guard let cloud = capturedCloud else { return }
        let box = UncheckedSendableBox(cloud)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let keyframesBox = UncheckedSendableBox(textureKeyframes)
        let surfaceBox = UncheckedSendableBox(captureSceneMesh)
        let anchor = subjectAnchor   // trust the tap when choosing the subject cluster
        runOperation(.isolating, startingToast: "Isolating object…",
                     failureToast: "Couldn't isolate an object — scan a clearer subject")
        { () -> (cloud: PointCloud, directions: [SIMD3<Float>]?, message: String)? in
            // ARKit scene-mesh cleanup first: drop silhouette floaters and crop
            // the classified floor before the photo/geometric isolation runs.
            let cleaned = SurfaceMask.cleaned(box.value, using: surfaceBox.value)
            let maskDropped = box.value.count - cleaned.count
            let masked = KeyframeSubjectFilter.filter(cleaned, keyframes: keyframesBox.value)
            let working = masked?.cloud ?? cleaned
            func withMaskNote(_ parts: [String]) -> String {
                (maskDropped > 0 ? parts + ["ARKit −\(maskDropped)"] : parts)
                    .joined(separator: " · ")
            }
            // Carry the recorder's view rays across the isolation (a pure subset),
            // so a later Make 3D Model reconstructs this curated cloud with the
            // robust Fusion orientation instead of estimated normals.
            func rays(_ c: PointCloud) -> [SIMD3<Float>]? {
                SpatialScanViewModel.recoverViewDirections(
                    for: c, from: box.value, directions: directionsBox.value)
            }
            if let result = PointCloudSegmenter.isolateMainSubject(working, anchor: anchor) {
                var parts: [String] = ["Kept \(result.keptPoints) pts"]
                if let masked { parts.append("photo mask ×\(masked.viewsUsed)") }
                if result.removedPlanePoints > 0 { parts.append("floor −\(result.removedPlanePoints)") }
                if result.clusterCount > 1 { parts.append("\(result.clusterCount) clusters found") }
                return (result.cloud, rays(result.cloud), withMaskNote(parts))
            }
            if let masked {
                // Geometric pass found nothing further — the mask alone is the isolation.
                return (masked.cloud, rays(masked.cloud),
                        withMaskNote(["Photo mask ×\(masked.viewsUsed)",
                                      "kept \(masked.cloud.count) pts"]))
            }
            if maskDropped > 0 {
                // Only the ARKit cleanup changed anything — still a win.
                return (cleaned, rays(cleaned), "ARKit cleanup · kept \(cleaned.count) pts")
            }
            return nil
        } completion: { [weak self] outcome in
            guard let self else { return }
            self.capturedCloud = outcome.cloud           // didSet clears rays
            self.capturedViewDirections = outcome.directions   // …re-attach the carried ones
            self.userIsolated = true   // isolated cloud → Make 3D Model trusts it
            self.pointCount = outcome.cloud.count
            self.showToast(outcome.message)
        }
    }

    // MARK: - Mesh clean-up

    /// Smooths the captured mesh (Taubin) on a background task for a cleaner
    /// output. Operates on the effective mesh so a structure crop is respected.
    func optimizeMesh() {
        guard let mesh = effectiveMesh else { return }
        let meshBox = UncheckedSendableBox(mesh)
        runOperation(.optimizing, startingToast: "Optimising surface…") { () -> MeshData? in
            MeshOptimizer.smooth(meshBox.value)
        } completion: { [weak self] result in
            guard let self else { return }
            let hadTexture = self.texturedMesh != nil
            self.capturedMesh = result   // didSet clears the now-stale texture
            self.removeStructure = false
            self.pointCount = result.triangleCount
            self.showToast("Surface optimised" + (hadTexture ? " · re-bake texture" : ""))
        }
    }

    /// Caps small boundary holes in the captured mesh on a background task.
    func fillHoles() {
        guard let mesh = effectiveMesh else { return }
        let meshBox = UncheckedSendableBox(mesh)
        let originalCount = mesh.triangleCount
        runOperation(.fillingHoles, startingToast: "Filling holes…") { () -> MeshData? in
            MeshHoleFiller.fill(meshBox.value)
        } completion: { [weak self] result in
            guard let self else { return }
            let added = result.triangleCount - originalCount
            let hadTexture = self.texturedMesh != nil
            self.capturedMesh = result   // didSet clears the now-stale texture
            self.removeStructure = false
            self.pointCount = result.triangleCount
            let base = added > 0 ? "Filled holes · +\(added) tris" : "No small holes found"
            self.showToast(base + (hadTexture ? " · re-bake texture" : ""))
        }
    }

    /// Reduces mesh triangle count via vertex clustering (background).
    func decimateMesh() {
        guard let mesh = effectiveMesh else { return }
        let box = UncheckedSendableBox(mesh)
        runOperation(.decimating, startingToast: "Reducing detail…") { () -> MeshData? in
            MeshDecimator.decimate(box.value)
        } completion: { [weak self] reduced in
            guard let self else { return }
            let hadTexture = self.texturedMesh != nil
            self.capturedMesh = reduced   // didSet clears the now-stale texture
            self.removeStructure = false
            self.pointCount = reduced.triangleCount
            self.showToast("Reduced to \(reduced.triangleCount) tris"
                + (hadTexture ? " · re-bake texture" : ""))
        }
    }

    // MARK: - Cloud clean-up

    /// Outlier removal on the captured cloud (background). Uses the Metal
    /// compute path (radius outlier removal) when the GPU is available; falls
    /// back to the CPU statistical denoiser otherwise.
    func cleanUpCloud() {
        guard let cloud = capturedCloud else { return }
        let box = UncheckedSendableBox(cloud)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let originalCount = cloud.count
        runOperation(.cleaning, startingToast: "Cleaning up…") { () -> (PointCloud, [SIMD3<Float>]?)? in
            var cleaned = GPUPointProcessor.removeRadiusOutliers(box.value)
                ?? PointCloudDenoiser.removeOutliers(box.value)
            // Then shed detached flying-pixel blobs the outlier pass keeps, so
            // "Clean up" clears the snowstorm of strays, not just sparse points.
            cleaned = PointCloudSegmenter.removeStrayClusters(cleaned)
            // Outlier removal only drops points, so the kept points keep their
            // positions — carry the Fusion view rays through the subset so a
            // later reconstruct still orients off measured rays instead of
            // falling back to estimated normals (the flat-sheet collapse).
            let dirs = SpatialScanViewModel.recoverViewDirections(
                for: cleaned, from: box.value, directions: directionsBox.value)
            return (cleaned, dirs)
        } completion: { [weak self] result in
            guard let self else { return }
            let (cleaned, dirs) = result
            let removed = originalCount - cleaned.count
            self.capturedCloud = cleaned        // didSet clears directions…
            self.capturedViewDirections = dirs  // …restore after
            self.pointCount = cleaned.count
            self.showToast(removed > 0 ? "Removed \(removed) stray points" : "Already clean")
        }
    }

    /// Curvature-aware thinning: sheds points on flat areas (walls, tabletops)
    /// while keeping edges and fine relief dense, so a re-mesh resolves features
    /// at a fraction of the point count. Reuses the cleaning operation slot.
    func adaptiveDownsampleCloud() {
        guard let cloud = capturedCloud else { return }
        let box = UncheckedSendableBox(cloud)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let originalCount = cloud.count
        runOperation(.thinning, startingToast: "Thinning flat areas…") { () -> (PointCloud, [SIMD3<Float>]?)? in
            let source = box.value
            guard source.count > 2_000,
                  let spacing = BallPivotingMesher.meanSpacing(source.positions) else {
                return (source, directionsBox.value)
            }
            let curvature = PointCloudCurvature.estimate(source)
            let thinned = PointCloudAdaptiveDownsampler.downsample(
                source, curvatures: curvature, spacing: spacing)
            // Thinning is a subset — carry the measured view rays through it so a
            // later reconstruct keeps the robust ray orientation.
            let dirs = SpatialScanViewModel.recoverViewDirections(
                for: thinned, from: source, directions: directionsBox.value)
            return (thinned, dirs)
        } completion: { [weak self] result in
            guard let self else { return }
            let (thinned, dirs) = result
            let removed = originalCount - thinned.count
            // Keep the change only when it meaningfully thinned and didn't gut
            // the cloud (a tiny/already-sparse scan can come back near-empty).
            guard removed > 0, thinned.count >= 1_000 else {
                self.showToast("Already at an efficient density")
                return
            }
            self.capturedCloud = thinned       // didSet clears directions…
            self.capturedViewDirections = dirs // …restore after
            self.pointCount = thinned.count
            self.showToast("Thinned \(removed) flat-area points · \(thinned.count) kept")
        }
    }

    /// Caps the open bottom left by floor removal / isolation, so the object
    /// reads as a solid: stands in AR, 3D-printable, watertight-ish.
    func closeBase() {
        guard let mesh = effectiveMesh else { return }
        let box = UncheckedSendableBox(mesh)
        let originalCount = mesh.triangleCount
        runOperation(.closingBase, startingToast: "Closing base…") { () -> MeshData? in
            MeshHoleFiller.closeBase(box.value)
        } completion: { [weak self] filled in
            guard let self else { return }
            let added = filled.triangleCount - originalCount
            guard added > 0 else {
                self.showToast("No open base found — the bottom is already closed")
                return
            }
            self.removeStructure = false
            let hadTexture = self.texturedMesh != nil
            self.capturedMesh = filled   // didSet clears the now-stale texture
            self.pointCount = filled.triangleCount
            self.showToast("Base closed · +\(added) tris"
                + (hadTexture ? " · re-bake texture" : ""))
        }
    }

    /// Strips the dominant flat support surface (table / placemat / floor) from
    /// the captured mesh, leaving the object that stood on it. Manual fallback for
    /// when the one-tap model kept its base — the auto support-lift is deliberately
    /// conservative so flat objects aren't gutted, so this gives the user the lever
    /// on demand. No-ops with a toast when there's no clear flat support to remove.
    func removeBasePlane() {
        guard let mesh = effectiveMesh else { return }
        let box = UncheckedSendableBox(mesh)
        let originalCount = mesh.triangleCount
        runOperation(.removingBase, startingToast: "Removing base…") { () -> MeshData? in
            box.value.removingBasePlane()
        } completion: { [weak self] result in
            guard let self else { return }
            guard result.triangleCount < originalCount else {
                self.showToast("No flat base found to remove")
                return
            }
            let removed = originalCount - result.triangleCount
            let hadTexture = self.texturedMesh != nil
            self.removeStructure = false
            self.capturedMesh = result   // didSet clears the now-stale texture
            self.pointCount = result.triangleCount
            self.showToast("Base removed · −\(removed) tris"
                + (hadTexture ? " · re-bake texture" : ""))
        }
    }

    /// Drops low-confidence points. LiDAR returns from glossy ceramic, metal or
    /// glass scatter and multipath — and ARKit marks exactly those samples as
    /// low confidence. The fused confidence is a weighted average over every
    /// sighting, so surfaces that were ever seen reliably survive the cut.
    func removeUnreliablePoints() {
        guard let cloud = capturedCloud else { return }
        let box = UncheckedSendableBox(cloud)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let originalCount = cloud.count
        runOperation(.filteringReflections, startingToast: "Filtering reflections…") { () -> (PointCloud, [SIMD3<Float>]?)? in
            let source = box.value
            var kept = PointCloud()
            kept.reserveCapacity(source.count)
            for i in 0..<source.count where source.confidences[i] >= 0.65 {
                kept.append(position: source.positions[i], color: source.colors[i],
                            confidence: source.confidences[i])
            }
            // Confidence filtering is a subset — carry the view rays through it.
            let dirs = SpatialScanViewModel.recoverViewDirections(
                for: kept, from: source, directions: directionsBox.value)
            return (kept, dirs)
        } completion: { [weak self] result in
            guard let self else { return }
            let (filtered, dirs) = result
            let removed = originalCount - filtered.count
            guard removed > 0 else { self.showToast("No low-confidence points found"); return }
            guard filtered.count >= 1_000 else {
                self.showToast("Almost everything is low-confidence — kept as is")
                return
            }
            self.capturedCloud = filtered        // didSet clears directions…
            self.capturedViewDirections = dirs   // …restore after
            self.pointCount = filtered.count
            self.showToast("Removed \(removed) unreliable pts · see Confidence view")
        }
    }

    /// Estimates per-point surface normals on a background task. They are cached,
    /// included automatically when the cloud is exported as PLY, and invalidated
    /// whenever the cloud changes (so re-estimate after a clean-up or merge).
    func estimateCloudNormals() {
        guard let cloud = capturedCloud else { return }
        guard capturedCloudNormals == nil else {
            showToast("Normals already estimated"); return
        }
        let box = UncheckedSendableBox(cloud)
        runOperation(.estimatingNormals, startingToast: "Estimating normals…") { () -> [SIMD3<Float>]? in
            PointCloudNormals.estimate(box.value)
        } completion: { [weak self] normals in
            guard let self else { return }
            // Skip if the cloud changed under us during estimation.
            guard self.capturedCloud?.count == box.value.count else { return }
            self.capturedCloudNormals = normals
            self.showToast("Normals ready — included in PLY export")
        }
    }

    // MARK: - Crop to box

    /// Keeps only the geometry inside the axis-aligned box [lo, hi] (world
    /// space). Filters the mesh by triangle centroid or the cloud by point.
    /// Goes through the operation slot, so it is undoable.
    func cropToBox(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        guard hasResult, lo.x < hi.x, lo.y < hi.y, lo.z < hi.z else { return }
        let meshBox = UncheckedSendableBox(effectiveMesh)
        let cloudBox = UncheckedSendableBox(capturedCloud)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        // Through runOperation like every other op: generation-guarded (a discard
        // mid-crop can't resurrect the old result), cancellable, bg-asserted.
        runOperation(.cropping, startingToast: "Cropping…", priority: .userInitiated, work: {
            () -> (cloud: PointCloud?, directions: [SIMD3<Float>]?, mesh: MeshData?)? in
            if let mesh = meshBox.value {
                return (nil, nil, Self.cropMesh(mesh, min: lo, max: hi))
            }
            if let cloud = cloudBox.value {
                let kept = (0..<cloud.count).filter { i in
                    let p = cloud.positions[i]
                    return p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y
                        && p.z >= lo.z && p.z <= hi.z
                }
                let cropped = cloud.subset(kept)
                // Carry the recorder's view rays across the crop (a pure subset)
                // so a later Make 3D Model uses the robust Fusion orientation.
                let rays = SpatialScanViewModel.recoverViewDirections(
                    for: cropped, from: cloud, directions: directionsBox.value)
                return (cropped, rays, nil)
            }
            return nil
        }, completion: { [weak self] result in
            guard let self else { return }
            if let mesh = result.mesh {
                guard !mesh.isEmpty else { self.showToast("Crop box is empty — widen it"); return }
                self.removeStructure = false
                self.capturedMesh = mesh
                self.pointCount = mesh.triangleCount
                self.showToast("Cropped · \(mesh.triangleCount) tris")
            } else if let cloud = result.cloud {
                guard cloud.count >= 100 else { self.showToast("Crop box is too small"); return }
                self.capturedCloud = cloud                       // didSet clears rays
                self.capturedViewDirections = result.directions  // …re-attach the carried ones
                self.pointCount = cloud.count
                self.userIsolated = true   // manual crop → Make 3D Model trusts it
                self.showToast("Cropped · \(cloud.count) pts")
            }
        })
    }

    /// Rebuilds a mesh from only the triangles whose centroid is inside the box,
    /// compacting and remapping the surviving vertices (normals/classification
    /// carried along). Pure value math — runs off-main.
    private nonisolated static func cropMesh(_ mesh: MeshData,
                                             min lo: SIMD3<Float>,
                                             max hi: SIMD3<Float>) -> MeshData {
        let hasNormals = mesh.normals.count == mesh.vertices.count
        let hasClass = mesh.hasClassification
        var remap = [UInt32: UInt32](minimumCapacity: mesh.vertices.count / 2)
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var classifications: [UInt8] = []
        var indices: [UInt32] = []

        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = (mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2])
            let centroid = (mesh.vertices[Int(tri.0)] + mesh.vertices[Int(tri.1)]
                            + mesh.vertices[Int(tri.2)]) / 3
            t += 3
            guard centroid.x >= lo.x, centroid.x <= hi.x,
                  centroid.y >= lo.y, centroid.y <= hi.y,
                  centroid.z >= lo.z, centroid.z <= hi.z else { continue }
            for old in [tri.0, tri.1, tri.2] {
                if let m = remap[old] {
                    indices.append(m)
                } else {
                    let m = UInt32(vertices.count)
                    remap[old] = m
                    vertices.append(mesh.vertices[Int(old)])
                    if hasNormals { normals.append(mesh.normals[Int(old)]) }
                    if hasClass { classifications.append(mesh.classifications[Int(old)]) }
                    indices.append(m)
                }
            }
        }
        return MeshData(vertices: vertices, normals: normals, indices: indices,
                        classifications: classifications)
    }

    // MARK: - Lasso selection

    /// Keeps or deletes the point-cloud points the viewer reported as enclosed
    /// by a freeform lasso. Undoable; refuses to gut the cloud below 100 points.
    func applyLasso(insideIndices: [Int], keepInside: Bool) {
        guard let cloud = capturedCloud, !insideIndices.isEmpty else { return }
        let box = UncheckedSendableBox(cloud)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let inside = Set(insideIndices)
        runOperation(.cropping,
                     startingToast: keepInside ? "Keeping selection…" : "Deleting selection…",
                     priority: .userInitiated, work: {
            () -> (cloud: PointCloud, directions: [SIMD3<Float>]?)? in
                let source = box.value
                let kept = (0..<source.count).filter {
                    keepInside ? inside.contains($0) : !inside.contains($0)
                }
                var selection = source.subset(kept)
                // Depth-aware keep: a 2-D lasso also grabs whatever sits *behind*
                // the subject in that screen region (the wall/floor the loop draws
                // over). When keeping a selection, 3-D cluster it and drop the
                // disconnected background, keeping the dominant component the user
                // circled — so the lasso becomes a precise object picker.
                if keepInside, selection.count >= 200 {
                    let parts = PointCloudSegmenter.clusters(selection)
                    if let largest = parts.first,
                       largest.count >= selection.count / 3,
                       largest.count < selection.count {
                        selection = PointCloudSegmenter.subset(selection, indices: largest)
                    }
                }
                // Carry the recorder's view rays across the selection (a pure
                // subset of the source, even after clustering) so a later Make 3D
                // Model reconstructs with the robust Fusion orientation.
                let rays = SpatialScanViewModel.recoverViewDirections(
                    for: selection, from: source, directions: directionsBox.value)
                return (selection, rays)
        }, completion: { [weak self] result in
            guard let self else { return }
            guard result.cloud.count >= 100 else { self.showToast("Selection too small — kept as is"); return }
            let removed = cloud.count - result.cloud.count
            self.capturedCloud = result.cloud                 // didSet clears rays
            self.capturedViewDirections = result.directions   // …re-attach the carried ones
            self.pointCount = result.cloud.count
            // The user is hand-curating the subject — let Make 3D Model trust it.
            self.userIsolated = true
            self.showToast(keepInside ? "Kept \(result.cloud.count) pts" : "Deleted \(removed) pts")
        })
    }

    // MARK: - Mirror / symmetry

    /// Reflects the result across its centre plane along `axis` (0=X, 1=Y, 2=Z)
    /// and merges the reflection back in — completes a roughly symmetric subject
    /// scanned mostly from one side. Crop to the symmetry plane first for a clean
    /// join. Undoable.
    func mirrorModel(axis: Int) {
        guard hasResult, axis >= 0, axis < 3 else { return }
        let meshBox = UncheckedSendableBox(capturedMesh)
        let cloudBox = UncheckedSendableBox(capturedCloud)
        runOperation(.mirroring, startingToast: "Mirroring…", priority: .userInitiated, work: {
            () -> (cloud: PointCloud?, mesh: MeshData?)? in
            if let mesh = meshBox.value { return (nil, Self.mirrorMesh(mesh, axis: axis)) }
            if let cloud = cloudBox.value { return (Self.mirrorCloud(cloud, axis: axis), nil) }
            return nil
        }, completion: { [weak self] result in
            guard let self else { return }
            if let mesh = result.mesh {
                self.removeStructure = false
                self.capturedMesh = mesh
                self.pointCount = mesh.triangleCount
                self.showToast("Mirrored · \(mesh.triangleCount) tris")
            } else if let cloud = result.cloud {
                self.capturedCloud = cloud
                self.pointCount = cloud.count
                self.showToast("Mirrored · \(cloud.count) pts")
            }
        })
    }

    /// Mesh reflected across its centre plane and concatenated. Reflection
    /// reverses orientation, so the copy's winding *and* per-vertex normals are
    /// flipped along the axis to keep the surface facing outward.
    private nonisolated static func mirrorMesh(_ mesh: MeshData, axis: Int) -> MeshData {
        guard let box = mesh.boundingBox() else { return mesh }
        let center = ((box.min + box.max) * 0.5)[axis]
        let originalCount = mesh.vertices.count
        let hasNormals = mesh.normals.count == originalCount
        let hasClass = mesh.hasClassification

        var vertices = mesh.vertices
        vertices.reserveCapacity(originalCount * 2)
        for v in mesh.vertices {
            var r = v; r[axis] = 2 * center - r[axis]; vertices.append(r)
        }
        var normals = mesh.normals
        if hasNormals {
            for n in mesh.normals { var r = n; r[axis] = -r[axis]; normals.append(r) }
        }
        var classifications = mesh.classifications
        if hasClass { classifications.append(contentsOf: mesh.classifications) }

        var indices = mesh.indices
        indices.reserveCapacity(mesh.indices.count * 2)
        let base = UInt32(originalCount)
        var i = 0
        while i + 2 < mesh.indices.count {
            indices.append(mesh.indices[i] + base)
            indices.append(mesh.indices[i + 2] + base)   // reversed winding
            indices.append(mesh.indices[i + 1] + base)
            i += 3
        }
        return MeshData(vertices: vertices, normals: hasNormals ? normals : [],
                        indices: indices, classifications: hasClass ? classifications : [])
    }

    /// Point cloud reflected across its centre plane and concatenated.
    private nonisolated static func mirrorCloud(_ cloud: PointCloud, axis: Int) -> PointCloud {
        guard let box = cloud.boundingBox() else { return cloud }
        let center = ((box.min + box.max) * 0.5)[axis]
        var out = cloud
        out.reserveCapacity(cloud.count * 2)
        for i in 0..<cloud.count {
            var p = cloud.positions[i]; p[axis] = 2 * center - p[axis]
            out.append(position: p, color: cloud.colors[i], confidence: cloud.confidences[i])
        }
        return out
    }

    // MARK: - One-tap "Smart finish"

    /// Scene-aware one-tap finish — detects what the mesh is and does the logical
    /// thing, so the user doesn't pick tools. An open surface (wall / floor /
    /// façade — a thin slab) gets its run-away edges trimmed and gaps filled and
    /// stays open; an object gets lifted off any flat support, its base closed and
    /// holes filled → solid. Both then smoothed. Undoable; drops the texture
    /// (geometry changed), so the toast says re-bake.
    func smartFinish() {
        guard let mesh = effectiveMesh else { return }
        let box = UncheckedSendableBox(mesh)
        runOperation(.makingPrintable, startingToast: "Finishing…",
                     priority: .userInitiated, work: {
            () -> (mesh: MeshData, summary: String)? in
                // Strip floating fragments first so closing/filling work on the
                // real body, not bridged across specks in the air.
                var m = box.value.removingSmallComponents()
                // A thin slab is an open surface; anything with real volume is an
                // object (maybe resting on a support).
                let isOpenSurface = m.isThinOpenSurface
                let summary: String
                if isOpenSurface {
                    m = m.trimmingLongEdges()
                    m = MeshHoleFiller.fill(m)
                    // The full clean finish: denoise → flatten walls/floor →
                    // adaptive (progressive) triangle density. It smooths
                    // internally, so the object-branch smooth pass is skipped here.
                    m = SurfaceCleanup.clean(m).mesh
                    summary = "Surface cleaned"
                } else {
                    let lifted = m.removingBasePlane()      // no-op if no support
                    let didLift = lifted.triangleCount < m.triangleCount
                    if didLift { m = lifted }
                    m = MeshHoleFiller.closeBase(m)
                    m = MeshHoleFiller.fill(m)
                    m = MeshOptimizer.smooth(m)   // objects: smooth the closed solid
                    summary = didLift ? "Lifted off surface · solid" : "Closed · solid"
                }
                return (m, summary)
        }, completion: { [weak self] result in
            guard let self else { return }
            let hadTexture = self.texturedMesh != nil
            self.removeStructure = false
            self.capturedMesh = result.mesh   // didSet clears the now-stale texture
            self.pointCount = result.mesh.triangleCount
            self.showToast("\(result.summary) · \(result.mesh.triangleCount) tris"
                + (hadTexture ? " · re-bake texture" : ""))
        })
    }

    // MARK: - Studio transforms (scale / rotate)

    /// Uniformly scales the captured result about its bounding-box centre.
    /// A baked texture survives (the transform doesn't change UV mapping), but
    /// photo keyframes are dropped: their depth maps and intrinsics describe
    /// the original size, so a later photo re-bake would misproject.
    func scaleModel(factor: Float) {
        guard factor.isFinite, factor > 0.001, factor < 1000, hasResult else { return }
        applyModelTransform(toast: String(format: "Scaling ×%.2f…", factor),
                            keyframeRigid: nil, dropKeyframes: true) { center in
            var scale = matrix_identity_float4x4
            scale.columns.0.x = factor
            scale.columns.1.y = factor
            scale.columns.2.z = factor
            return Self.aboutCenter(scale, center: center)
        }
    }

    /// Rotates the captured result around the world-Y axis through its
    /// bounding-box centre. Rigid, so keyframe camera poses are carried along
    /// and photo texturing keeps working afterwards.
    func rotateModel(degreesY: Float) {
        guard degreesY.isFinite, hasResult else { return }
        let radians = degreesY * .pi / 180
        let cosA = cos(radians), sinA = sin(radians)
        let rotate = simd_float4x4(
            SIMD4<Float>(cosA, 0, -sinA, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sinA, 0, cosA, 0),
            SIMD4<Float>(0, 0, 0, 1))
        applyModelTransform(toast: String(format: "Rotating %.0f°…", degreesY),
                            keyframeRigid: rotate) { center in
            Self.aboutCenter(rotate, center: center)
        }
    }

    /// Shared transform runner: builds the world transform about the result's
    /// centre off-main and applies it to whichever representation is captured.
    /// The baked texture's duplicated-corner mesh is transformed alongside so
    /// it stays valid; the texture-source cloud follows the same transform so
    /// colour re-bakes stay aligned. `keyframeRigid` (rotation about the same
    /// centre) updates keyframe camera poses for rigid transforms.
    private func applyModelTransform(toast: String,
                                     keyframeRigid: simd_float4x4?,
                                     dropKeyframes: Bool = false,
                                     _ make: @escaping @Sendable (SIMD3<Float>) -> simd_float4x4) {
        let cloudBox = UncheckedSendableBox(capturedCloud)
        let meshBox = UncheckedSendableBox(capturedMesh)
        let texturedBox = UncheckedSendableBox(texturedMesh)
        let sourceBox = UncheckedSendableBox(textureSourceCloud)
        // Scaling drops the keyframes (their depth maps/intrinsics describe the
        // original size, a photo re-bake would misproject); rigid rotations carry
        // them. Dropped only when the op actually runs, not on a busy bounce.
        let keyframesBox = UncheckedSendableBox(dropKeyframes ? [] : textureKeyframes)
        runOperation(.transforming, startingToast: toast, work: {
            () -> (cloud: PointCloud?, mesh: MeshData?, textured: TexturedMesh?,
                   source: PointCloud?, keyframes: [ScanKeyframe])? in
                func carriedKeyframes(center: SIMD3<Float>) -> [ScanKeyframe] {
                    guard let rigid = keyframeRigid else { return keyframesBox.value }
                    let world = Self.aboutCenter(rigid, center: center)
                    return keyframesBox.value.map { k in
                        ScanKeyframe(jpeg: k.jpeg,
                                     cameraTransform: world * k.cameraTransform,
                                     intrinsics: k.intrinsics,
                                     depthWidth: k.depthWidth,
                                     depthHeight: k.depthHeight,
                                     depth: k.depth)
                    }
                }
                if let mesh = meshBox.value {
                    guard let box = mesh.boundingBox() else { return nil }
                    let center = (box.min + box.max) * 0.5
                    let transform = make(center)
                    var textured = texturedBox.value
                    if var t = textured {
                        t.mesh = t.mesh.transformed(by: transform)
                        textured = t
                    }
                    return (nil, mesh.transformed(by: transform), textured,
                            sourceBox.value?.transformed(by: transform),
                            carriedKeyframes(center: center))
                }
                if let cloud = cloudBox.value {
                    guard let box = cloud.boundingBox() else { return nil }
                    let center = (box.min + box.max) * 0.5
                    return (cloud.transformed(by: make(center)), nil, nil, nil,
                            carriedKeyframes(center: center))
                }
                return nil
        }, completion: { [weak self] result in
            guard let self else { return }
            if let mesh = result.mesh {
                self.removeStructure = false
                self.capturedMesh = mesh           // didSet clears texturedMesh
                self.texturedMesh = result.textured
                self.textureSourceCloud = result.source
                self.textureKeyframes = result.keyframes
                self.pointCount = mesh.triangleCount
            } else if let cloud = result.cloud {
                self.capturedCloud = cloud         // didSet clears normals/rays
                self.textureKeyframes = result.keyframes
                self.pointCount = cloud.count
            }
            if let dims = self.dimensionsText {
                self.showToast("Transformed · \(dims)")
            } else {
                self.showToast("Transformed")
            }
        })
    }

    /// T(center) · M · T(−center): applies `m` about a pivot.
    nonisolated static func aboutCenter(_ m: simd_float4x4,
                                        center: SIMD3<Float>) -> simd_float4x4 {
        var toOrigin = matrix_identity_float4x4
        toOrigin.columns.3 = SIMD4<Float>(-center, 1)
        var back = matrix_identity_float4x4
        back.columns.3 = SIMD4<Float>(center, 1)
        return back * m * toOrigin
    }

    // MARK: - Multi-scan merge (ICP)

    /// ICP-aligns a saved point cloud into the current one for a more complete
    /// capture. Multi-start yaw seeding handles scans captured facing any way.
    func mergeSavedCloud(_ incoming: PointCloud) {
        guard let base = capturedCloud, !incoming.isEmpty else { return }
        let baseBox = UncheckedSendableBox(base)
        let incomingBox = UncheckedSendableBox(incoming)
        runOperation(.merging, startingToast: "Merging scan…") {
            ICPRegistration.merge(newScan: incomingBox.value, into: baseBox.value)
        } completion: { [weak self] result in
            guard let self else { return }
            self.capturedCloud = result.cloud
            self.pointCount = result.cloud.count
            let overlap = Int((result.fitness * 100).rounded())
            self.showToast("Merged · \(result.cloud.count) pts · \(overlap)% overlap")
        }
    }

    /// ICP-aligns a saved mesh into the current one and concatenates them —
    /// stitching separately scanned rooms or passes into one model. Vertices
    /// stand in for the registration point clouds (strided to keep ICP fast).
    func mergeSavedMesh(_ incoming: MeshData) {
        guard let base = capturedMesh, !incoming.isEmpty else { return }
        let baseBox = UncheckedSendableBox(base)
        let incomingBox = UncheckedSendableBox(incoming)
        runOperation(.merging, startingToast: "Merging mesh…")
        { () -> (mesh: MeshData, fitness: Float)? in
            let target = Self.registrationCloud(from: baseBox.value)
            let source = Self.registrationCloud(from: incomingBox.value)
            let registration = ICPRegistration.register(source: source, target: target)
            // A failed registration (no overlap) would teleport the mesh
            // somewhere arbitrary — append unaligned instead and say so.
            let aligned = registration.fitness > 0.2
                ? incomingBox.value.transformed(by: registration.transform)
                : incomingBox.value
            return (baseBox.value.appending(aligned),
                    registration.fitness > 0.2 ? registration.fitness : 0)
        } completion: { [weak self] result in
            guard let self else { return }
            self.removeStructure = false   // any crop indexes the pre-merge mesh
            self.capturedMesh = result.mesh
            self.pointCount = result.mesh.triangleCount
            if result.fitness > 0 {
                let overlap = Int((result.fitness * 100).rounded())
                self.showToast("Merged · \(result.mesh.triangleCount) tris · \(overlap)% overlap")
            } else {
                self.showToast("Low overlap — added without alignment")
            }
        }
    }

    // MARK: - Place a saved scan

    /// Starts interactive placement of a saved mesh inside the current one —
    /// the viewer shows it as a ghost; the user taps a spot and rotates it.
    func beginPlacement(_ mesh: MeshData) {
        guard capturedMesh != nil, !mesh.isEmpty, !isBusy else { return }
        placementMesh = mesh
        placementRotation = 0
        placementPosition = nil
        showToast("Tap the room where the scan should stand")
    }

    func cancelPlacement() {
        placementMesh = nil
        placementPosition = nil
    }

    /// Bakes the placed mesh into the current one at the chosen spot/rotation.
    /// No registration: both meshes are metric (1:1), the position is explicit.
    func applyPlacement() {
        guard let base = capturedMesh, let object = placementMesh,
              let position = placementPosition else { return }
        let hadTexture = texturedMesh != nil
        let baseBox = UncheckedSendableBox(base)
        let objectBox = UncheckedSendableBox(object)
        let rotation = placementRotation
        runOperation(.placing, startingToast: "Placing scan…") { () -> MeshData? in
            let transform = Self.placementTransform(for: objectBox.value,
                                                    rotation: rotation,
                                                    position: position)
            return baseBox.value.appending(objectBox.value.transformed(by: transform))
        } completion: { [weak self] merged in
            guard let self else { return }
            self.placementMesh = nil
            self.placementPosition = nil
            self.removeStructure = false   // any crop indexes the pre-merge mesh
            self.capturedMesh = merged     // didSet invalidates the baked texture
            self.pointCount = merged.triangleCount
            self.showToast(hadTexture
                           ? "Placed · \(merged.triangleCount) tris — re-bake the texture"
                           : "Placed · \(merged.triangleCount) tris")
        }
    }

    /// Rotate the object around Y about its floor centre, then drop that
    /// centre onto the tapped point: T(position) · R(rotation) · T(−pivot).
    nonisolated static func placementTransform(for mesh: MeshData, rotation: Float,
                                               position: SIMD3<Float>) -> simd_float4x4 {
        guard let box = mesh.boundingBox() else { return matrix_identity_float4x4 }
        let pivot = SIMD3<Float>((box.min.x + box.max.x) * 0.5,
                                 box.min.y,
                                 (box.min.z + box.max.z) * 0.5)
        let cosA = cos(rotation), sinA = sin(rotation)
        let rotate = simd_float4x4(
            SIMD4<Float>(cosA, 0, -sinA, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sinA, 0, cosA, 0),
            SIMD4<Float>(0, 0, 0, 1))
        var toOrigin = matrix_identity_float4x4
        toOrigin.columns.3 = SIMD4<Float>(-pivot, 1)
        var toPosition = matrix_identity_float4x4
        toPosition.columns.3 = SIMD4<Float>(position, 1)
        return toPosition * rotate * toOrigin
    }

    /// Strided vertex sampling of a mesh as a PointCloud for ICP registration.
    private nonisolated static func registrationCloud(from mesh: MeshData,
                                                      cap: Int = 60_000) -> PointCloud {
        var cloud = PointCloud()
        let stride = Swift.max(1, mesh.vertices.count / cap)
        var i = 0
        while i < mesh.vertices.count {
            cloud.append(position: mesh.vertices[i], color: .one, confidence: 1)
            i += stride
        }
        return cloud
    }
}
