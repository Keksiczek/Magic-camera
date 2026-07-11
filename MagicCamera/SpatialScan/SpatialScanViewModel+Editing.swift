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
    /// well under it, so they're never touched. 450 k (was 250 k): the uniform
    /// surface lattice now goes finer on rooms (the ceiling was what made a big
    /// room mesh into "illogical big triangles"), and decimating the finer mesh
    /// back down would re-open the crack + smearing problems the budget raises
    /// fixed before — the GPU bake is atlas-texel-bound, so the extra triangles
    /// cost little; only genuinely enormous scans should ever hit this.
    nonisolated static let photoBakeTriangleBudget = 450_000
    /// The variable-resolution path affords more: the GPU bake's cost scales with
    /// atlas texels not triangles, and the area-proportional atlas assigns texels
    /// by area — so a denser mesh keeps its texture sharp. 600 k (was 320 k) so a
    /// BIG / multi-session space keeps enough triangles for its extent: at 320 k a
    /// large continuous scan came out with too few triangles for its area — coarse,
    /// faceted, "bulgy" walls the plane regulariser had too few vertices to snap
    /// flat, and visibly worse than the un-capped manual "Build Surface". Atlas-
    /// texel-bound bake, so the extra triangles barely cost time and the phone has
    /// the headroom; only genuinely enormous scans hit the crack-free uniform cap
    /// now. A single small room stays well under this untouched.
    nonisolated static let adaptiveBakeTriangleBudget = 600_000

    /// Decimates `mesh` until it fits `budget` triangles, coarsening the cluster
    /// grid until it does (or a floor is hit). Vertex-clustering decimation
    /// self-heals soup/atlas geometry (see [[soup-mesh-weld-rule]]), so it's safe
    /// to run on any mesh. A no-op when already under budget. Off-main, pure value
    /// math — bounds the heaviest review-time op so it can't run the CPU watchdog.
    nonisolated static func cappedForBake(_ mesh: MeshData, budget: Int) -> MeshData {
        guard mesh.triangleCount > budget else { return mesh }
        // Take the FINEST cluster grid whose decimation still fits the budget, so
        // the result lands just under it. The old fixed grid-140 first step
        // overshot badly on a big scan: an 867 k-triangle continuous room collapsed
        // to ~160 k in one step (coarse, faceted walls the regulariser couldn't
        // snap flat) even though the raised budget had room for ~4× that. Search
        // fine→coarse; return the first grid that fits, else the coarsest tried.
        var coarsest: MeshData?
        var grid = 336
        while grid >= 32 {
            let decimated = MeshDecimator.decimate(mesh, gridResolution: grid)
            if !decimated.isEmpty {
                if decimated.triangleCount <= budget { return decimated }
                coarsest = decimated
            }
            grid -= 32
        }
        return coarsest ?? mesh
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
    /// of `source` — the contract the one-tap model and every subset edit relies
    /// on. Forwards to the canonical implementation on `ReconstructionPipeline`
    /// (kept there so the pipeline is standalone-testable without the view model);
    /// the many review-time call sites keep calling it here unchanged.
    nonisolated static func recoverViewDirections(for subset: PointCloud,
                                                  from source: PointCloud,
                                                  directions: [SIMD3<Float>]?) -> [SIMD3<Float>]? {
        ReconstructionPipeline.recoverViewDirections(for: subset, from: source, directions: directions)
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
            // Shared cloud→surface spine (see `ReconstructionPipeline`): the same
            // confident-cut → subsample → prepass → outlier/stray sequence the
            // one-tap model runs, so a fix to it lands in both paths.
            var pipeline = ReconstructionPipeline(cloud: cloudBox.value,
                                                  directions: directionsBox.value,
                                                  normals: normalsBox.value)
            // Drop the least-reliable points first: low fused confidence is where
            // bleed/ghosts that survived carving sit, and they pull the surface.
            pipeline.dropLowConfidence()
            // Density-driven resolution: size the lattice from the (post-cut) cloud's
            // actual point density so the mesh is as fine as the scan supports — a
            // flat tier coarsened a whole room uniformly ("changing detail barely
            // helped"). Bounded by the tier's densityCap to stay off the watchdog.
            let effectiveResolution = SpatialScanViewModel.densityResolution(
                for: pipeline.cloud, fallback: resolution + 16, cap: detailCap)
            // Hard density bound so a million-point room cloud can't blow the
            // watchdog; then optional curvature thinning; then the bleed-halo
            // outlier + stray removal Build Surface used to skip.
            pipeline.subsample(resolution: effectiveResolution)
            if Task.isCancelled { return nil }
            pipeline.curvaturePrepass(enabled: prepass)
            if Task.isCancelled { return nil }
            pipeline.removeOutliersAndStrays()
            if Task.isCancelled { return nil }
            let cloud = pipeline.cloud
            let directions = pipeline.directions
            let normals = pipeline.normals
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
            // surface (the bleed bubbles the SOR above didn't catch) + trim, and on
            // the variable-resolution path fill pinholes then erode the fringe.
            // Build Surface kept these; the one-tap model already strips them. Stays
            // open — no base capping here, that's the model path.
            guard let built, !built.isEmpty else { return built }
            let assembled = ReconstructionPipeline.assemble(
                built, adaptive: ReconstructionSettings.adaptiveEnabled)
            if Task.isCancelled { return nil }
            // Same automatic clean finish as the one-tap surface: flatten walls +
            // denoise. Decimation disabled (adaptiveDecimate: false) — the
            // multi-level clustering cracked the mesh at flat↔detail boundaries;
            // keep the solid reconstruction. Self-gating on organic shapes.
            var cleaned = ReconstructionPipeline.surfaceCleanup(
                assembled, baseResolution: effectiveResolution,
                adaptiveDecimate: false,
                seedPlanes: scenePlanesBox.value)
            if Task.isCancelled { return nil }
            // …and the SAME solidify finish the one-tap surface runs, so "Build
            // Surface" isn't a second-class path: plane snapping tears small seams
            // after the earlier fills, erosion leaves new islands, and the robust
            // graph closer catches the non-manifold gaps the loop filler can't.
            // Stays UN-capped (no boundedForBake) — the texture bake caps later.
            cleaned = ReconstructionPipeline.fillingInteriorPinholes(cleaned)
            cleaned = cleaned.removingSmallComponents()
            let holesBefore = cleaned.boundaryEdgeCount
            cleaned = MeshHoleFiller.closeSmallGaps(cleaned)
            Diagnostics.shared.log("surface holes",
                                   "\(holesBefore) → \(cleaned.boundaryEdgeCount) open edges")
            return cleaned
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
            // Geometry runs on a bounded subsample (one point per half-cell); the
            // full `isolated` cloud stays the colour source so the texture is
            // unaffected. This is the cap that keeps a dense scan's one-tap model
            // off the CPU/memory watchdog.
            //
            // Shared cloud→surface spine (see `ReconstructionPipeline`) — the same
            // confident-cut → subsample → prepass → outlier/stray sequence Build
            // Surface runs, so a fix to it lands in both paths. The pipeline starts
            // from the recovered view rays: isolation/masking only remove points,
            // so each kept point matches back to its source direction, giving the
            // robust outward orientation Build Surface uses. nil for ray-less clouds
            // (gallery-loaded / hand-edited) → estimated normals below. The full
            // `isolated` cloud stays the texture colour source (the pipeline's cuts
            // only bound the GEOMETRY input).
            var pipeline = ReconstructionPipeline(
                cloud: isolated,
                directions: SpatialScanViewModel.recoverViewDirections(
                    for: isolated, from: cloudBox.value, directions: directionsBox.value))
            pipeline.dropLowConfidence()
            // Bilateral denoise on the dense cloud before the reconstruction
            // subsample (variable-resolution path only); then the density bound,
            // curvature thinning, and bleed-halo outlier + stray removal.
            pipeline.bilateralDenoise(enabled: surface && ReconstructionSettings.adaptiveEnabled)
            if Task.isCancelled { return nil }
            // The subsample grid must out-resolve the mesh lattice below, or its
            // half-cell spacing becomes the density term's binding cap and the
            // finer surface ceilings are unreachable (at +16 a surface's density
            // cap maxed at ~2×(res+16)/spacingMul ≈ 213-246 cells regardless of
            // how dense the capture was). Objects keep +16 — their lattice is +16.
            pipeline.subsample(resolution: resolution + (surface ? 96 : 16))
            pipeline.curvaturePrepass(enabled: prepass)
            if Task.isCancelled { return nil }
            pipeline.removeOutliersAndStrays()
            if Task.isCancelled { return nil }
            let meshInput = pipeline.cloud
            let directions = pipeline.directions
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
            // Lattice resolution vs point density. Back to 1.5× (finer = sharper):
            // the holes that made me back off to 2.0× were DECIMATION cracks, not
            // sparse-reconstruction gaps — with adaptive decimation now disabled
            // (it split the mesh at flat↔detail boundaries) a 1.5× mesh stays solid,
            // so the coarse 2.0× base was just softening the geometry (and, through
            // it, the reprojected texture) for no benefit. adaptiveSupport + the
            // 2.5 m pinhole fill still close the odd sparse-region gap. Objects 1.5×.
            let spacingMul: Float = usedAdaptive ? 1.5 : (surface ? 1.3 : 1.5)
            // The adaptive path lets the DENSITY term below drive the lattice: a
            // 9.7 m outdoor scan with 1.8M points was capped at ~224 cells (43 mm)
            // by the fixed ceiling while its point spacing supported ~320 — the
            // "big scans come out coarse with illogical big triangles" report.
            // The density term and the reconstructor's band guard still bound it.
            // The UNIFORM surface path had the same disease at +32: a ~7 m room
            // capped at ~176-224 cells (~31-40 mm triangles — "zbytečně velké,
            // nerozpozná detaily") while its 12 mm cloud supported far finer. +96
            // brings it near the adaptive ceiling; small scans are unaffected
            // (the density term binds them first).
            var fineResolution = resolution + (usedAdaptive ? 128 : (surface ? 96 : 16))
            if let box = meshInput.boundingBox(),
               let spacing = BallPivotingMesher.meanSpacing(meshInput.positions), spacing > 0 {
                let extent = box.max - box.min
                let maxExtent = max(extent.x, extent.y, extent.z, 0.01)
                fineResolution = max(24, min(fineResolution, Int(maxExtent / (spacing * spacingMul))))
                // LiDAR noise floor for room-scale scans: below ~28 mm cells the
                // lattice out-resolves the sensor (multi-metre depth noise is
                // ~cm), so the "detail" it adds is crumpled noise shingles — a
                // device room meshed at 22 mm came back looking like torn paper
                // ("boule"), and the scattered normals shattered the UV unwrap
                // into 71k charts. Geometry detail past this scale doesn't exist
                // in the data; sharpness lives in the photo texture. Close-up
                // scans (< 4 m) keep the fine lattice — noise shrinks with range.
                if surface, maxExtent >= 4 {
                    fineResolution = min(fineResolution, Int(maxExtent / 0.028))
                }
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
            // adaptiveSupport for EVERY surface reconstruction (was adaptive-path
            // only): the finer uniform lattice above would confetti-hole exactly
            // where the adaptive path used to — far walls whose local spacing
            // (distance-coarsened voxels) exceeds the mean-derived cell. The
            // support widening self-gates to those sparse regions, so a dense
            // close-up scan pays nothing.
            guard let reconstructed = SmoothSurfaceReconstructor.reconstruct(
                        meshInput, resolution: fineResolution, normals: normals,
                        adaptiveSupport: surface)
                    ?? PointCloudMesher.reconstruct(meshInput, resolution: min(resolution, fineResolution)),
                  !reconstructed.isEmpty else { return nil }
            // Drop the floating blobs reconstruction leaves around the subject
            // before texturing, so the atlas isn't spent on specks in the air —
            // the snowstorm of disconnected bleed triangles that made "Textured
            // surface" look spoiled. This runs for surface mode too now: dropping
            // disconnected components keeps the open surface intact (it doesn't
            // close anything — that's `closeBase`, still model-only below), it just
            // removes the floaters. Model mode additionally caps the base.
            var mesh = ReconstructionPipeline.assemble(reconstructed, adaptive: usedAdaptive)
            if Task.isCancelled { return nil }
            if surface {
                // Automatic clean finish for open surfaces: flatten the walls/floor
                // and shed reconstruction noise. Decimation is DISABLED here — the
                // adaptive multi-level clustering merged flat and detail vertices
                // onto different grids, so at every flat↔detail boundary (a picture
                // edge, the bed) adjacent triangles stopped sharing an edge and
                // cracked open (the scattered black holes the user saw on a SOLID
                // cloud). The area-proportional atlas keeps the un-decimated small
                // triangles sharp anyway, and boundedForBake below applies a
                // crack-free UNIFORM cap only if the mesh is genuinely too big.
                // Self-gating — organic shapes with no large plane pass through.
                mesh = ReconstructionPipeline.surfaceCleanup(
                    mesh, baseResolution: fineResolution,
                    adaptiveDecimate: false, seedPlanes: scenePlanes)
                if usedAdaptive {
                    // Plane snapping can leave a few marginal triangles — close any
                    // gaps that opened (no long-edge trim here: it would re-open
                    // holes for the fill to chase).
                    mesh = ReconstructionPipeline.fillingInteriorPinholes(mesh)
                }
                // Final floater sweep. `assemble` already pruned small components,
                // but it ran BEFORE surface cleanup + the fills — and boundary
                // erosion / plane snapping can sever thin bridges, leaving new
                // disconnected islands (the debris blobs seen floating inside a
                // scanned room). Now the shell is fully assembled, drop anything
                // still detached from the main body.
                mesh = mesh.removingSmallComponents()
                // One more manifold pinhole fill (loop-based), then the robust
                // graph-based closer for the small NON-MANIFOLD gaps plane snapping
                // leaves — those were the bulk of the scattered empty triangles on
                // well-covered walls (a device room: 527 sub-0.5 m holes still open,
                // 1.7% non-manifold edges, that the loop tracer couldn't form a
                // clean loop around). Real openings (room front, windows) are left
                // alone by the ≤0.4 m size gate. Log the open-edge count before and
                // after so a device scan shows how much the graph closer caught.
                mesh = ReconstructionPipeline.fillingInteriorPinholes(mesh)
                let holesBefore = mesh.boundaryEdgeCount
                mesh = MeshHoleFiller.closeSmallGaps(mesh)
                Diagnostics.shared.log("surface holes",
                                       "\(holesBefore) → \(mesh.boundaryEdgeCount) open edges")
                // Anchor the finished shell back onto the captured points. The
                // fused cloud holds the clean shape ("cloudy si drží hezčí
                // tvary"); the field + lattice added structured crinkle it never
                // had — a device room measured 22% of mesh edges over 41°
                // dihedral while its cloud read smooth, Taubin plateaued at
                // ~14%, and the scattered normals were also what shattered the
                // UV unwrap into 71k charts and failed bake facing tests
                // (`unseen` 15%+ despite good photo coverage). MLS projection
                // along the vertex normal onto the local cloud kills the
                // crinkle AND keeps the surface data-true; fill patches (no
                // cloud beneath) and the open rim stay put. Synthetic harness:
                // structured-zigzag mesh over a clean cloud → p90 dihedral
                // 78°→0.5°, RMS-to-true 8.3→1.4 mm.
                if let snapSpacing = BallPivotingMesher.meanSpacing(meshInput.positions) {
                    let snapped = MeshCloudSnap.snap(mesh, to: meshInput, spacing: snapSpacing)
                    mesh = snapped.mesh
                    Diagnostics.shared.log("cloud snap", String(
                        format: "moved %d/%d verts · avg %.1f mm",
                        snapped.stats.moved, snapped.stats.total, snapped.stats.meanShiftMM))
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
                let preCut = mesh
                if !matCutApplied && !mesh.isThinOpenSurface {
                    mesh = mesh.removingBasePlane()
                }
                mesh = MeshHoleFiller.closeBase(mesh)
                // Invariant: a 3-D subject must never come back as a pancake. If
                // the base cut + close collapsed the mesh flat while the isolated
                // cloud wasn't flat, the heuristics cut the subject, not the
                // support ("zmáčklo to do podlahy") — keep the uncut solid, mat
                // and all; a model with a mat beats a squashed one.
                if mesh.isThinOpenSurface, !Self.isFlat(isolated) {
                    mesh = MeshHoleFiller.closeBase(preCut)
                    isolationPath += "+flat-guard"
                }
            }
            // Bound the per-triangle bake so it can't run for minutes and trip the
            // CPU watchdog. The whole un-isolated scan (surface mode) can mesh into
            // hundreds of thousands of triangles; the photo texture carries the
            // detail, so a capped mesh looks the same but bakes faster. Isolated
            // objects are already small — a no-op for them. `preservingDetail:
            // false` so the cap uses crack-free UNIFORM clustering, never the
            // multi-level adaptive decimation that opened holes at level boundaries.
            mesh = Self.boundedForBake(
                mesh,
                budget: usedAdaptive ? Self.adaptiveBakeTriangleBudget : Self.photoBakeTriangleBudget,
                preservingDetail: false)
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

    /// Caps small boundary holes in the captured mesh on a background task. Uses
    /// the same pair the reconstruction paths run — the wide pinhole fill for clean
    /// boundary loops, then the graph closer for the small NON-manifold gaps plane
    /// snapping leaves (which the loop tracer skips) — so the manual tool closes
    /// exactly what the automatic finish does instead of only the easy holes.
    func fillHoles() {
        guard let mesh = effectiveMesh else { return }
        let meshBox = UncheckedSendableBox(mesh)
        let originalCount = mesh.triangleCount
        runOperation(.fillingHoles, startingToast: "Filling holes…") { () -> MeshData? in
            let filled = ReconstructionPipeline.fillingInteriorPinholes(meshBox.value)
            return MeshHoleFiller.closeSmallGaps(filled)
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
        // The ARKit wall/floor anchors, so Smart finish flattens walls with the
        // same authority the reconstruction paths do — RANSAC alone leaves them
        // rippled, and this path was silently passing no seeds at all.
        let scenePlanes = capturedScenePlanes
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
                    // Same solidify pair the reconstruction paths use: the wide
                    // pinhole fill, then the graph closer for the non-manifold gaps
                    // the loop tracer can't form a clean loop around.
                    m = ReconstructionPipeline.fillingInteriorPinholes(m)
                    m = MeshHoleFiller.closeSmallGaps(m)
                    // The full clean finish: denoise → flatten walls/floor →
                    // adaptive (progressive) triangle density. It smooths
                    // internally, so the object-branch smooth pass is skipped here.
                    m = SurfaceCleanup.clean(m, seedPlanes: scenePlanes).mesh
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
                                     depth: k.depth,
                                     sharpness: k.sharpness)
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

    /// Auto-merge for the "Continue scanning" flow: fold the previously saved
    /// scan (latched at `startScan`) into the just-finished capture, then clear
    /// the intent so it fires exactly once. The prior scan is loaded from disk
    /// *inside* the detached work closure so a large `.mcscan`/`.mcmesh` decode
    /// never blocks the main actor. Mirrors `mergeSavedCloud`/`mergeSavedMesh`
    /// (same ICP, same low-overlap handling) but triggered by the finish path,
    /// not a gallery pick. `buildSurfaceAfter` chains the one-tap textured surface
    /// once the clouds are combined (the mesh-from-cloud finish path).
    func continueMergeIfNeeded(buildSurfaceAfter: Bool) {
        guard let url = continueSourceURL else {
            if buildSurfaceAfter { makeQuickModel(surface: true) }
            return
        }
        continueSourceURL = nil
        if let base = capturedCloud {
            let baseBox = UncheckedSendableBox(base)
            runOperation(.merging, startingToast: "Merging with last scan…",
                         failureToast: "Couldn't load the last scan to merge")
            { () -> (cloud: PointCloud, fitness: Float)? in
                guard let incoming = try? ScanStore.load(url), !incoming.isEmpty else { return nil }
                let merged = ICPRegistration.merge(newScan: incoming, into: baseBox.value)
                return (merged.cloud, merged.fitness)
            } completion: { [weak self] result in
                guard let self else { return }
                self.capturedCloud = result.cloud
                self.pointCount = result.cloud.count
                let overlap = Int((result.fitness * 100).rounded())
                self.showToast("Continued · \(MeasurementFormat.count(result.cloud.count)) pts · \(overlap)% overlap")
                if buildSurfaceAfter { self.makeQuickModel(surface: true) }
            }
        } else if let base = capturedMesh {
            let baseBox = UncheckedSendableBox(base)
            runOperation(.merging, startingToast: "Merging with last scan…",
                         failureToast: "Couldn't load the last scan to merge")
            { () -> (mesh: MeshData, fitness: Float)? in
                guard let incoming = try? MeshStore.load(url), !incoming.isEmpty else { return nil }
                let target = Self.registrationCloud(from: baseBox.value)
                let source = Self.registrationCloud(from: incoming)
                let registration = ICPRegistration.register(source: source, target: target)
                let aligned = registration.fitness > 0.2
                    ? incoming.transformed(by: registration.transform)
                    : incoming
                return (baseBox.value.appending(aligned),
                        registration.fitness > 0.2 ? registration.fitness : 0)
            } completion: { [weak self] result in
                guard let self else { return }
                self.removeStructure = false   // any crop indexes the pre-merge mesh
                self.capturedMesh = result.mesh
                self.pointCount = result.mesh.triangleCount
                if result.fitness > 0 {
                    let overlap = Int((result.fitness * 100).rounded())
                    self.showToast("Continued · \(result.mesh.triangleCount) tris · \(overlap)% overlap")
                } else {
                    self.showToast("Continued — added without alignment (low overlap)")
                }
            }
        } else if buildSurfaceAfter {
            makeQuickModel(surface: true)
        }
    }

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
