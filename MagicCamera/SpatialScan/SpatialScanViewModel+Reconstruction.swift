//
//  SpatialScanViewModel+Reconstruction.swift
//  Magic Camera
//
//  Cloud into surface: the Build Surface path, photogrammetry from the
//  scan's own keyframes, and the one-tap model that runs the same spine
//  end to end.
//

import SwiftUI

extension SpatialScanViewModel {

    // MARK: - Surface reconstruction (point cloud → mesh)

    /// Reconstructs a surface mesh from the captured cloud on a background task
    /// using the selected method (voxel / Poisson-style smooth / ball-pivoting),
    /// then switches the review over to the mesh (with its AR / export tooling).
    /// The source cloud is kept aside as the colour source for texture baking.
    func reconstructMesh(thenFinish: Bool = false) {
        guard let cloud = capturedCloud else { return }
        // Photogrammetry doesn't come from the cloud at all — it reconstructs from
        // the scan's photos, so it shares none of the pipeline below.
        if reconstructMethod.usesPhotos {
            reconstructByPhotogrammetry(thenFinish: thenFinish)
            return
        }
        let cloudBox = UncheckedSendableBox(cloud)
        let normalsBox = UncheckedSendableBox(capturedCloudNormals)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let scenePlanesBox = UncheckedSendableBox(capturedScenePlanes)
        let resolution = reconstructDetail.resolution
        let detailCap = reconstructDetail.densityCap
        let method = reconstructMethod
        let prepass = adaptiveDensityPrepass
        // Close-object capture (≤1.5 m range) scans with mm-scale depth noise, so
        // it keeps the fine lattice its point density supports; every other mode
        // is scanned at room range and gets the 28 mm noise floor. See the floor
        // in `densityResolution`.
        let noiseFloorCell: Float? = captureProfile.subject == .object ? nil : Self.activeRoomLatticeFloorCell
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
                for: pipeline.cloud, fallback: resolution + 16, cap: detailCap,
                noiseFloorCell: noiseFloorCell)
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
            case .photogrammetry:
                // Unreachable — `reconstructMesh` routes this to
                // `reconstructByPhotogrammetry` before the cloud pipeline starts.
                // Kept explicit rather than `default:` so adding a future method
                // is a compile error here instead of a silent nil.
                built = nil
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
            // Same turned-shape rounding as the one-tap paths (isolation-free read
            // of the preference, since this runs off-main).
            cleaned = SpatialScanViewModel.snappingToPrimitives(
                cleaned, enabled: ShapeSnapSettings.enabled)
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

    // MARK: - Photogrammetric reconstruction (from the scan's own photos)

    /// Reconstructs from the scan's keyframes instead of its point cloud.
    ///
    /// The app already shipped photogrammetry, but only behind Apple's guided
    /// Object Capture mode — a separate capture flow with its own UI. This brings
    /// it into the app's own scan mode: the keyframes are already banked (sharp,
    /// pose-diverse, 43-96 per scan) and were only being used as a texture source.
    ///
    /// Why it is worth having at all: the LiDAR path's geometry is floored by
    /// depth noise (3.7 mm on a device object, 15.3 mm in a room), so its lattice
    /// is already at the limit of what the sensor supports. Photogrammetry
    /// recovers geometry from image correspondence and is not bound by that floor.
    ///
    /// Kept off `runOperation`: that runner takes a synchronous work closure, and
    /// `PhotogrammetrySession` is an async output stream. This mirrors its
    /// lifecycle (slot, cancel handle, in-flight latch, stale-result guard,
    /// background assertion) rather than bending it — see `runAsyncOperation`.
    func reconstructByPhotogrammetry(thenFinish: Bool = false) {
        let keyframes = textureKeyframes
        guard KeyframePhotogrammetry.isAvailable else {
            showToast("This device can't run photogrammetry")
            return
        }
        guard keyframes.count >= KeyframePhotogrammetry.minimumKeyframes else {
            showToast("Only \(keyframes.count) photos — photogrammetry needs \(KeyframePhotogrammetry.minimumKeyframes)+")
            return
        }
        let cloud = capturedCloud
        runAsyncOperation(
            .reconstructing,
            startingToast: "Photogrammetry — this takes a few minutes…"
        ) { [weak self] in
            try await KeyframePhotogrammetry.reconstruct(keyframes: keyframes) { fraction, stage in
                // -1 means "stage changed, no new fraction" — keep the last bar.
                self?.showToast(fraction >= 0
                                ? "\(stage) \(Int(fraction * 100))%" : stage)
            }
        } completion: { [weak self] imported in
            guard let self else { return }
            guard !imported.mesh.isEmpty else {
                self.showToast("Photogrammetry produced no geometry")
                return
            }
            self.capturedCloud = nil
            // Keep the cloud as the bake's colour fallback exactly as the LiDAR
            // path does — a photogrammetric mesh can still be re-textured here.
            self.textureSourceCloud = cloud
            self.capturedMesh = imported.mesh
            self.texturedMesh = imported.textured
            self.removeStructure = false
            self.scanKind = .mesh
            // The viewer shows the photo texture whenever `texturedMesh` is set;
            // the colour mode only drives the untextured shading.
            self.meshColorMode = .shaded
            self.pointCount = imported.mesh.triangleCount
            if thenFinish {
                self.smartFinish()
            } else {
                self.showToast("Photogrammetry ready · \(imported.mesh.triangleCount) tris")
            }
        }
    }

    /// Snap a finished mesh onto the surfaces of revolution / spheres it is turned
    /// from (pots, cups, vases, bottles, bowls, a ball), logging the breadcrumb.
    /// Shared by the object, surface and Build-Surface paths so all three round a
    /// scanned shape the same way; a no-op when nothing axisymmetric is found.
    /// `nonisolated` — pure value math called from the detached reconstruction tasks.
    nonisolated static func snappingToPrimitives(_ mesh: MeshData, enabled: Bool) -> MeshData {
        guard enabled else { return mesh }
        var result = mesh
        // Round the turned surfaces (pots/vases/balls), keeping decoration.
        let snapped = MeshPrimitiveSnap.snap(result)
        if snapped.stats.snapped > 0 {
            result = snapped.mesh
            Diagnostics.shared.log("shape snap", snapped.stats.summary)
        }
        // NOTE — the periodic slat-stack regulariser (MeshLouverSnap) is DISABLED.
        // On device it read the marching-cubes LATTICE as a blind: a reconstructed
        // room reported "120 slats · period 2.8 cm" and 95% of its vertices were
        // shifted onto that bogus grid, tearing holes and spikes into the mesh.
        // Root cause: MC places vertices on cell edges, so vertex-count density
        // along any axis is periodic with real gaps at the lattice pitch — which is
        // the same 2–5 cm scale as real slats, and is MORE perfectly periodic than
        // any real blind (the lattice scored a higher autocorrelation than a genuine
        // slat stack). A vertex histogram therefore cannot separate them.
        // To re-enable it needs: density measured from TRIANGLE AREA spread over each
        // triangle's extent (a wall's triangles bridge the lattice rows and cover
        // every coordinate — only a real stack leaves the gaps empty), a cap on the
        // share of the mesh one stack may claim, and validation against real device
        // meshes rather than synthetic grids. The code + tests stay for that work.
        return result
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
        let detailCap = reconstructDetail.densityCap
        let prepass = adaptiveDensityPrepass
        let anchor = subjectAnchor   // the tapped subject, for trust-the-selection isolation
        let manual = userIsolated    // user already lassoed/cropped — skip auto isolation
        let cropTrusted = capturedSupportCropped   // capture already removed the support
        let snapShapes = ShapeSnapSettings.enabled  // round the subject onto cylinders/spheres
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
            } else if cropTrusted, !Self.supportSurvivedTheCrop(cloudBox.value) {
                // The live support crop already removed the pad/table at capture:
                // the cloud IS the subject. Keep the bleed cleanups (mask + visual
                // hull) but skip the geometric isolation and every support lift —
                // re-guessing a clean cloud is what decimated the mouse/plate.
                //
                // …but only once that is actually TRUE. It is a claim about the
                // data, and on the 2026-07-28 object scan the data said otherwise:
                // 74% of the exported cloud was a 4.5 cm slab spanning the full
                // 30 × 43 cm footprint — the tabletop — even though the capture
                // reported `support-crop 1284300 (target yes)`. Taking the
                // shortcut there disables the one branch that removes a support,
                // on the strength of a crop that demonstrably did not.
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
                // The other half of the funnel — everything upstream of the
                // reconstruction prep. A thin subject can be lost to the ARKit
                // mask, to the keyframe visual hull, or to clustering, and the
                // `isolate <path>` label alone doesn't distinguish them.
                Diagnostics.shared.log("isolate funnel",
                    "\(cloudBox.value.count) → mask \(cleaned.count)"
                    + " → hull \(masked?.count ?? cleaned.count)"
                    + " → cluster \(cut.count)")
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
            // Which prep stage cost what. `object model — raw N → kept M` collapses
            // nine stages into two numbers, and a thin subject that comes out
            // gutted (the 2026-07-29 steel-rimmed sunglasses: 111 158 points in,
            // 41 triangles out) needs to name the stage before anything is tuned.
            // Thin structure is the standing suspect — statistical outlier removal
            // reads a wire frame's inherently sparse neighbourhood as noise — but
            // suspicion is not measurement.
            Diagnostics.shared.log("prep funnel", pipeline.funnelSummary)
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
            // Surface ceiling from the AREA-triangle budget (+ the shared room
            // noise floor), not a fixed axis count. `resolution + 96` divided
            // every room into the same number of cells, so a big room got coarse
            // cells and a small one fine — "fewer points → more triangles" when
            // the smaller room is denser. `densityResolution` sizes the cell by
            // area so triangle COUNT tracks the room; it carries the 28 mm noise
            // floor, so this is the same rule Build Surface uses. Objects keep
            // the fixed `resolution + 16` — their own point spacing binds them.
            let latticeBound = surface
                ? SpatialScanViewModel.latticeBound(
                    for: meshInput, fallback: resolution + (usedAdaptive ? 128 : 96),
                    cap: detailCap,
                    noiseFloorCell: SpatialScanViewModel.activeRoomLatticeFloorCell)
                : nil
            var fineResolution = latticeBound?.resolution ?? (resolution + 16)
            if let box = meshInput.boundingBox() {
                let extent = box.max - box.min
                let maxExtent = max(extent.x, extent.y, extent.z, 0.01)
                // Density clamp: don't lattice finer than the points support, or
                // far walls confetti-hole. But a room's cloud is distance-
                // coarsened, so the MEAN nn-spacing is dragged up by the sparse
                // far tail and throttled the WHOLE surface to far-wall coarseness
                // — two same-size device rooms meshed 68 k vs 295 k triangles on
                // nothing but scan distance, and Smart-Finish rooms came back at
                // ~45-55 mm cells ("hrozně málo trigs") while Build Surface, which
                // skips this clamp, stayed fine. For a surface use a robust low
                // percentile (the denser near bulk) instead; `adaptiveSupport`
                // (on below for surfaces) keeps the sparse far walls solid at the
                // finer cell, and densityResolution's 28 mm noise floor is still
                // the hard limit above, so this cannot reach the sub-cm torn-paper
                // regime. Objects are close-scanned at uniform density — mean.
                let spacing = surface
                    ? BallPivotingMesher.spacingPercentile(meshInput.positions, percentile: 0.35)
                    : BallPivotingMesher.meanSpacing(meshInput.positions)
                let beforeClamp = fineResolution
                if let spacing, spacing > 0 {
                    fineResolution = max(24, min(fineResolution, Int(maxExtent / (spacing * spacingMul))))
                }
                // The lattice cell size the reconstruction actually asked for —
                // the number missing from every prior triangle-density diagnosis.
                // `mesh N tris` below then reads as "this cell over this area".
                //
                // …plus WHICH limit produced it. The 2026-07-28 room came back at
                // 42 mm cells under a `floor 28 mm` label, and the four candidate
                // limits (point spacing / triangle budget / narrow band / noise
                // floor) each need a different fix, so the raw number sent the
                // last two rounds guessing. `bound by` names the lever directly.
                let cellMM = maxExtent / Float(max(fineResolution, 1)) * 1000
                let binding = fineResolution < beforeClamp ? "spacing"
                    : (latticeBound?.binding ?? "tier")
                Diagnostics.shared.log("lattice",
                    "res \(fineResolution) · cell \(String(format: "%.0f", cellMM)) mm"
                    + " · bound by \(binding)"
                    + (surface ? " · floor \(Int(SpatialScanViewModel.activeRoomLatticeFloorCell * 1000)) mm"
                        + (ReconstructionSettings.fineRoomLatticeEnabled ? " (fine)" : "") : ""))
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
            var mesh = ReconstructionPipeline.assemble(reconstructed, adaptive: usedAdaptive,
                                                       keepFraction: surface ? 0.05 : 0.01)
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
                // Ghost-sheet trim (needs keyframes): the duplicated layers a
                // few cm behind the real surface — glossy-furniture LiDAR
                // reflections + registration drift — are the protruding pale
                // flaps still reading as torn paper in lit viewers after the
                // shading fix. Parallax against the keyframes' own depth maps
                // identifies them; hidden-but-real geometry keeps (gap ≫ 12 cm).
                if !keyframesBox.value.isEmpty {
                    let trimmed = PhotoTextureBaker.trimmingGhostSheets(
                        mesh, keyframes: keyframesBox.value)
                    if trimmed.removed > 0 {
                        mesh = trimmed.mesh
                        Diagnostics.shared.log("ghost trim",
                                               "removed \(trimmed.removed) tris")
                    }
                }
                // Round any turned surface in the scene (a column, a round table,
                // a vase captured in surface mode) onto its ideal profile — runs
                // AFTER the cloud snap so it has the last word on shape. Flat walls
                // never seed a revolution (parallel normals), so a room is a no-op.
                mesh = SpatialScanViewModel.snappingToPrimitives(mesh, enabled: snapShapes)
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
                // Round the subject onto the turned shape it is made of: a scanned
                // pot / cup / vase / bottle / bowl / ball snaps back to a clean
                // profile instead of the lumpy barrel the noisy marching-cubes
                // surface bakes ("škoda že to nedokáže poznávat common tvary").
                // Only vertices already on a detected surface of revolution move —
                // radially, clamped — so a spout / handle / logo, and any part the
                // fit doesn't recognise, is left untouched; the flat base cap's
                // axial normals fail the radial gate too. Kill switch for A/B.
                mesh = SpatialScanViewModel.snappingToPrimitives(mesh, enabled: snapShapes)
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
            // Shading-normal smoothing, both subjects: the registration noise
            // the mesh inherits (~±1.5 cm between frames) scatters per-face
            // normals, and a LIT viewer shades every facet — the torn-paper
            // "boule" the user sees in AR Quick Look but not in the unlit
            // in-app viewer. Smooth normals only: geometry, bake and UVs are
            // untouched, silhouettes stay, the shading reads as the surface.
            mesh = MeshOptimizer.smoothingNormals(mesh, iterations: 4)
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

}
