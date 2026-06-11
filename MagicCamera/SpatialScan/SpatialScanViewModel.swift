//
//  SpatialScanViewModel.swift
//  Magic Camera
//
//  Drives Mode 2: owns the point-cloud recorder and the mesh collector, and
//  tracks the scan phase + chosen scan kind / quality. Split across files to
//  stay readable:
//    SpatialScanViewModel.swift          — state, scan lifecycle, autosave/recovery
//    SpatialScanViewModel+Editing.swift  — review-time edits (reconstruct, clean…)
//    SpatialScanViewModel+Export.swift   — save, AR Quick Look, exports, texture
//

import Observation
import SwiftUI

/// Screen-space circle of the projected ROI sphere (points, while scanning).
struct ROIScreenCircle: Equatable {
    var center: CGPoint
    var radius: CGFloat
}

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

/// Algorithm used to turn a point cloud into a surface mesh.
enum ReconstructionMethod: String, CaseIterable, Identifiable {
    case voxel = "Voxel"
    case smooth = "Smooth"
    case ballPivot = "Ball-Pivot"
    case fusion = "Fusion"
    var id: String { rawValue }

    var hint: String {
        switch self {
        case .voxel:     return "Fast & robust — slightly blocky"
        case .smooth:    return "Poisson-style smooth surface"
        case .ballPivot: return "Interpolating — keeps fine detail"
        case .fusion:    return "TSDF ray-carved — best right after a scan"
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
    var reconstructMethod: ReconstructionMethod = .voxel
    var pointCount = 0
    var colorMode: PointColorMode = .rgb
    var meshColorMode: MeshColorMode = .shaded
    var pointSize: CGFloat = 6
    var capturedCloud: PointCloud? {
        // Per-point normals and view directions are indexed to a specific cloud,
        // so any change (new scan, clean-up, merge, reconstruct) invalidates them.
        didSet {
            capturedCloudNormals = nil
            capturedViewDirections = nil
        }
    }
    /// Mean camera→point view direction per point, captured by the recorder —
    /// drives the ray-carved Fusion reconstruction. Index-aligned to
    /// `capturedCloud`; nil once the cloud is edited or loaded from disk.
    @ObservationIgnored var capturedViewDirections: [SIMD3<Float>]?
    var capturedMesh: MeshData? {
        // A baked texture is indexed to specific mesh vertices, so any change to
        // the mesh (optimise, decimate, fill holes, new scan) invalidates it.
        didSet { texturedMesh = nil }
    }
    /// Mesh + UV atlas baked from the keyframe photos / source cloud, used by
    /// the textured exports and AR Quick Look until the mesh changes again.
    var texturedMesh: TexturedMesh?
    /// Pending crash-recovery snapshot found at launch (offered in the UI once).
    var pendingRecovery: ScanAutoSave.Pending?
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
    /// Screen-space projection of the ROI sphere, updated live by the AR
    /// coordinator so the focus overlay tracks the subject instead of sitting
    /// in the middle of the screen. Nil when the target is off-screen/behind.
    var roiScreenCircle: ROIScreenCircle?

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
    // Object isolation (plane removal + clustering) on the captured cloud.
    var isIsolating = false
    // Texture/UV baking onto the reconstructed mesh.
    var isBakingTexture = false
    // Web viewer (HTML) export.
    var isExportingWeb = false
    // One-tap pipeline: isolate → reconstruct → texture.
    var isMakingModel = false

    @ObservationIgnored let recorder = ScanRecorder()
    @ObservationIgnored let meshCollector = MeshAnchorCollector()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var croppedMesh: MeshData?
    /// Cloud the current mesh was reconstructed from — fallback colour source
    /// for texture baking. Cleared when a new scan starts or a mesh is loaded.
    @ObservationIgnored var textureSourceCloud: PointCloud?
    /// Keyframe photos captured during the last point scan — the primary
    /// texture source (photo texturing beats point colours by a wide margin).
    @ObservationIgnored var textureKeyframes: [ScanKeyframe] = []
    @ObservationIgnored private var autoSaveTask: Task<Void, Never>?

    var isSupported: Bool { DeviceCapabilities.supportsSceneDepth }
    var supportsMesh: Bool { DeviceCapabilities.supportsSceneReconstruction }
    var isScanning: Bool { phase == .scanning }
    var isFinishing: Bool { phase == .finishing }
    var hasResult: Bool { capturedCloud != nil || capturedMesh != nil }
    var meshIsClassified: Bool { capturedMesh?.hasClassification ?? false }
    var canRemoveStructure: Bool { capturedMesh?.hasClassification ?? false }
    /// Texture baking needs a colour source — keyframe photos or the source cloud.
    var canBakeTexture: Bool {
        capturedMesh != nil && (textureSourceCloud != nil || !textureKeyframes.isEmpty)
    }

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
        pendingRecovery = ScanAutoSave.pending()
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
        textureSourceCloud = nil
        textureKeyframes = []
        pointCount = 0
        scanConfidence = 0
        scanCoverage = 0
        if scanKind == .points {
            recorder.configure(quality.config)
        }
        meshCollector.reset()
        phase = .scanning
        startAutoSave()
    }

    /// Periodically snapshots the in-progress scan to disk so a crash or
    /// watchdog kill mid-scan loses at most one interval of work.
    private func startAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard let self, self.phase == .scanning else { return }
                switch self.scanKind {
                case .points:
                    let recorder = self.recorder
                    Task.detached(priority: .utility) {
                        ScanAutoSave.saveCloud(recorder.snapshot())
                    }
                case .mesh:
                    let collector = self.meshCollector
                    Task.detached(priority: .utility) {
                        ScanAutoSave.saveMesh(collector.snapshot())
                    }
                }
            }
        }
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
                let result = await Task.detached(priority: .userInitiated) {
                    recorder.snapshotDenoised(minNeighbors: 2)
                }.value
                self?.finishPointScan(result.cloud, viewDirections: result.viewDirections)
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

    private func finishPointScan(_ cloud: PointCloud, viewDirections: [SIMD3<Float>]) {
        guard phase == .finishing else { return }   // discarded mid-finish
        autoSaveTask?.cancel()
        pointCount = cloud.count
        if cloud.isEmpty {
            phase = .idle
            showToast("No points captured — scan textured surfaces up close")
        } else {
            capturedCloud = cloud   // didSet clears the directions — set after
            capturedViewDirections = viewDirections.count == cloud.count ? viewDirections : nil
            textureKeyframes = recorder.snapshotKeyframes()
            phase = .reviewing
            // Snapshot the final result too: it is in memory but not yet saved.
            let box = UncheckedSendableBox(cloud)
            Task.detached(priority: .utility) { ScanAutoSave.saveCloud(box.value) }
        }
    }

    private func finishMeshScan(_ mesh: MeshData) {
        guard phase == .finishing else { return }
        autoSaveTask?.cancel()
        if mesh.isEmpty {
            phase = .idle
            showToast("No mesh captured — sweep the space slowly")
        } else {
            capturedMesh = mesh
            removeStructure = false
            pointCount = mesh.triangleCount
            phase = .reviewing
            let box = UncheckedSendableBox(mesh)
            Task.detached(priority: .utility) { ScanAutoSave.saveMesh(box.value) }
        }
    }

    func discard() {
        capturedCloud = nil
        capturedMesh = nil
        textureSourceCloud = nil
        textureKeyframes = []
        removeStructure = false
        pointCount = 0
        scanConfidence = 0
        scanCoverage = 0
        recorder.reset()
        meshCollector.reset()
        hasScanTarget = false
        phase = .idle
        autoSaveTask?.cancel()
        ScanAutoSave.clear()
    }

    // MARK: - Crash recovery

    /// Restores the autosaved snapshot found at launch into the review screen.
    func restoreAutosave() {
        guard let pending = pendingRecovery else { return }
        pendingRecovery = nil
        Task { [weak self] in
            switch pending {
            case .cloud:
                let cloud = await Task.detached(priority: .userInitiated) {
                    ScanAutoSave.restoreCloud()
                }.value
                guard let self else { return }
                if let cloud, !cloud.isEmpty {
                    self.loadSaved(cloud)
                    self.showToast("Recovered unsaved scan · \(cloud.count) pts")
                } else {
                    self.showToast("Couldn't restore the unsaved scan")
                    ScanAutoSave.clear()
                }
            case .mesh:
                let mesh = await Task.detached(priority: .userInitiated) {
                    ScanAutoSave.restoreMesh()
                }.value
                guard let self else { return }
                if let mesh, !mesh.isEmpty {
                    self.loadSavedMesh(mesh)
                    self.showToast("Recovered unsaved mesh · \(mesh.triangleCount) tris")
                } else {
                    self.showToast("Couldn't restore the unsaved mesh")
                    ScanAutoSave.clear()
                }
            }
        }
    }

    /// Dismisses the recovery offer and deletes the snapshot.
    func discardAutosave() {
        pendingRecovery = nil
        ScanAutoSave.clear()
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
        textureSourceCloud = nil
        textureKeyframes = []
        removeStructure = false
        scanKind = .points
        pointCount = cloud.count
        phase = .reviewing
    }

    func loadSavedMesh(_ mesh: MeshData, textured: TexturedMesh? = nil) {
        capturedCloud = nil
        capturedMesh = mesh          // didSet clears texturedMesh — restore after
        texturedMesh = textured
        textureSourceCloud = nil
        textureKeyframes = []
        removeStructure = false
        scanKind = .mesh
        pointCount = mesh.triangleCount
        meshColorMode = mesh.hasClassification ? .classification : .shaded
        phase = .reviewing
    }

    // MARK: - Toast

    /// Public entry point for transient hints from the AR coordinator.
    func showScanHint(_ message: String) { showToast(message) }

    /// Transient status message (auto-dismisses). Internal so the editing and
    /// export extensions can report results.
    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
