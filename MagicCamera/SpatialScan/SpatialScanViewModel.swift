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
    case ultra = "Ultra"
    var id: String { rawValue }

    /// Approximate voxel count along the longest axis passed to PointCloudMesher.
    var resolution: Int {
        switch self {
        case .draft:    return 56
        case .standard: return 80
        case .detailed: return 120
        case .ultra:    return 168   // finest triangles; needs a dense scan
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
                              voxelSize: 0.008, maxPoints: 2_000_000, maxDepth: 4.0)
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
    /// Unified quality dial: setting it cascades to the capture preset and the
    /// reconstruction defaults so the whole pipeline stays consistent. The
    /// review screen can still override detail/method individually afterwards.
    var captureQuality: CaptureQuality = .balanced {
        didSet {
            guard captureQuality != oldValue else { return }
            quality = captureQuality.scanQuality
            reconstructDetail = captureQuality.reconstructDetail
            reconstructMethod = captureQuality.reconstructMethod
        }
    }
    var reconstructDetail: MeshDetail = .standard
    var reconstructMethod: ReconstructionMethod = .voxel
    /// When on, the cloud is curvature-thinned right before reconstruction —
    /// flat regions shed points, edges stay dense — so the surface methods spend
    /// their triangle budget on detail. The colour-source cloud stays full-res.
    var adaptiveDensityPrepass = false
    /// Object-mode tuning (only used when `captureQuality == .object`). `fine`
    /// is the 2 mm "Object+" density; `objectRange` is the capture depth in m.
    var objectFine = false
    var objectRange: Float = 1.5
    /// One-shot guard so Auto-Object switches at most once per scanning session.
    @ObservationIgnored private var didAutoObject = false

    /// The capture config a point scan actually starts with — the unified
    /// profile, with Object mode's live fineness/range folded in.
    var effectiveScanConfig: ScanConfig {
        captureQuality == .object
            ? CaptureQuality.objectConfig(fine: objectFine, rangeMeters: objectRange)
            : captureQuality.scanConfig
    }
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

    // Tap-to-target: restrict a point-cloud scan to a region around a tapped point.
    var hasScanTarget = false
    var scanTargetRadius: Float = 0.6
    /// Screen-space projection of the ROI sphere, updated live by the AR
    /// coordinator so the focus overlay tracks the subject instead of sitting
    /// in the middle of the screen. Nil when the target is off-screen/behind.
    var roiScreenCircle: ROIScreenCircle?
    /// True while the AR coordinator is drawing the lifted-subject highlight —
    /// the circular ROI dim would just fight it visually, so the view hides it.
    var subjectMaskActive = false

    // Structure removal: strip walls/floor/ceiling from a classified mesh.
    var removeStructure = false {
        didSet { rebuildCrop() }
    }

    // Interactive placement of a saved scan inside the current mesh (a detailed
    // object dropped into a scanned room). The ghost lives in the viewer; Apply
    // bakes it into `capturedMesh`.
    var placementMesh: MeshData?
    var placementRotation: Float = 0          // around Y, radians
    var placementPosition: SIMD3<Float>?      // tapped point on the host mesh
    var isPlacing: Bool { placementMesh != nil }

    // Scan intelligence: generated report (drives the sheet) and the auto-fix
    // run state + its one-shot undo snapshot.
    var sceneReport: String?
    var isDescribing = false
    var isAutoFixing = false

    // Studio mode: chat-driven editing over the review state. The transcript
    // and busy flag drive the panel; the model session is type-erased because
    // FoundationModels only exists on iOS 26+ (see StudioEngine).
    var isStudioActive = false
    var isStudioBusy = false
    var studioTranscript: [StudioLine] = []
    @ObservationIgnored var studioSessionStorage: Any?
    @ObservationIgnored var autoFixBackup: AutoFixBackup? {
        didSet { hasAutoFixBackup = autoFixBackup != nil }
    }
    /// Observable mirror of `autoFixBackup` presence (the snapshot itself is
    /// big and must not be diffed by Observation).
    var hasAutoFixBackup = false

    /// The review-time background operations. Exactly one may run at a time —
    /// they all mutate (or snapshot) the same captured cloud/mesh, so running
    /// two concurrently was a data race waiting to happen, and a dozen
    /// independent `isXxx` flags made every view and guard repeat itself.
    enum Operation: Equatable {
        case reconstructing      // point cloud → surface mesh
        case makingModel         // one-tap isolate → reconstruct → texture
        case isolating           // plane removal + clustering
        case optimizing          // Taubin smoothing
        case fillingHoles        // boundary-loop capping
        case decimating          // vertex-clustering reduction
        case cleaning            // outlier removal
        case estimatingNormals   // per-point normals for PLY
        case merging             // ICP merge (cloud or mesh)
        case placing             // bake a placed scan into the host mesh
        case transforming        // scale / rotate about the model centre (Studio)
        case bakingTexture       // UV atlas + texture bake
        case exportingWeb        // self-contained HTML viewer
        case exportingVideo      // turntable render

        /// Human-readable name for the processing overlay.
        var label: String {
            switch self {
            case .reconstructing:    return "Reconstructing surface"
            case .makingModel:       return "Making 3D model"
            case .isolating:         return "Isolating object"
            case .optimizing:        return "Optimising surface"
            case .fillingHoles:      return "Filling holes"
            case .decimating:        return "Reducing detail"
            case .cleaning:          return "Cleaning up"
            case .estimatingNormals: return "Estimating normals"
            case .merging:           return "Merging scan"
            case .placing:           return "Placing scan"
            case .transforming:      return "Transforming"
            case .bakingTexture:     return "Baking texture"
            case .exportingWeb:      return "Building web viewer"
            case .exportingVideo:    return "Rendering turntable"
            }
        }
    }

    /// The single operation currently running, if any. UI spinners and
    /// disabled states all derive from this one value.
    var activeOperation: Operation?

    /// When the active operation started — drives the processing overlay's
    /// elapsed-time readout so a long job visibly keeps ticking (not frozen).
    var operationStartedAt: Date?

    var isBusy: Bool { activeOperation != nil }
    func isRunning(_ operation: Operation) -> Bool { activeOperation == operation }

    /// Claims the exclusive operation slot — the hard gate behind the UI's
    /// disabled states. Returns false when another operation is running.
    func beginOperation(_ operation: Operation) -> Bool {
        guard activeOperation == nil else { return false }
        activeOperation = operation
        operationStartedAt = Date()
        return true
    }

    func endOperation() {
        activeOperation = nil
        operationStartedAt = nil
    }

    /// Cancels any in-flight heavy reconstruction/model job and invalidates its
    /// completion. The detached job polls `Task.isCancelled` at stage boundaries
    /// and bails; bumping `workGeneration` makes a result that's already
    /// returning land on a no-op, so a discarded or restarted scan can never
    /// have a stale mesh overwrite the new state. Clearing the slot also stops
    /// the UI from staying stuck on a spinner.
    func cancelHeavyWork() {
        workGeneration &+= 1   // wrapping: never traps, even after a long session of restarts
        heavyWorkCancel?()
        heavyWorkCancel = nil
        endOperation()
    }

    /// One backbone for every review-time background operation. Each op used to
    /// hand-roll the same lifecycle — claim the slot, run heavy pure-value work
    /// on a detached task, hop back to the main actor, mutate state, toast — and
    /// only the two reconstruction paths had cancellation + stale-result
    /// protection. This funnels them through one place so every adopter is
    /// cancellable and stale-safe for free; call sites shrink to "what to
    /// compute" (`work`) + "what to do with the result" (`completion`).
    ///
    /// Folds in the whole shared lifecycle: `beginOperation` gates one op at a
    /// time; `startingToast` shows immediately; `work` runs on a cancellable
    /// `Task.detached` at `priority` (`.utility` by default — long compute
    /// shouldn't ride user-initiated QoS); `heavyWorkCancel` + the captured
    /// `workGeneration` mean a `discard()`/`startScan()` mid-run cancels the job
    /// AND drops its result instead of letting a stale mesh land on a torn-down
    /// scan; on completion the slot is released and `completion` runs only for a
    /// non-nil result (a nil result shows `failureToast` when given, else ends
    /// quietly). `T: Sendable` because the result crosses back to the main actor;
    /// long `work` closures should poll `Task.isCancelled` at stage boundaries.
    func runOperation<T: Sendable>(
        _ operation: Operation,
        startingToast: String,
        failureToast: String? = nil,
        priority: TaskPriority = .utility,
        work: @Sendable @escaping () -> T?,
        completion: @escaping @MainActor (T) -> Void
    ) {
        guard beginOperation(operation) else { return }
        showToast(startingToast)
        let generation = workGeneration
        let task = Task.detached(priority: priority) { work() }
        heavyWorkCancel = { task.cancel() }
        Task { [weak self] in
            let result = await task.value
            guard let self else { return }
            guard self.workGeneration == generation else { return }   // discarded/restarted mid-run
            self.heavyWorkCancel = nil
            self.endOperation()
            guard let result else {
                if let failureToast { self.showToast(failureToast) }
                return
            }
            completion(result)
        }
    }

    @ObservationIgnored let recorder = ScanRecorder()
    @ObservationIgnored let meshCollector = MeshAnchorCollector()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Cancels the current heavy reconstruction/model job (see cancelHeavyWork).
    /// Private — every operation now flows through `runOperation`, so nothing
    /// outside this file touches the cancellation machinery directly.
    @ObservationIgnored private var heavyWorkCancel: (() -> Void)?
    /// Bumped whenever heavy work is cancelled/superseded; a completing job
    /// compares against the value it captured to drop a stale result.
    @ObservationIgnored private var workGeneration = 0
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

    /// Upfront capture cost for the chosen quality, shown on the setup screen.
    var captureEstimateText: String { captureQuality.captureEstimate.summary }

    /// Upfront reconstruction cost for the captured cloud at the chosen detail
    /// and method — nil when there is no cloud to mesh.
    var reconstructionEstimateText: String? {
        guard let cloud = capturedCloud else { return nil }
        return QualityEstimator.reconstruction(
            cloud: cloud, detail: reconstructDetail, method: reconstructMethod).summary
    }

    init() {
        // Start from the persisted preset, mapped onto the unified dial. Property
        // observers don't fire during init, so set the capture preset and the
        // reconstruction defaults to match the chosen profile explicitly.
        let profile = CaptureQuality(scanQuality: AppSettings.shared.defaultQuality)
        captureQuality = profile
        quality = profile.scanQuality
        reconstructDetail = profile.reconstructDetail
        reconstructMethod = profile.reconstructMethod
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
        // Mesh scans reuse `pointCount` as the live triangle counter (the same
        // field already holds the final triangle count in review).
        meshCollector.onTriangleCount = { [weak self] count in
            guard let self, self.phase == .scanning, self.scanKind == .mesh else { return }
            self.pointCount = count
        }
    }

    // MARK: - Scan lifecycle

    func startScan() {
        cancelHeavyWork()   // abort any lingering reconstruction from a prior scan
        capturedCloud = nil
        capturedMesh = nil
        textureSourceCloud = nil
        textureKeyframes = []
        pointCount = 0
        scanConfidence = 0
        scanCoverage = 0
        didAutoObject = false
        if scanKind == .points {
            // Use the unified profile's config so bespoke modes (Object's fine
            // voxels + short range) apply, not just the four-tier mapping.
            recorder.configure(effectiveScanConfig)
        } else {
            recorder.reset()   // mesh scans still collect keyframes for texturing
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
            // Object mode scans a small subject up close, where the main defect
            // is the speckle of flying pixels around its silhouette. Require one
            // more occupied neighbour there to shed those specks; room/area
            // scans stay lenient so thin far-away structure survives.
            let minNeighbors = captureQuality == .object ? 3 : 2
            Task { [weak self] in
                let result = await Task.detached(priority: .utility) {
                    recorder.snapshotDenoised(minNeighbors: minNeighbors)
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
            // Keyframes collected during the sweep let Bake texture work on
            // mesh scans too (photo-projected colour).
            textureKeyframes = recorder.snapshotKeyframes()
            phase = .reviewing
            let box = UncheckedSendableBox(mesh)
            Task.detached(priority: .utility) { ScanAutoSave.saveMesh(box.value) }
        }
    }

    func discard() {
        cancelHeavyWork()   // stop any in-flight reconstruction before tearing down
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
        placementMesh = nil
        placementPosition = nil
        resetStudio()
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

    /// Sets the region of interest around a tapped/auto-detected subject.
    /// `cameraDistance` (when known) drives Auto-Object: a close subject flips a
    /// non-Object point scan into fine Object capture, since targeting already
    /// restarts accumulation anyway.
    func setScanTarget(_ center: SIMD3<Float>, cameraDistance: Float? = nil) {
        let switchedToObject = maybeAutoObject(cameraDistance: cameraDistance)
        recorder.setRegion(center: center, radius: scanTargetRadius)
        // Restart accumulation so the result is just the subject, not what was
        // already captured around it.
        recorder.clearAccumulation()
        pointCount = 0
        hasScanTarget = true
        showToast(switchedToObject
                  ? "Object mode — fine detail for the close subject"
                  : String(format: "Target set — scanning within %.1f m", scanTargetRadius))
    }

    /// Auto-Object: when a point scan targets a close subject (≤ 1.2 m) and
    /// isn't already in Object mode, switch to fine Object capture once per
    /// session, sizing the range to the subject. Reconfigures the recorder; the
    /// caller re-applies the region right after. Returns whether it switched.
    @discardableResult
    private func maybeAutoObject(cameraDistance: Float?) -> Bool {
        guard phase == .scanning, scanKind == .points,
              captureQuality != .object, !didAutoObject,
              let distance = cameraDistance, distance <= 1.2 else { return false }
        didAutoObject = true
        objectRange = min(max(distance * 1.5, 1.0), 2.5)
        captureQuality = .object        // cascades reconstruction detail/method
        recorder.configure(effectiveScanConfig)   // fine voxels + short range
        return true
    }

    func updateScanTargetRadius(_ radius: Float) {
        scanTargetRadius = radius
        recorder.setRegionRadius(radius)
    }

    func clearScanTarget() {
        recorder.clearRegion()
        hasScanTarget = false
        didAutoObject = false   // a fresh target may re-evaluate Auto-Object
        showToast("Target cleared — scanning everything")
    }

    // MARK: - Load (from gallery)

    func loadSaved(_ cloud: PointCloud) {
        capturedMesh = nil
        capturedCloud = cloud
        textureSourceCloud = nil
        textureKeyframes = []
        removeStructure = false
        resetStudio()
        scanKind = .points
        pointCount = cloud.count
        phase = .reviewing
    }

    func loadSavedMesh(_ mesh: MeshData, textured: TexturedMesh? = nil) {
        placementMesh = nil          // a half-done placement refers to the old mesh
        placementPosition = nil
        capturedCloud = nil
        capturedMesh = mesh          // didSet clears texturedMesh — restore after
        texturedMesh = textured
        textureSourceCloud = nil
        textureKeyframes = []
        removeStructure = false
        resetStudio()
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
