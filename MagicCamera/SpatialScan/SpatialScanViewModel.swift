//
//  SpatialScanViewModel.swift
//  Magic Camera
//
//  Drives Mode 2: owns the point-cloud recorder and the mesh collector, tracks
//  the scan phase + chosen scan kind / quality, and handles save, load and
//  export of results.
//

import Observation
import SwiftUI

enum ScanKind: String, CaseIterable, Identifiable {
    case points = "Point Cloud"
    case mesh = "Mesh"
    var id: String { rawValue }
    var systemImage: String { self == .points ? "circle.grid.3x3.fill" : "grid" }
}

/// Detail level for cloud → surface reconstruction. LiDAR mesh resolution is
/// fixed by ARKit, but a point cloud can be re-meshed at any density: a finer
/// voxel lattice keeps more shape detail (at the cost of triangle count + time).
enum MeshDetail: String, CaseIterable, Identifiable {
    case draft = "Draft"
    case standard = "Standard"
    case detailed = "Detailed"
    var id: String { rawValue }

    /// Approximate voxel count along the longest axis passed to PointCloudMesher.
    var resolution: Int {
        switch self {
        case .draft:    return 56
        case .standard: return 80
        case .detailed: return 120
        }
    }
}

enum ScanQuality: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case detailed = "Detailed"
    case ultra = "Ultra"
    var id: String { rawValue }

    var config: ScanConfig {
        switch self {
        case .fast:
            return ScanConfig(frameStride: 4, pixelStride: 3, minConfidence: 1,
                              voxelSize: 0.020, maxPoints: 300_000, maxDepth: 5.0)
        case .balanced:
            return ScanConfig(frameStride: 3, pixelStride: 2, minConfidence: 1,
                              voxelSize: 0.012, maxPoints: 600_000, maxDepth: 5.0)
        case .detailed:
            return ScanConfig(frameStride: 2, pixelStride: 1, minConfidence: 2,
                              voxelSize: 0.008, maxPoints: 1_200_000, maxDepth: 4.0)
        case .ultra:
            return ScanConfig(frameStride: 2, pixelStride: 1, minConfidence: 1,
                              voxelSize: 0.005, maxPoints: 2_000_000, maxDepth: 4.0)
        }
    }
}

@MainActor
@Observable
final class SpatialScanViewModel {
    enum Phase: Equatable { case idle, scanning, finishing, reviewing }

    var phase: Phase = .idle
    var scanKind: ScanKind = .points
    var quality: ScanQuality = .balanced
    var reconstructDetail: MeshDetail = .standard
    var pointCount = 0
    var colorMode: PointColorMode = .rgb
    var meshColorMode: MeshColorMode = .shaded
    var pointSize: CGFloat = 6
    var capturedCloud: PointCloud? {
        // Per-point normals are indexed to a specific cloud, so any change to the
        // cloud (new scan, clean-up, merge, retarget, reconstruct) invalidates them.
        didSet { capturedCloudNormals = nil }
    }
    var capturedMesh: MeshData?
    var toast: String?
    var exportURL: URL?
    var arQuickLookURL: URL?
    /// Live scan confidence in [0,1] — 0 = poor / no signal, 1 = high confidence.
    /// Updated while scanning when adaptive stride is active; reset on discard.
    var scanConfidence: Float = 0
    /// Live coverage estimate in [0,1] — 0 = still sweeping fresh surface, 1 = the
    /// visible area is largely captured. Updated while scanning; reset on discard.
    var scanCoverage: Float = 0
    /// Cached per-point normals for the captured cloud, included in PLY export when
    /// present. Estimated on demand, invalidated whenever the cloud changes.
    var capturedCloudNormals: [SIMD3<Float>]?
    var isEstimatingNormals = false

    // Tap-to-target: restrict a point-cloud scan to a region around a tapped point.
    var hasScanTarget = false
    var scanTargetRadius: Float = 0.6

    // Structure removal: strip walls/floor/ceiling from a classified mesh.
    var removeStructure = false {
        didSet { rebuildCrop() }
    }

    // Surface reconstruction: turning a point cloud into a mesh (off the main thread).
    var isReconstructing = false
    // Surface optimisation: Taubin-smoothing a captured mesh (off the main thread).
    var isOptimizing = false
    // Hole filling: capping small boundary loops in a captured mesh.
    var isFillingHoles = false
    // Multi-scan merge: ICP-aligning a second cloud into the current one.
    var isMergingBusy = false
    // Background cleanup / decimation / turntable export.
    var isCleaning = false
    var isDecimating = false
    var isExportingVideo = false

    @ObservationIgnored let recorder = ScanRecorder()
    @ObservationIgnored let meshCollector = MeshAnchorCollector()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var croppedMesh: MeshData?

    var isSupported: Bool { DeviceCapabilities.supportsSceneDepth }
    var supportsMesh: Bool { DeviceCapabilities.supportsSceneReconstruction }
    var isScanning: Bool { phase == .scanning }
    var isFinishing: Bool { phase == .finishing }
    var hasResult: Bool { capturedCloud != nil || capturedMesh != nil }
    var meshIsClassified: Bool { capturedMesh?.hasClassification ?? false }
    var canRemoveStructure: Bool { capturedMesh?.hasClassification ?? false }

    /// The mesh to display, export and measure — the structure-stripped crop when
    /// `removeStructure` is on, otherwise the captured mesh.
    var effectiveMesh: MeshData? {
        (removeStructure ? croppedMesh : nil) ?? capturedMesh
    }

    /// Bounding-box extents of the current result, in metres (width × height × depth).
    var dimensions: SIMD3<Float>? {
        if let box = effectiveMesh?.boundingBox() ?? capturedCloud?.boundingBox() {
            return box.max - box.min
        }
        return nil
    }

    private func rebuildCrop() {
        guard removeStructure, let mesh = capturedMesh, mesh.hasClassification else {
            croppedMesh = nil
            return
        }
        croppedMesh = mesh.removingSurfaces([.wall, .floor, .ceiling])
    }

    var dimensionsText: String? {
        guard let d = dimensions else { return nil }
        return MeasurementFormat.dimensions(d)
    }

    /// Estimated enclosed volume for a mesh (≈, since LiDAR meshes may be open).
    var volumeText: String? {
        guard let mesh = effectiveMesh else { return nil }
        let v = mesh.volume()
        guard v > 0.0001 else { return nil }
        return "≈ " + MeasurementFormat.volume(v)
    }

    init() {
        quality = AppSettings.shared.defaultQuality
        recorder.onProgress = { [weak self] count in
            self?.pointCount = count
        }
        recorder.onQualityUpdate = { [weak self] confidence in
            self?.scanConfidence = confidence
        }
        recorder.onCoverageUpdate = { [weak self] coverage in
            self?.scanCoverage = coverage
        }
    }

    // MARK: - Scan lifecycle

    func startScan() {
        capturedCloud = nil
        capturedMesh = nil
        pointCount = 0
        scanConfidence = 0
        scanCoverage = 0
        if scanKind == .points {
            recorder.configure(quality.config)
        }
        meshCollector.reset()
        phase = .scanning
    }

    /// Finalises a scan. The heavy work (outlier filtering a million-point cloud,
    /// or stitching every mesh anchor) runs off the main thread — doing it inline
    /// previously blocked the main thread past the 5s watchdog and SIGKILLed the
    /// app. While it runs the phase is `.finishing` so capture stops and the UI
    /// shows a spinner.
    func stopScan() {
        guard phase == .scanning else { return }
        phase = .finishing
        switch scanKind {
        case .points:
            let recorder = self.recorder   // ScanRecorder is Sendable (lock-guarded)
            Task { [weak self] in
                let cloud = await Task.detached(priority: .userInitiated) {
                    recorder.snapshotDenoised(minNeighbors: 2)
                }.value
                self?.finishPointScan(cloud)
            }
        case .mesh:
            let collector = self.meshCollector
            Task { [weak self] in
                let mesh = await Task.detached(priority: .userInitiated) {
                    collector.snapshot()
                }.value
                self?.finishMeshScan(mesh)
            }
        }
    }

    private func finishPointScan(_ cloud: PointCloud) {
        guard phase == .finishing else { return }   // discarded mid-finish
        pointCount = cloud.count
        if cloud.isEmpty {
            phase = .idle
            showToast("No points captured — scan textured surfaces up close")
        } else {
            capturedCloud = cloud
            phase = .reviewing
        }
    }

    private func finishMeshScan(_ mesh: MeshData) {
        guard phase == .finishing else { return }
        if mesh.isEmpty {
            phase = .idle
            showToast("No mesh captured — sweep the space slowly")
        } else {
            capturedMesh = mesh
            removeStructure = false
            pointCount = mesh.triangleCount
            phase = .reviewing
        }
    }

    func discard() {
        capturedCloud = nil
        capturedMesh = nil
        removeStructure = false
        pointCount = 0
        scanConfidence = 0
        scanCoverage = 0
        recorder.reset()
        meshCollector.reset()
        hasScanTarget = false
        phase = .idle
    }

    /// Zeroes everything captured so far while staying in the scanning session —
    /// a mid-scan "start over" so the user can re-do a take without going back to
    /// the setup screen. Keeps the current scan kind, quality and ROI target.
    func restartScan() {
        guard phase == .scanning else { return }
        pointCount = 0
        scanConfidence = 0
        scanCoverage = 0
        switch scanKind {
        case .points: recorder.clearAccumulation()   // keeps the ROI region/target
        case .mesh:   meshCollector.reset()
        }
        showToast("Scan reset — keep moving to rebuild")
    }

    // MARK: - Scan target (region of interest)

    func setScanTarget(_ center: SIMD3<Float>) {
        recorder.setRegion(center: center, radius: scanTargetRadius)
        // Restart accumulation so the result is just the subject, not what was
        // already captured around it.
        recorder.clearAccumulation()
        pointCount = 0
        hasScanTarget = true
        showToast(String(format: "Target set — scanning within %.1f m", scanTargetRadius))
    }

    func updateScanTargetRadius(_ radius: Float) {
        scanTargetRadius = radius
        recorder.setRegionRadius(radius)
    }

    func clearScanTarget() {
        recorder.clearRegion()
        hasScanTarget = false
        showToast("Target cleared — scanning everything")
    }

    // MARK: - Load (from gallery)

    func loadSaved(_ cloud: PointCloud) {
        capturedMesh = nil
        capturedCloud = cloud
        removeStructure = false
        scanKind = .points
        pointCount = cloud.count
        phase = .reviewing
    }

    func loadSavedMesh(_ mesh: MeshData) {
        capturedCloud = nil
        capturedMesh = mesh
        removeStructure = false
        scanKind = .mesh
        pointCount = mesh.triangleCount
        meshColorMode = mesh.hasClassification ? .classification : .shaded
        phase = .reviewing
    }

    // MARK: - Save / export

    func savePointCloud() {
        guard let cloud = capturedCloud else { return }
        do {
            let url = try ScanStore.save(cloud, name: ScanStore.defaultName())
            if let png = ThumbnailRenderer.png(for: cloud) { Thumbnails.write(png, for: url) }
            showToast("Scan saved")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    func saveMesh() {
        guard let mesh = effectiveMesh else { return }
        do {
            let url = try MeshStore.save(mesh, name: MeshStore.defaultName())
            if let png = ThumbnailRenderer.png(for: mesh) { Thumbnails.write(png, for: url) }
            showToast("Mesh saved")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    func save() {
        if capturedMesh != nil { saveMesh() } else { savePointCloud() }
    }

    // MARK: - AR Quick Look

    /// Export the captured result to a temporary USDZ and present it in AR Quick
    /// Look — meshes as a surface, point clouds as placeable point geometry.
    func presentARQuickLook() {
        do {
            if let mesh = effectiveMesh {
                arQuickLookURL = try MeshExporter.write(mesh, format: .usdz, filename: "MagicCamera-ar")
            } else if let cloud = capturedCloud {
                arQuickLookURL = try PointCloudUSDZExporter.write(cloud, filename: "MagicCamera-ar")
            }
        } catch {
            showToast("AR preview failed: \(error.localizedDescription)")
        }
    }

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

    // MARK: - Surface reconstruction (point cloud → mesh)

    /// Reconstructs a surface mesh from the captured cloud on a background task,
    /// then switches the review over to the mesh (with its AR / export tooling).
    func reconstructMesh() {
        guard let cloud = capturedCloud, !isReconstructing else { return }
        isReconstructing = true
        showToast("Reconstructing surface…")
        let cloudBox = UncheckedSendableBox(cloud)
        let resolution = reconstructDetail.resolution
        Task { [weak self] in
            let mesh = await Task.detached(priority: .userInitiated) {
                PointCloudMesher.reconstruct(cloudBox.value, resolution: resolution)
            }.value
            guard let self else { return }
            self.isReconstructing = false
            guard let mesh, !mesh.isEmpty else {
                self.showToast("Couldn't build a surface — scan more densely")
                return
            }
            self.capturedCloud = nil
            self.capturedMesh = mesh
            self.removeStructure = false
            self.scanKind = .mesh
            self.meshColorMode = .shaded
            self.pointCount = mesh.triangleCount
            self.showToast("Surface ready · \(mesh.triangleCount) tris")
        }
    }

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

    // MARK: - Cleanup / decimation / turntable

    /// Statistical outlier removal on the captured cloud (background).
    func cleanUpCloud() {
        guard let cloud = capturedCloud, !isCleaning else { return }
        isCleaning = true
        showToast("Cleaning up…")
        let box = UncheckedSendableBox(cloud)
        Task { [weak self] in
            let cleaned = await Task.detached(priority: .userInitiated) {
                PointCloudDenoiser.removeOutliers(box.value)
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

    /// Renders a spinning turntable video of the mesh and saves it (background).
    func exportTurntable() {
        guard let mesh = effectiveMesh, !isExportingVideo else { return }
        isExportingVideo = true
        showToast("Rendering turntable…")
        let colorMode = meshColorMode
        let box = UncheckedSendableBox(mesh)
        Task { [weak self] in
            let url = await Task.detached(priority: .userInitiated) {
                await TurntableVideoBuilder.make(mesh: box.value, colorMode: colorMode,
                                                 size: CGSize(width: 1080, height: 1080))
            }.value
            guard let self else { return }
            self.isExportingVideo = false
            guard let url else { self.showToast("Turntable failed"); return }
            let ok = await MediaSaver.saveVideo(url)
            self.showToast(ok ? "Turntable saved" : "Save failed — check Photos permission")
        }
    }

    // MARK: - Multi-scan merge (ICP)

    /// ICP-aligns a saved point cloud into the current one for a more complete
    /// capture. Works best when the two scans overlap and share orientation.
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

    // MARK: - Toast

    /// Public entry point for transient hints from the AR coordinator.
    func showScanHint(_ message: String) { showToast(message) }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
