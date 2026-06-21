//
//  SpatialScanViewModel+Editing.swift
//  Magic Camera
//
//  Review-time editing operations — every one runs its heavy work on a
//  detached background task and reports back through the observable state.
//

import SwiftUI

extension SpatialScanViewModel {

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

    // MARK: - Surface reconstruction (point cloud → mesh)

    /// Reconstructs a surface mesh from the captured cloud on a background task
    /// using the selected method (voxel / Poisson-style smooth / ball-pivoting),
    /// then switches the review over to the mesh (with its AR / export tooling).
    /// The source cloud is kept aside as the colour source for texture baking.
    func reconstructMesh() {
        guard let cloud = capturedCloud else { return }
        let cloudBox = UncheckedSendableBox(cloud)
        let normalsBox = UncheckedSendableBox(capturedCloudNormals)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
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
            switch method {
            case .voxel:
                return PointCloudMesher.reconstruct(cloud, resolution: min(resolution, effectiveResolution))
            case .smooth:
                return SmoothSurfaceReconstructor.reconstruct(
                    cloud, resolution: effectiveResolution, normals: meshNormals())
            case .ballPivot:
                return BallPivotingMesher.reconstruct(cloud, normals: meshNormals())
            case .fusion:
                // Ray-carved TSDF: the recorder's measured view rays replace
                // estimated normals in the signed field — the outward side is
                // simply "toward the camera that saw the point". Falls back
                // to consistently-oriented estimated normals when the rays
                // are gone (edited / gallery-loaded clouds).
                if let directions, directions.count == cloud.count {
                    return SmoothSurfaceReconstructor.reconstruct(
                        cloud, resolution: effectiveResolution,
                        normals: directions.map { -$0 })
                }
                return SmoothSurfaceReconstructor.reconstruct(
                    cloud, resolution: effectiveResolution, normals: meshNormals())
            }
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
            self.showToast("Surface ready · \(mesh.triangleCount) tris")
        }
    }

    // MARK: - One-tap model

    /// The whole pipeline in one tap: isolate the subject (floor removal +
    /// clustering, falling back to the full cloud when nothing isolates),
    /// reconstruct a smooth surface, and bake the texture (photos when
    /// keyframes exist, cloud colours otherwise).
    func makeQuickModel() {
        guard let cloud = capturedCloud else { return }
        let cloudBox = UncheckedSendableBox(cloud)
        let keyframesBox = UncheckedSendableBox(textureKeyframes)
        let surfaceBox = UncheckedSendableBox(captureSceneMesh)
        let resolution = reconstructDetail.resolution
        let prepass = adaptiveDensityPrepass
        runOperation(.makingModel,
                     startingToast: "Making 3D model…",
                     failureToast: "Couldn't build a model — scan the subject more densely")
        { () -> (PointCloud, MeshData, TexturedMesh?)? in
            // ARKit scene-mesh cleanup first (floaters + classified floor), then
            // the photo-mask visual hull, then the geometric isolation.
            let cleaned = SurfaceMask.cleaned(cloudBox.value, using: surfaceBox.value)
            let masked = KeyframeSubjectFilter.filter(cleaned,
                                                      keyframes: keyframesBox.value)?.cloud
            let working = masked ?? cleaned
            let isolated = PointCloudSegmenter.isolateMainSubject(working)?.cloud
                ?? working
            if Task.isCancelled { return nil }
            // Geometry runs on a bounded subsample (one point per half-cell);
            // the full `isolated` cloud stays the colour source so the texture
            // is unaffected. This is the cap that keeps a dense scan's one-tap
            // model off the CPU/memory watchdog. An optional curvature pre-pass
            // then thins flat regions further. Consistently-oriented normals
            // raise the smooth surface quality.
            var meshInput = isolated
            // Drop the least-reliable points before meshing: low fused confidence
            // is where bleed/ghosts that survived carving sit, and they pull the
            // surface around. Guarded so a dark/glossy (low-confidence) scan isn't
            // gutted. `isolated` itself is kept full as the texture colour source.
            let confident = meshInput.confidentIndices(min: 0.25)
            if confident.count >= 100, confident.count < meshInput.count,
               Float(confident.count) >= Float(meshInput.count) * 0.6 {
                meshInput = meshInput.subset(confident)
            }
            let sample = meshInput.reconstructionSampleIndices(resolution: resolution + 16)
            if sample.count >= 100 && sample.count < meshInput.count {
                meshInput = meshInput.subset(sample)
            }
            if prepass, meshInput.count > 2_000,
               let spacing = BallPivotingMesher.meanSpacing(meshInput.positions) {
                let curvature = PointCloudCurvature.estimate(meshInput)
                let kept = PointCloudAdaptiveDownsampler.keptIndices(
                    meshInput, curvatures: curvature, spacing: spacing)
                if kept.count >= 1_000 && kept.count < meshInput.count {
                    meshInput = meshInput.subset(kept)
                }
            }
            if Task.isCancelled { return nil }
            let normals = PointCloudNormals.estimateConsistent(meshInput)
            // Cap the lattice resolution to what the point density can support:
            // reconstructing fine cells from sparse points interpolates over gaps
            // into a spiky, over-tessellated blob (the "it ruins the surface"
            // result). Never finer than ≈1.5× the mean point spacing.
            var fineResolution = resolution + 16
            if let box = meshInput.boundingBox(),
               let spacing = BallPivotingMesher.meanSpacing(meshInput.positions), spacing > 0 {
                let extent = box.max - box.min
                let maxExtent = max(extent.x, extent.y, extent.z, 0.01)
                fineResolution = max(24, min(fineResolution, Int(maxExtent / (spacing * 1.5))))
            }
            guard let reconstructed = SmoothSurfaceReconstructor.reconstruct(
                    meshInput, resolution: fineResolution, normals: normals)
                ?? PointCloudMesher.reconstruct(meshInput, resolution: min(resolution, fineResolution)),
                !reconstructed.isEmpty else { return nil }
            // Drop the floating blobs reconstruction leaves around the subject
            // before texturing, so the atlas isn't spent on specks in the air.
            var mesh = reconstructed.removingSmallComponents()
            if Task.isCancelled { return nil }
            // Cap the open bottom left by floor removal so the subject reads as a
            // solid object — the "close the surface" parity the user asked for
            // (Apple's Object Capture always returns a watertight mesh). A no-op
            // when nothing is open, so it never harms an already-closed result.
            mesh = MeshHoleFiller.closeBase(mesh)
            if Task.isCancelled { return nil }
            let textured: TexturedMesh?
            if keyframesBox.value.isEmpty {
                textured = MeshTextureBaker.bake(mesh: mesh, cloud: isolated)
            } else {
                textured = PhotoTextureBaker.bake(mesh: mesh,
                                                  keyframes: keyframesBox.value,
                                                  fallbackCloud: isolated,
                                                  smoothLighting: true)
                    ?? MeshTextureBaker.bake(mesh: mesh, cloud: isolated)
            }
            // Cleanup funnel for diagnostics: if `kept` stays close to `raw`,
            // isolation/masking isn't stripping the support-surface/background
            // bleed — which would explain "the model still bleeds".
            Diagnostics.shared.log("object model", "raw \(cloudBox.value.count)"
                + " → kept \(isolated.count) → mesh \(mesh.triangleCount) tris"
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
        let keyframesBox = UncheckedSendableBox(textureKeyframes)
        let surfaceBox = UncheckedSendableBox(captureSceneMesh)
        runOperation(.isolating, startingToast: "Isolating object…",
                     failureToast: "Couldn't isolate an object — scan a clearer subject")
        { () -> (cloud: PointCloud, message: String)? in
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
            if let result = PointCloudSegmenter.isolateMainSubject(working) {
                var parts: [String] = ["Kept \(result.keptPoints) pts"]
                if let masked { parts.append("photo mask ×\(masked.viewsUsed)") }
                if result.removedPlanePoints > 0 { parts.append("floor −\(result.removedPlanePoints)") }
                if result.clusterCount > 1 { parts.append("\(result.clusterCount) clusters found") }
                return (result.cloud, withMaskNote(parts))
            }
            if let masked {
                // Geometric pass found nothing further — the mask alone is the isolation.
                return (masked.cloud,
                        withMaskNote(["Photo mask ×\(masked.viewsUsed)",
                                      "kept \(masked.cloud.count) pts"]))
            }
            if maskDropped > 0 {
                // Only the ARKit cleanup changed anything — still a win.
                return (cleaned, "ARKit cleanup · kept \(cleaned.count) pts")
            }
            return nil
        } completion: { [weak self] outcome in
            guard let self else { return }
            self.capturedCloud = outcome.cloud
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
            self.capturedMesh = result
            self.removeStructure = false
            self.pointCount = result.triangleCount
            self.showToast("Surface optimised")
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
            self.capturedMesh = result
            self.removeStructure = false
            self.pointCount = result.triangleCount
            self.showToast(added > 0 ? "Filled holes · +\(added) tris" : "No small holes found")
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
            self.capturedMesh = reduced
            self.removeStructure = false
            self.pointCount = reduced.triangleCount
            self.showToast("Reduced to \(reduced.triangleCount) tris")
        }
    }

    // MARK: - Cloud clean-up

    /// Outlier removal on the captured cloud (background). Uses the Metal
    /// compute path (radius outlier removal) when the GPU is available; falls
    /// back to the CPU statistical denoiser otherwise.
    func cleanUpCloud() {
        guard let cloud = capturedCloud else { return }
        let box = UncheckedSendableBox(cloud)
        let originalCount = cloud.count
        runOperation(.cleaning, startingToast: "Cleaning up…") { () -> PointCloud? in
            GPUPointProcessor.removeRadiusOutliers(box.value)
                ?? PointCloudDenoiser.removeOutliers(box.value)
        } completion: { [weak self] cleaned in
            guard let self else { return }
            let removed = originalCount - cleaned.count
            self.capturedCloud = cleaned
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
        let originalCount = cloud.count
        runOperation(.cleaning, startingToast: "Thinning flat areas…") { () -> PointCloud? in
            let source = box.value
            guard source.count > 2_000,
                  let spacing = BallPivotingMesher.meanSpacing(source.positions) else {
                return source
            }
            let curvature = PointCloudCurvature.estimate(source)
            return PointCloudAdaptiveDownsampler.downsample(
                source, curvatures: curvature, spacing: spacing)
        } completion: { [weak self] thinned in
            guard let self else { return }
            let removed = originalCount - thinned.count
            // Keep the change only when it meaningfully thinned and didn't gut
            // the cloud (a tiny/already-sparse scan can come back near-empty).
            guard removed > 0, thinned.count >= 1_000 else {
                self.showToast("Already at an efficient density")
                return
            }
            self.capturedCloud = thinned
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
        runOperation(.fillingHoles, startingToast: "Closing base…") { () -> MeshData? in
            MeshHoleFiller.closeBase(box.value)
        } completion: { [weak self] filled in
            guard let self else { return }
            let added = filled.triangleCount - originalCount
            guard added > 0 else {
                self.showToast("No open base found — the bottom is already closed")
                return
            }
            self.removeStructure = false
            self.capturedMesh = filled
            self.pointCount = filled.triangleCount
            self.showToast("Base closed · +\(added) tris")
        }
    }

    /// Drops low-confidence points. LiDAR returns from glossy ceramic, metal or
    /// glass scatter and multipath — and ARKit marks exactly those samples as
    /// low confidence. The fused confidence is a weighted average over every
    /// sighting, so surfaces that were ever seen reliably survive the cut.
    func removeUnreliablePoints() {
        guard let cloud = capturedCloud else { return }
        let box = UncheckedSendableBox(cloud)
        let originalCount = cloud.count
        runOperation(.cleaning, startingToast: "Filtering reflections…") { () -> PointCloud? in
            let source = box.value
            var kept = PointCloud()
            kept.reserveCapacity(source.count)
            for i in 0..<source.count where source.confidences[i] >= 0.65 {
                kept.append(position: source.positions[i], color: source.colors[i],
                            confidence: source.confidences[i])
            }
            return kept
        } completion: { [weak self] filtered in
            guard let self else { return }
            let removed = originalCount - filtered.count
            guard removed > 0 else { self.showToast("No low-confidence points found"); return }
            guard filtered.count >= 1_000 else {
                self.showToast("Almost everything is low-confidence — kept as is")
                return
            }
            self.capturedCloud = filtered
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
        guard hasResult, lo.x < hi.x, lo.y < hi.y, lo.z < hi.z,
              beginOperation(.cropping) else { return }
        showToast("Cropping…")
        let meshBox = UncheckedSendableBox(effectiveMesh)
        let cloudBox = UncheckedSendableBox(capturedCloud)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated)
            { () -> (cloud: PointCloud?, mesh: MeshData?)? in
                if let mesh = meshBox.value {
                    return (nil, Self.cropMesh(mesh, min: lo, max: hi))
                }
                if let cloud = cloudBox.value {
                    let kept = (0..<cloud.count).filter { i in
                        let p = cloud.positions[i]
                        return p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y
                            && p.z >= lo.z && p.z <= hi.z
                    }
                    return (cloud.subset(kept), nil)
                }
                return nil
            }.value
            guard let self else { return }
            self.endOperation()
            guard let result else { return }
            if let mesh = result.mesh {
                guard !mesh.isEmpty else { self.showToast("Crop box is empty — widen it"); return }
                self.removeStructure = false
                self.capturedMesh = mesh
                self.pointCount = mesh.triangleCount
                self.showToast("Cropped · \(mesh.triangleCount) tris")
            } else if let cloud = result.cloud {
                guard cloud.count >= 100 else { self.showToast("Crop box is too small"); return }
                self.capturedCloud = cloud
                self.pointCount = cloud.count
                self.showToast("Cropped · \(cloud.count) pts")
            }
        }
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
        guard let cloud = capturedCloud, !insideIndices.isEmpty,
              beginOperation(.cropping) else { return }
        showToast(keepInside ? "Keeping selection…" : "Deleting selection…")
        let box = UncheckedSendableBox(cloud)
        let inside = Set(insideIndices)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> PointCloud in
                let source = box.value
                let kept = (0..<source.count).filter {
                    keepInside ? inside.contains($0) : !inside.contains($0)
                }
                return source.subset(kept)
            }.value
            guard let self else { return }
            self.endOperation()
            guard result.count >= 100 else { self.showToast("Selection too small — kept as is"); return }
            let removed = cloud.count - result.count
            self.capturedCloud = result
            self.pointCount = result.count
            self.showToast(keepInside ? "Kept \(result.count) pts" : "Deleted \(removed) pts")
        }
    }

    // MARK: - Mirror / symmetry

    /// Reflects the result across its centre plane along `axis` (0=X, 1=Y, 2=Z)
    /// and merges the reflection back in — completes a roughly symmetric subject
    /// scanned mostly from one side. Crop to the symmetry plane first for a clean
    /// join. Undoable.
    func mirrorModel(axis: Int) {
        guard hasResult, axis >= 0, axis < 3, beginOperation(.mirroring) else { return }
        showToast("Mirroring…")
        let meshBox = UncheckedSendableBox(capturedMesh)
        let cloudBox = UncheckedSendableBox(capturedCloud)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated)
            { () -> (cloud: PointCloud?, mesh: MeshData?)? in
                if let mesh = meshBox.value { return (nil, Self.mirrorMesh(mesh, axis: axis)) }
                if let cloud = cloudBox.value { return (Self.mirrorCloud(cloud, axis: axis), nil) }
                return nil
            }.value
            guard let self else { return }
            self.endOperation()
            guard let result else { return }
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
        }
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

    // MARK: - One-tap "make printable"

    /// Close the base, cap small holes and smooth — one tap to a cleaner,
    /// watertight-ish mesh ready for 3D printing. Undoable.
    func makePrintable() {
        guard let mesh = effectiveMesh, beginOperation(.makingPrintable) else { return }
        showToast("Making printable…")
        let box = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> MeshData in
                // Strip floating fragments first so the base/holes are closed on
                // the real object, not bridged across specks in the air.
                var m = box.value.removingSmallComponents()
                m = MeshHoleFiller.closeBase(m)
                m = MeshHoleFiller.fill(m)
                return MeshOptimizer.smooth(m)
            }.value
            guard let self else { return }
            self.endOperation()
            self.removeStructure = false
            self.capturedMesh = result
            self.pointCount = result.triangleCount
            self.showToast("Print-ready · \(result.triangleCount) tris")
        }
    }

    // MARK: - Studio transforms (scale / rotate)

    /// Uniformly scales the captured result about its bounding-box centre.
    /// A baked texture survives (the transform doesn't change UV mapping), but
    /// photo keyframes are dropped: their depth maps and intrinsics describe
    /// the original size, so a later photo re-bake would misproject.
    func scaleModel(factor: Float) {
        guard factor.isFinite, factor > 0.001, factor < 1000, hasResult,
              beginOperation(.transforming) else { return }
        showToast(String(format: "Scaling ×%.2f…", factor))
        textureKeyframes = []
        applyModelTransform(keyframeRigid: nil) { center in
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
        guard degreesY.isFinite, hasResult, beginOperation(.transforming) else { return }
        showToast(String(format: "Rotating %.0f°…", degreesY))
        let radians = degreesY * .pi / 180
        let cosA = cos(radians), sinA = sin(radians)
        let rotate = simd_float4x4(
            SIMD4<Float>(cosA, 0, -sinA, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sinA, 0, cosA, 0),
            SIMD4<Float>(0, 0, 0, 1))
        applyModelTransform(keyframeRigid: rotate) { center in
            Self.aboutCenter(rotate, center: center)
        }
    }

    /// Shared transform runner: builds the world transform about the result's
    /// centre off-main and applies it to whichever representation is captured.
    /// The baked texture's duplicated-corner mesh is transformed alongside so
    /// it stays valid; the texture-source cloud follows the same transform so
    /// colour re-bakes stay aligned. `keyframeRigid` (rotation about the same
    /// centre) updates keyframe camera poses for rigid transforms.
    private func applyModelTransform(keyframeRigid: simd_float4x4?,
                                     _ make: @escaping @Sendable (SIMD3<Float>) -> simd_float4x4) {
        let cloudBox = UncheckedSendableBox(capturedCloud)
        let meshBox = UncheckedSendableBox(capturedMesh)
        let texturedBox = UncheckedSendableBox(texturedMesh)
        let sourceBox = UncheckedSendableBox(textureSourceCloud)
        let keyframesBox = UncheckedSendableBox(textureKeyframes)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility)
            { () -> (cloud: PointCloud?, mesh: MeshData?, textured: TexturedMesh?,
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
            }.value
            guard let self else { return }
            self.endOperation()
            guard let result else { return }
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
        }
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
