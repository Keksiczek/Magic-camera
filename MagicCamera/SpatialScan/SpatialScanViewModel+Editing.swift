//
//  SpatialScanViewModel+Editing.swift
//  Magic Camera
//
//  Review-time editing operations — every one runs its heavy work on a
//  detached background task and reports back through the observable state.
//

import SwiftUI

extension SpatialScanViewModel {

    // MARK: - Surface reconstruction (point cloud → mesh)

    /// Reconstructs a surface mesh from the captured cloud on a background task
    /// using the selected method (voxel / Poisson-style smooth / ball-pivoting),
    /// then switches the review over to the mesh (with its AR / export tooling).
    /// The source cloud is kept aside as the colour source for texture baking.
    func reconstructMesh() {
        guard let cloud = capturedCloud, beginOperation(.reconstructing) else { return }
        showToast("Reconstructing surface…")
        let cloudBox = UncheckedSendableBox(cloud)
        let normalsBox = UncheckedSendableBox(capturedCloudNormals)
        let directionsBox = UncheckedSendableBox(capturedViewDirections)
        let resolution = reconstructDetail.resolution
        let method = reconstructMethod
        Task { [weak self] in
            let mesh = await Task.detached(priority: .userInitiated) { () -> MeshData? in
                switch method {
                case .voxel:
                    return PointCloudMesher.reconstruct(cloudBox.value, resolution: resolution)
                case .smooth:
                    return SmoothSurfaceReconstructor.reconstruct(
                        cloudBox.value, resolution: resolution + 16, normals: normalsBox.value)
                case .ballPivot:
                    return BallPivotingMesher.reconstruct(cloudBox.value, normals: normalsBox.value)
                case .fusion:
                    // Ray-carved TSDF: the recorder's measured view rays replace
                    // estimated normals in the signed field — the outward side is
                    // simply "toward the camera that saw the point". Falls back
                    // to estimated normals when the rays are gone (edited /
                    // gallery-loaded clouds).
                    if let directions = directionsBox.value,
                       directions.count == cloudBox.value.count {
                        return SmoothSurfaceReconstructor.reconstruct(
                            cloudBox.value, resolution: resolution + 16,
                            normals: directions.map { -$0 })
                    }
                    return SmoothSurfaceReconstructor.reconstruct(
                        cloudBox.value, resolution: resolution + 16, normals: normalsBox.value)
                }
            }.value
            guard let self else { return }
            self.endOperation()
            guard let mesh, !mesh.isEmpty else {
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
        guard let cloud = capturedCloud, beginOperation(.makingModel) else { return }
        showToast("Making 3D model…")
        let cloudBox = UncheckedSendableBox(cloud)
        let keyframesBox = UncheckedSendableBox(textureKeyframes)
        let resolution = reconstructDetail.resolution
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated)
            { () -> (PointCloud, MeshData, TexturedMesh?)? in
                // Photo-mask pre-filter (visual hull from keyframe silhouettes)
                // before the geometric isolation — same path as Isolate object.
                let masked = KeyframeSubjectFilter.filter(cloudBox.value,
                                                          keyframes: keyframesBox.value)?.cloud
                let working = masked ?? cloudBox.value
                let isolated = PointCloudSegmenter.isolateMainSubject(working)?.cloud
                    ?? working
                guard let mesh = SmoothSurfaceReconstructor.reconstruct(
                        isolated, resolution: resolution + 16)
                    ?? PointCloudMesher.reconstruct(isolated, resolution: resolution),
                    !mesh.isEmpty else { return nil }
                let textured: TexturedMesh?
                if keyframesBox.value.isEmpty {
                    textured = MeshTextureBaker.bake(mesh: mesh, cloud: isolated)
                } else {
                    textured = PhotoTextureBaker.bake(mesh: mesh,
                                                      keyframes: keyframesBox.value,
                                                      fallbackCloud: isolated)
                        ?? MeshTextureBaker.bake(mesh: mesh, cloud: isolated)
                }
                return (isolated, mesh, textured)
            }.value
            guard let self else { return }
            self.endOperation()
            guard let (isolated, mesh, textured) = result else {
                self.showToast("Couldn't build a model — scan the subject more densely")
                return
            }
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
        guard let cloud = capturedCloud, beginOperation(.isolating) else { return }
        showToast("Isolating object…")
        let box = UncheckedSendableBox(cloud)
        let keyframesBox = UncheckedSendableBox(textureKeyframes)
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated)
            { () -> (cloud: PointCloud, message: String)? in
                let masked = KeyframeSubjectFilter.filter(box.value, keyframes: keyframesBox.value)
                let working = masked?.cloud ?? box.value
                if let result = PointCloudSegmenter.isolateMainSubject(working) {
                    var parts: [String] = ["Kept \(result.keptPoints) pts"]
                    if let masked { parts.append("photo mask ×\(masked.viewsUsed)") }
                    if result.removedPlanePoints > 0 { parts.append("floor −\(result.removedPlanePoints)") }
                    if result.clusterCount > 1 { parts.append("\(result.clusterCount) clusters found") }
                    return (result.cloud, parts.joined(separator: " · "))
                }
                if let masked {
                    // Geometric pass found nothing further — the mask alone is the isolation.
                    return (masked.cloud,
                            "Photo mask ×\(masked.viewsUsed) · kept \(masked.cloud.count) pts")
                }
                return nil
            }.value
            guard let self else { return }
            self.endOperation()
            guard let outcome else {
                self.showToast("Couldn't isolate an object — scan a clearer subject")
                return
            }
            self.capturedCloud = outcome.cloud
            self.pointCount = outcome.cloud.count
            self.showToast(outcome.message)
        }
    }

    // MARK: - Mesh clean-up

    /// Smooths the captured mesh (Taubin) on a background task for a cleaner
    /// output. Operates on the effective mesh so a structure crop is respected.
    func optimizeMesh() {
        guard let mesh = effectiveMesh, beginOperation(.optimizing) else { return }
        showToast("Optimising surface…")
        let meshBox = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                MeshOptimizer.smooth(meshBox.value)
            }.value
            guard let self else { return }
            self.endOperation()
            self.capturedMesh = result
            self.removeStructure = false
            self.pointCount = result.triangleCount
            self.showToast("Surface optimised")
        }
    }

    /// Caps small boundary holes in the captured mesh on a background task.
    func fillHoles() {
        guard let mesh = effectiveMesh, beginOperation(.fillingHoles) else { return }
        showToast("Filling holes…")
        let meshBox = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                MeshHoleFiller.fill(meshBox.value)
            }.value
            guard let self else { return }
            self.endOperation()
            let added = result.triangleCount - mesh.triangleCount
            self.capturedMesh = result
            self.removeStructure = false
            self.pointCount = result.triangleCount
            self.showToast(added > 0 ? "Filled holes · +\(added) tris" : "No small holes found")
        }
    }

    /// Reduces mesh triangle count via vertex clustering (background).
    func decimateMesh() {
        guard let mesh = effectiveMesh, beginOperation(.decimating) else { return }
        showToast("Reducing detail…")
        let box = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let reduced = await Task.detached(priority: .userInitiated) {
                MeshDecimator.decimate(box.value)
            }.value
            guard let self else { return }
            self.endOperation()
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
        guard let cloud = capturedCloud, beginOperation(.cleaning) else { return }
        showToast("Cleaning up…")
        let box = UncheckedSendableBox(cloud)
        Task { [weak self] in
            let cleaned = await Task.detached(priority: .userInitiated) {
                GPUPointProcessor.removeRadiusOutliers(box.value)
                    ?? PointCloudDenoiser.removeOutliers(box.value)
            }.value
            guard let self else { return }
            self.endOperation()
            let removed = cloud.count - cleaned.count
            self.capturedCloud = cleaned
            self.pointCount = cleaned.count
            self.showToast(removed > 0 ? "Removed \(removed) stray points" : "Already clean")
        }
    }

    /// Drops low-confidence points. LiDAR returns from glossy ceramic, metal or
    /// glass scatter and multipath — and ARKit marks exactly those samples as
    /// low confidence. The fused confidence is a weighted average over every
    /// sighting, so surfaces that were ever seen reliably survive the cut.
    func removeUnreliablePoints() {
        guard let cloud = capturedCloud, beginOperation(.cleaning) else { return }
        showToast("Filtering reflections…")
        let box = UncheckedSendableBox(cloud)
        Task { [weak self] in
            let filtered = await Task.detached(priority: .userInitiated) { () -> PointCloud in
                let source = box.value
                var kept = PointCloud()
                kept.reserveCapacity(source.count)
                for i in 0..<source.count where source.confidences[i] >= 0.65 {
                    kept.append(position: source.positions[i], color: source.colors[i],
                                confidence: source.confidences[i])
                }
                return kept
            }.value
            guard let self else { return }
            self.endOperation()
            let removed = cloud.count - filtered.count
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
        guard beginOperation(.estimatingNormals) else { return }
        showToast("Estimating normals…")
        let box = UncheckedSendableBox(cloud)
        Task { [weak self] in
            let normals = await Task.detached(priority: .userInitiated) {
                PointCloudNormals.estimate(box.value)
            }.value
            guard let self else { return }
            self.endOperation()
            // Skip if the cloud changed under us during estimation.
            guard self.capturedCloud?.count == box.value.count else { return }
            self.capturedCloudNormals = normals
            self.showToast("Normals ready — included in PLY export")
        }
    }

    // MARK: - Multi-scan merge (ICP)

    /// ICP-aligns a saved point cloud into the current one for a more complete
    /// capture. Multi-start yaw seeding handles scans captured facing any way.
    func mergeSavedCloud(_ incoming: PointCloud) {
        guard let base = capturedCloud, !incoming.isEmpty, beginOperation(.merging) else { return }
        showToast("Merging scan…")
        let baseBox = UncheckedSendableBox(base)
        let incomingBox = UncheckedSendableBox(incoming)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ICPRegistration.merge(newScan: incomingBox.value, into: baseBox.value)
            }.value
            guard let self else { return }
            self.endOperation()
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
        guard let base = capturedMesh, !incoming.isEmpty, beginOperation(.merging) else { return }
        showToast("Merging mesh…")
        let baseBox = UncheckedSendableBox(base)
        let incomingBox = UncheckedSendableBox(incoming)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated)
            { () -> (mesh: MeshData, fitness: Float) in
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
            }.value
            guard let self else { return }
            self.endOperation()
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
              let position = placementPosition, beginOperation(.placing) else { return }
        showToast("Placing scan…")
        let hadTexture = texturedMesh != nil
        let baseBox = UncheckedSendableBox(base)
        let objectBox = UncheckedSendableBox(object)
        let rotation = placementRotation
        Task { [weak self] in
            let merged = await Task.detached(priority: .userInitiated) { () -> MeshData in
                let transform = Self.placementTransform(for: objectBox.value,
                                                        rotation: rotation,
                                                        position: position)
                return baseBox.value.appending(objectBox.value.transformed(by: transform))
            }.value
            guard let self else { return }
            self.endOperation()
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
