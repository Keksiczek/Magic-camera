//
//  SpatialScanViewModel+Cleanup.swift
//  Magic Camera
//
//  Everything that REMOVES or reshapes what was captured — isolation, mesh
//  and cloud clean-up, crop, lasso, mirror. Each runs its heavy work on a
//  detached task and reports back through the observable state.
//

import SwiftUI

extension SpatialScanViewModel {

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
        let anchors = subjectAnchors   // trust the taps when choosing subject clusters
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
            if let result = PointCloudSegmenter.isolateSubjects(working, anchors: anchors) {
                var parts: [String] = ["Kept \(result.keptPoints) pts"]
                if result.subjectCount > 1 { parts.append("\(result.subjectCount) subjects") }
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

    /// Restores the cloud the last keep-lasso selected from, so the next loop
    /// ADDS an object to the selection instead of picking from what the first
    /// loop left behind. Without this, "keep this one" is a one-shot decision:
    /// the second object is no longer on screen to be circled.
    func beginAddingToSelection() {
        guard let base = lassoBaseCloud, !lassoKeptIndices.isEmpty else { return }
        let directions = lassoBaseDirections
        capturedCloud = base                  // didSet clears the rays…
        capturedViewDirections = directions   // …re-attach the base's own
        pointCount = base.count
        lassoAdding = true
        showToast("Whole scan is back — circle the next object to add it")
    }

    /// Keeps or deletes the point-cloud points the viewer reported as enclosed
    /// by a freeform lasso. Undoable; refuses to gut the cloud below 100 points.
    ///
    /// While `lassoAdding` is set, a keep-loop UNIONS with what earlier loops
    /// already kept rather than replacing it, so several objects can be picked
    /// one at a time.
    func applyLasso(insideIndices: [Int], keepInside: Bool) {
        guard let cloud = capturedCloud, !insideIndices.isEmpty else { return }
        let box = UncheckedSendableBox(cloud)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let adding = keepInside && lassoAdding
        let inside: Set<Int> = adding
            ? Set(insideIndices).union(lassoKeptIndices)
            : Set(insideIndices)
        // Remember what this loop selected FROM, so the next one can add to it.
        // A delete-loop is not a subject pick, so it ends the run.
        if keepInside {
            lassoBaseCloud = cloud
            lassoBaseDirections = capturedViewDirections
            lassoKeptIndices = inside
        } else {
            lassoBaseCloud = nil
            lassoBaseDirections = nil
            lassoKeptIndices = []
        }
        lassoAdding = false
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
                // disconnected background — so the lasso becomes a precise object
                // picker.
                //
                // EVERY substantial cluster survives, not just the largest. One
                // loop drawn around two objects used to keep the bigger one and
                // silently bin the other, which is the complaint "multiple objects
                // don't work even when I select them myself" in its purest form.
                // The background is what this is aimed at, and background is a
                // handful of stray points behind the subject, not a second body
                // the size of a fifth of what was circled.
                if keepInside, selection.count >= 200 {
                    let parts = PointCloudSegmenter.clusters(selection)
                    if let largest = parts.first, largest.count < selection.count {
                        let floorPoints = max(largest.count / 5, 60)
                        var keptIndices: [Int] = []
                        for part in parts where part.count >= floorPoints {
                            keptIndices.append(contentsOf: part)
                        }
                        // Only act when a dominant body clearly remains, the same
                        // bar `removeStrayClusters` uses — a cut that keeps under a
                        // third of what the user circled is not trimming background.
                        if keptIndices.count >= selection.count / 3,
                           keptIndices.count < selection.count {
                            selection = PointCloudSegmenter.subset(selection, indices: keptIndices)
                        }
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
            if !keepInside {
                self.showToast("Deleted \(removed) pts")
            } else if adding {
                self.showToast("Added to selection — \(result.cloud.count) pts")
            } else {
                self.showToast("Kept \(result.cloud.count) pts · Add to pick another")
            }
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

}
