//
//  SpatialScanViewModel+Editing.swift
//  Magic Camera
//
//  Whole-model operations: Smart finish, merging two scans through ICP, and
//  placing a saved scan into the current one.
//
//  Reconstruction lives in +Reconstruction, the destructive edits in
//  +Cleanup, and the lattice sizing in +Lattice.
//

import SwiftUI

extension SpatialScanViewModel {

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
        // Same rule as the reconstruction path: never flatten a subject's planes.
        // Here the trap is sharper — the branch below picks "open surface" from
        // the mesh's own thinness, so a subject that came out too shallow gets
        // routed to the room finish, which then flattens it the rest of the way.
        let flattenPlanes = captureProfile.subject != .object
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
                    // The full clean finish: denoise → flatten walls/floor. It smooths
                    // internally, so the object-branch smooth pass is skipped here.
                    m = SurfaceCleanup.clean(m, seedPlanes: scenePlanes,
                                             flattenPlanes: flattenPlanes).mesh
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

    // MARK: - Transform helper

    /// T(center) · M · T(−center): applies `m` about a pivot. Model Studio's rotate
    /// and scale tools call it, which is why it outlived the review-screen transforms.
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
