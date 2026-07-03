//
//  SpatialScanViewModel+Export.swift
//  Magic Camera
//
//  Saving to the scan library, AR Quick Look, texture baking and every export
//  path (point cloud, mesh, textured mesh, web viewer, turntable video).
//

import SwiftUI

extension SpatialScanViewModel {

    // MARK: - Save to library

    func savePointCloud() {
        guard let cloud = capturedCloud else { return }
        do {
            // Persist the view rays alongside the cloud (v2 .mcscan) so reopening
            // this scan from the gallery rebuilds with fusion-rays, not est-normals.
            let url = try ScanStore.save(cloud, name: ScanStore.defaultName(),
                                         directions: capturedViewDirections)
            // Keyframes ride along as a sidecar so a reopened scan can still
            // photo-texture (without them it silently fell back to soft
            // point-colour baking).
            ScanKeyframeStore.save(textureKeyframes, for: url)
            if let png = ThumbnailRenderer.png(for: cloud) { Thumbnails.write(png, for: url) }
            showToast("Scan saved")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    func saveMesh() {
        // When a texture is baked, persist the textured variant (its duplicated-
        // corner mesh + UVs + atlas) so it reloads textured from the gallery.
        // The structure crop never matches the baked texture, so skip it then.
        let textured = removeStructure ? nil : texturedMesh
        guard let mesh = textured?.mesh ?? effectiveMesh else { return }
        do {
            let url = try MeshStore.save(mesh, textured: textured, name: MeshStore.defaultName())
            if let png = ThumbnailRenderer.png(for: mesh) { Thumbnails.write(png, for: url) }
            showToast(textured != nil ? "Textured mesh saved" : "Mesh saved")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    func save() {
        if capturedMesh != nil { saveMesh() } else { savePointCloud() }
        // The result now lives in the scan library — drop the crash snapshot.
        ScanAutoSave.clear()
    }

    // MARK: - Hand off to Model Studio

    /// Drops the current mesh (with its baked texture, when present) straight
    /// onto the Model Studio stage. Uses the same mesh source as `saveMesh()` so
    /// what lands in Studio matches what would be saved/exported. Studio only
    /// works with meshes, so this is offered only once a mesh exists.
    func sendToStudio() {
        let textured = removeStructure ? nil : texturedMesh
        guard let mesh = textured?.mesh ?? effectiveMesh else {
            showToast("Reconstruct a mesh first, then send it to Studio")
            return
        }
        AppRouter.shared.openInModelStudio(.mesh(mesh, textured))
    }

    // MARK: - AR Quick Look

    /// Export the captured result to a temporary USDZ and present it in AR Quick
    /// Look — meshes as a surface (textured when baked), point clouds as
    /// placeable point geometry.
    func presentARQuickLook() {
        do {
            if let textured = texturedMesh {
                arQuickLookURL = try TexturedMeshExporter.write(textured, format: .usdz,
                                                                filename: "MagicCamera-ar")
            } else if let mesh = effectiveMesh {
                arQuickLookURL = try MeshExporter.write(mesh, format: .usdz, filename: "MagicCamera-ar")
            } else if let cloud = capturedCloud {
                arQuickLookURL = try PointCloudUSDZExporter.write(cloud, filename: "MagicCamera-ar")
            }
        } catch {
            showToast("AR preview failed: \(error.localizedDescription)")
        }
    }

    // MARK: - File exports

    func exportPointCloud(format: PointCloudExporter.Format) {
        guard let cloud = capturedCloud else { return }
        // Normals (when estimated) are written into PLY; ignored by other formats.
        do { exportURL = try PointCloudExporter.write(cloud, format: format, normals: capturedCloudNormals) }
        catch { showToast("Export failed: \(error.localizedDescription)") }
    }

    /// Export the captured cloud as USDZ point geometry (kept separate from the
    /// pure-Foundation PointCloudExporter, which doesn't depend on ModelIO).
    func exportPointCloudUSDZ() {
        guard let cloud = capturedCloud else { return }
        do { exportURL = try PointCloudUSDZExporter.write(cloud) }
        catch { showToast("Export failed: \(error.localizedDescription)") }
    }

    func exportMesh(format: MeshExporter.Format) {
        guard let mesh = effectiveMesh else { return }
        do { exportURL = try MeshExporter.write(mesh, format: format) }
        catch { showToast("Export failed: \(error.localizedDescription)") }
    }

    /// Exports the baked textured mesh (GLB / USDZ with the colour atlas).
    func exportTextured(format: TexturedMeshExporter.Format) {
        guard let textured = texturedMesh else { return }
        do { exportURL = try TexturedMeshExporter.write(textured, format: format) }
        catch { showToast("Export failed: \(error.localizedDescription)") }
    }

    // MARK: - Texture / UV baking

    /// Bakes a colour atlas for the current mesh: keyframe photos when the scan
    /// captured them (sharpest), otherwise the source cloud's point colours.
    /// Enables the textured GLB/USDZ exports and textured AR Quick Look.
    func bakeTexture() {
        guard let mesh = effectiveMesh else { return }
        let cloud = textureSourceCloud
        let keyframes = textureKeyframes
        guard cloud != nil || !keyframes.isEmpty else { return }
        guard texturedMesh == nil else {
            showToast("Texture already baked"); return
        }
        let meshBox = UncheckedSendableBox(mesh)
        let cloudBox = UncheckedSendableBox(cloud)
        let keyframesBox = UncheckedSendableBox(keyframes)
        // Re-bakes must keep the variable-resolution pairing: an adaptive mesh has
        // big flat-wall triangles that only stay sharp with the area-proportional
        // atlas — the uniform grid gives them the same few texels as a tiny detail
        // triangle and the walls come back blurry (the 07-03 re-bake regression).
        let adaptive = ReconstructionSettings.adaptiveEnabled
        runOperation(.bakingTexture,
                     startingToast: keyframes.isEmpty ? "Baking texture…" : "Baking photo texture…",
                     failureToast: "Texture baking failed") { () -> TexturedMesh? in
            // Bound the per-triangle bake so a huge Build-Surface mesh can't run
            // the ~90 s CPU watchdog (it took ~4 min on a 243 k-tri mesh). The
            // texture carries the detail, so the decimated result looks the same.
            let mesh = SpatialScanViewModel.boundedForBake(
                meshBox.value,
                budget: adaptive ? SpatialScanViewModel.adaptiveBakeTriangleBudget
                                 : SpatialScanViewModel.photoBakeTriangleBudget,
                preservingDetail: adaptive)
            if !keyframesBox.value.isEmpty,
               let photo = PhotoTextureBaker.bake(mesh: mesh,
                                                  keyframes: keyframesBox.value,
                                                  fallbackCloud: cloudBox.value,
                                                  areaProportional: adaptive) {
                return photo
            }
            guard let cloud = cloudBox.value else { return nil }
            return MeshTextureBaker.bake(mesh: mesh, cloud: cloud)
        } completion: { [weak self] result in
            guard let self else { return }
            self.texturedMesh = result
            self.showToast("Texture baked · \(result.mesh.triangleCount) tris · "
                           + "\(result.textureSize)×\(result.textureSize)")
        }
    }

    // MARK: - Web viewer

    /// Exports a self-contained HTML viewer (three.js + embedded model).
    func exportWebViewer() {
        let textured = texturedMesh
        let mesh = effectiveMesh
        let cloud = capturedCloud
        guard textured != nil || mesh != nil || cloud != nil else { return }
        let texturedBox = UncheckedSendableBox(textured)
        let meshBox = UncheckedSendableBox(mesh)
        let cloudBox = UncheckedSendableBox(cloud)
        runOperation(.exportingWeb,
                     startingToast: "Building web viewer…",
                     failureToast: "Web export failed") { () -> URL? in
            if let textured = texturedBox.value {
                return try? WebViewerExporter.write(textured: textured)
            }
            if let mesh = meshBox.value {
                return try? WebViewerExporter.write(mesh: mesh)
            }
            if let cloud = cloudBox.value {
                return try? WebViewerExporter.write(cloud: cloud)
            }
            return nil
        } completion: { [weak self] url in
            self?.exportURL = url
        }
    }

    // MARK: - Turntable video

    /// Renders a spinning turntable video of the mesh and saves it (background).
    /// Kept hand-rolled (not `runOperation`): it needs a second `await`
    /// (`MediaSaver.saveVideo`) *after* the detached render, which the
    /// synchronous-completion runner can't express.
    func exportTurntable() {
        guard let mesh = effectiveMesh, beginOperation(.exportingVideo) else { return }
        showToast("Rendering turntable…")
        let colorMode = meshColorMode
        let box = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let url = await Task.detached(priority: .userInitiated) {
                await TurntableVideoBuilder.make(mesh: box.value, colorMode: colorMode,
                                                 size: CGSize(width: 1080, height: 1080))
            }.value
            guard let self else { return }
            self.endOperation()
            guard let url else { self.showToast("Turntable failed"); return }
            let ok = await MediaSaver.saveVideo(url)
            self.showToast(ok ? "Turntable saved" : "Save failed — check Photos permission")
        }
    }
}
