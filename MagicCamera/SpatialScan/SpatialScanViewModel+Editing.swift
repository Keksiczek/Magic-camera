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
        guard let cloud = capturedCloud, !isReconstructing else { return }
        isReconstructing = true
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
            self.isReconstructing = false
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
        guard let cloud = capturedCloud, !isMakingModel, !isReconstructing else { return }
        isMakingModel = true
        showToast("Making 3D model…")
        let cloudBox = UncheckedSendableBox(cloud)
        let keyframesBox = UncheckedSendableBox(textureKeyframes)
        let resolution = reconstructDetail.resolution
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated)
            { () -> (PointCloud, MeshData, TexturedMesh?)? in
                let isolated = PointCloudSegmenter.isolateMainSubject(cloudBox.value)?.cloud
                    ?? cloudBox.value
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
            self.isMakingModel = false
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

    /// Strips the support plane (floor/table) and keeps the main object cluster.
    func isolateSubject() {
        guard let cloud = capturedCloud, !isIsolating else { return }
        isIsolating = true
        showToast("Isolating object…")
        let box = UncheckedSendableBox(cloud)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                PointCloudSegmenter.isolateMainSubject(box.value)
            }.value
            guard let self else { return }
            self.isIsolating = false
            guard let result else {
                self.showToast("Couldn't isolate an object — scan a clearer subject")
                return
            }
            self.capturedCloud = result.cloud
            self.pointCount = result.cloud.count
            var parts: [String] = ["Kept \(result.keptPoints) pts"]
            if result.removedPlanePoints > 0 { parts.append("floor −\(result.removedPlanePoints)") }
            if result.clusterCount > 1 { parts.append("\(result.clusterCount) clusters found") }
            self.showToast(parts.joined(separator: " · "))
        }
    }

    // MARK: - Mesh clean-up

    /// Smooths the captured mesh (Taubin) on a background task for a cleaner
    /// output. Operates on the effective mesh so a structure crop is respected.
    func optimizeMesh() {
        guard let mesh = effectiveMesh, !isOptimizing else { return }
        isOptimizing = true
        showToast("Optimising surface…")
        let meshBox = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                MeshOptimizer.smooth(meshBox.value)
            }.value
            guard let self else { return }
            self.isOptimizing = false
            self.capturedMesh = result
            self.removeStructure = false
            self.pointCount = result.triangleCount
            self.showToast("Surface optimised")
        }
    }

    /// Caps small boundary holes in the captured mesh on a background task.
    func fillHoles() {
        guard let mesh = effectiveMesh, !isFillingHoles else { return }
        isFillingHoles = true
        showToast("Filling holes…")
        let meshBox = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                MeshHoleFiller.fill(meshBox.value)
            }.value
            guard let self else { return }
            self.isFillingHoles = false
            let added = result.triangleCount - mesh.triangleCount
            self.capturedMesh = result
            self.removeStructure = false
            self.pointCount = result.triangleCount
            self.showToast(added > 0 ? "Filled holes · +\(added) tris" : "No small holes found")
        }
    }

    /// Reduces mesh triangle count via vertex clustering (background).
    func decimateMesh() {
        guard let mesh = effectiveMesh, !isDecimating else { return }
        isDecimating = true
        showToast("Reducing detail…")
        let box = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let reduced = await Task.detached(priority: .userInitiated) {
                MeshDecimator.decimate(box.value)
            }.value
            guard let self else { return }
            self.isDecimating = false
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
        guard let cloud = capturedCloud, !isCleaning else { return }
        isCleaning = true
        showToast("Cleaning up…")
        let box = UncheckedSendableBox(cloud)
        Task { [weak self] in
            let cleaned = await Task.detached(priority: .userInitiated) {
                GPUPointProcessor.removeRadiusOutliers(box.value)
                    ?? PointCloudDenoiser.removeOutliers(box.value)
            }.value
            guard let self else { return }
            self.isCleaning = false
            let removed = cloud.count - cleaned.count
            self.capturedCloud = cleaned
            self.pointCount = cleaned.count
            self.showToast(removed > 0 ? "Removed \(removed) stray points" : "Already clean")
        }
    }

    /// Estimates per-point surface normals on a background task. They are cached,
    /// included automatically when the cloud is exported as PLY, and invalidated
    /// whenever the cloud changes (so re-estimate after a clean-up or merge).
    func estimateCloudNormals() {
        guard let cloud = capturedCloud, !isEstimatingNormals else { return }
        guard capturedCloudNormals == nil else {
            showToast("Normals already estimated"); return
        }
        isEstimatingNormals = true
        showToast("Estimating normals…")
        let box = UncheckedSendableBox(cloud)
        Task { [weak self] in
            let normals = await Task.detached(priority: .userInitiated) {
                PointCloudNormals.estimate(box.value)
            }.value
            guard let self else { return }
            self.isEstimatingNormals = false
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
        guard let base = capturedCloud, !isMergingBusy, !incoming.isEmpty else { return }
        isMergingBusy = true
        showToast("Merging scan…")
        let baseBox = UncheckedSendableBox(base)
        let incomingBox = UncheckedSendableBox(incoming)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ICPRegistration.merge(newScan: incomingBox.value, into: baseBox.value)
            }.value
            guard let self else { return }
            self.isMergingBusy = false
            self.capturedCloud = result.cloud
            self.pointCount = result.cloud.count
            let overlap = Int((result.fitness * 100).rounded())
            self.showToast("Merged · \(result.cloud.count) pts · \(overlap)% overlap")
        }
    }
}
