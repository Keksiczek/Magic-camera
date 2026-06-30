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
import os
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
    /// Bumped for finer triangles (smaller faces). The reconstructor's 1.5 mm
    /// cell floor and the density-aware clamp (≤1.5× mean point spacing) stop a
    /// sparse scan over-tessellating, so the extra resolution only materialises
    /// where the capture is dense enough to support it.
    var resolution: Int {
        switch self {
        case .draft:    return 56
        case .standard: return 96    // was 80
        case .detailed: return 144   // was 120
        case .ultra:    return 192   // was 168 — finest triangles; needs a dense scan
        }
    }

    /// Upper bound on the *density-driven* lattice resolution (see
    /// `SpatialScanViewModel.densityResolution`). The reconstruction sizes its
    /// cells from the cloud's actual point density so a densely-scanned room/object
    /// meshes finer than the flat tier would allow; this cap keeps a large dense
    /// cloud from exploding the triangle count past the CPU/memory watchdog. The
    /// tier therefore acts as a quality ceiling rather than the only knob.
    var densityCap: Int {
        switch self {
        case .draft:    return 128
        case .standard: return 192
        case .detailed: return 256
        case .ultra:    return 320
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

    /// Point scans that ask for ARKit's scene mesh (Object mode) so it can be
    /// used as a surface mask in review. Gated on hardware support.
    var captureWantsSceneMesh: Bool {
        scanKind == .points && effectiveScanConfig.wantsSceneMesh
            && DeviceCapabilities.supportsSceneReconstruction
    }
    /// Point scans that ask ARKit to detect planes (floor/walls) for cropping.
    var captureWantsPlanes: Bool {
        scanKind == .points && effectiveScanConfig.wantsPlanes
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
            // Any fresh cloud (scan / load / restore) drops a stale manual-isolate
            // flag; the lasso/crop ops re-set it after they assign the cloud.
            userIsolated = false
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
    /// Live orbit coverage for object / targeted scans: the fraction of the 360°
    /// orbit the camera has observed from, plus the 24-sector bitmask that fills
    /// the Apple-style coverage ring. Reset on discard / restart.
    var scanOrbitFraction: Float = 0
    var scanOrbitSectors: UInt32 = 0
    /// Live camera bearing around the subject [0,1) (−1 = unknown) — the moving
    /// "you are here" marker on the orbit ring.
    var scanOrbitHeading: Float = -1
    /// Elevation bands the subject has been viewed from (bit 0 = level/side,
    /// bit 1 = angled, bit 2 = top-down). Lets the coach catch a top-down-only
    /// sweep that would reconstruct flat. Reset on discard / restart.
    var scanElevationBands: UInt8 = 0
    /// Cached per-point normals for the captured cloud, included in PLY export when
    /// present. Estimated on demand, invalidated whenever the cloud changes.
    var capturedCloudNormals: [SIMD3<Float>]?

    // Tap-to-target: restrict a point-cloud scan to a region around a tapped point.
    var hasScanTarget = false
    var scanTargetRadius: Float = 0.6
    /// World point the user tapped (or auto-target picked) as the subject. Used at
    /// review time to isolate the cluster the user actually pointed at — the
    /// Apple-style "trust the selection" cue — instead of guessing the largest /
    /// most-central blob. nil for untargeted scans.
    @ObservationIgnored var subjectAnchor: SIMD3<Float>?
    /// Set once the user manually isolates the subject (lasso-keep or crop). Then
    /// "Make 3D Model" trusts that selection and skips the automatic floor/cluster
    /// isolation, which would otherwise second-guess the manual pick. Reset on a
    /// new scan / load / discard.
    var userIsolated = false
    /// Mesh-mode capture settings (parity with the point Object/quality dial).
    /// Object mode keeps just the subject (drops stray anchors, hides walls/floor);
    /// detail decimates the finished ARKit mesh (Ultra keeps it full).
    var meshObjectMode = false
    var meshDetail: MeshDetail = .detailed
    /// Screen-space projection of the ROI sphere, updated live by the AR
    /// coordinator so the focus overlay tracks the subject instead of sitting
    /// in the middle of the screen. Nil when the target is off-screen/behind.
    var roiScreenCircle: ROIScreenCircle?
    /// True while the AR coordinator is drawing the lifted-subject highlight —
    /// the circular ROI dim would just fight it visually, so the view hides it.
    var subjectMaskActive = false
    /// When on, the live point overlay is coloured by capture confidence
    /// (green = solid, red = poor) instead of RGB — a live heatmap so the user
    /// can see which surfaces still need another pass.
    var scanShowConfidence = false

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
        case makingModel         // one-tap isolate → reconstruct → texture (object)
        case makingSurface       // one-tap open textured surface (rooms / façades)
        case isolating           // plane removal + clustering
        case optimizing          // Taubin smoothing
        case fillingHoles        // boundary-loop capping (Fill holes)
        case closingBase         // cap the open floor-cut base (Close base)
        case removingBase        // strip the dominant flat support plane (Remove base)
        case decimating          // vertex-clustering reduction
        case cleaning            // outlier removal (Clean up — remove strays)
        case filteringReflections // low-confidence / multipath cut (Matte filter)
        case thinning            // curvature-aware adaptive downsample
        case estimatingNormals   // per-point normals for PLY
        case merging             // ICP merge (cloud or mesh)
        case placing             // bake a placed scan into the host mesh
        case transforming        // scale / rotate about the model centre (Studio)
        case bakingTexture       // UV atlas + texture bake
        case exportingWeb        // self-contained HTML viewer
        case exportingVideo      // turntable render
        case cropping            // keep only geometry inside a box
        case mirroring           // reflect + merge for symmetry
        case makingPrintable     // close base + fill holes + smooth (one tap)

        /// Ops that change the captured result — these snapshot the review state
        /// onto the undo stack before they run. (Normals/texture/export don't
        /// alter the geometry, so they're excluded.)
        var mutatesResult: Bool {
            switch self {
            case .reconstructing, .makingModel, .makingSurface, .isolating, .optimizing,
                 .fillingHoles, .closingBase, .removingBase, .decimating, .cleaning,
                 .filteringReflections, .thinning, .merging, .placing, .transforming,
                 .cropping, .mirroring, .makingPrintable:
                return true
            case .estimatingNormals, .bakingTexture, .exportingWeb, .exportingVideo:
                return false
            }
        }

        /// Human-readable name for the processing overlay.
        var label: String {
            switch self {
            case .reconstructing:    return "Reconstructing surface"
            case .makingModel:       return "Making 3D model"
            case .makingSurface:     return "Building textured surface"
            case .isolating:         return "Isolating object"
            case .optimizing:        return "Optimising surface"
            case .fillingHoles:      return "Filling holes"
            case .closingBase:       return "Closing base"
            case .removingBase:      return "Removing base"
            case .decimating:        return "Reducing detail"
            case .cleaning:          return "Cleaning up"
            case .filteringReflections: return "Filtering reflections"
            case .thinning:          return "Thinning flat areas"
            case .estimatingNormals: return "Estimating normals"
            case .merging:           return "Merging scan"
            case .placing:           return "Placing scan"
            case .transforming:      return "Transforming"
            case .bakingTexture:     return "Baking texture"
            case .exportingWeb:      return "Building web viewer"
            case .exportingVideo:    return "Rendering turntable"
            case .cropping:          return "Cropping"
            case .mirroring:         return "Mirroring"
            case .makingPrintable:   return "Finishing"
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
    /// disabled states. Returns false when another operation is running. A
    /// mutating op snapshots the review state onto the undo stack first.
    func beginOperation(_ operation: Operation) -> Bool {
        guard activeOperation == nil else { return false }
        if operation.mutatesResult { pushUndoSnapshot() }
        activeOperation = operation
        operationStartedAt = Date()
        // Keep the screen awake for the whole job. If the display auto-locks
        // mid-run the app is suspended and the detached reconstruction/bake gets
        // cancelled (scenePhase .background → cancelHeavyWork) — minutes of work
        // on a big surface lost just because the screen dimmed. Restored in
        // endOperation (which every exit path, including cancel, funnels through).
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    func endOperation() {
        activeOperation = nil
        operationStartedAt = nil
        UIApplication.shared.isIdleTimerDisabled = false
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

    /// The app is leaving the foreground. Review-time reconstruction / texture
    /// bake run on detached tasks; left running into suspension they keep the CPU
    /// busy and trip the "failed to terminate in time" watchdog (the background
    /// SIGKILL the diagnostics kept showing). Cancel them so the app suspends
    /// cleanly — the cloud/mesh is already autosaved, so the user re-runs on
    /// return. (Live capture is quiesced separately by ScanARView pausing the
    /// ARSession.)
    func handleEnterBackground() {
        // No-op now: heavy review ops hold a background-task assertion (see
        // runOperation), so they finish across a screen-lock instead of being
        // cancelled the instant the screen turns off — which was killing
        // reconstructions mid-run. Live capture is still quiesced by ScanARView
        // pausing the ARSession on background.
    }

    /// Telemetry for the CPU/memory-watchdog class of bug: an Instruments
    /// signpost interval per review operation plus a duration log, so a slow or
    /// runaway job is observable rather than anecdotal.
    private static let opSignposter = OSSignposter(subsystem: "com.keks.MagicCamera",
                                                   category: "review-ops")
    private static let opLog = Logger(subsystem: "com.keks.MagicCamera", category: "review-ops")

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
        // Breadcrumb the op's start + elapsed time into the exportable log. A run
        // the CPU watchdog kills mid-flight shows up as a `▶` with no matching `■`,
        // which names the culprit op directly in the export (no symbolication).
        let crumb = Diagnostics.shared.begin(operation.label)
        let generation = workGeneration
        let startedAt = Date()
        let signpostID = Self.opSignposter.makeSignpostID()
        let interval = Self.opSignposter.beginInterval("review-op", id: signpostID,
                                                       "\(operation.label, privacy: .public)")
        let task = Task.detached(priority: priority) { work() }
        heavyWorkCancel = { task.cancel() }
        // Keep heavy ops alive across a screen-lock / backgrounding: a
        // background-task assertion buys iOS-granted time so reconstruction/bake
        // finishes instead of being suspended mid-run (the "it stops soon after
        // the screen turns off" report). If the grant expires, cancel gracefully.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: operation.label) {
            task.cancel()
        }
        Task { [weak self] in
            let result = await task.value
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            Self.opSignposter.endInterval("review-op", interval)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let self else { return }
            guard self.workGeneration == generation else {   // discarded/restarted mid-run
                Diagnostics.shared.end(crumb, "discarded")   // end() appends the elapsed ms
                Self.opLog.debug("\(operation.label, privacy: .public) cancelled after \(ms) ms")
                return
            }
            self.heavyWorkCancel = nil
            self.endOperation()
            Diagnostics.shared.end(crumb, result == nil ? "failed" : "ok")
            Self.opLog.debug("\(operation.label, privacy: .public) \(result == nil ? "failed" : "ok", privacy: .public) in \(ms) ms")
            guard let result else {
                if let failureToast { self.showToast(failureToast) }
                return
            }
            completion(result)
        }
    }

    // MARK: - Undo / redo

    /// A restorable snapshot of the editable review state.
    struct ReviewSnapshot {
        let cloud: PointCloud?
        let mesh: MeshData?
        let textured: TexturedMesh?
        let sourceCloud: PointCloud?
        let keyframes: [ScanKeyframe]
        let normals: [SIMD3<Float>]?
        let viewDirections: [SIMD3<Float>]?
        let scanKind: ScanKind
        let removeStructure: Bool

        /// Rough resident size, to bound the stack on big scans.
        var estimatedBytes: Int {
            var b = (cloud?.count ?? 0) * 28 + (sourceCloud?.count ?? 0) * 28
            if let mesh { b += mesh.vertices.count * 24 + mesh.indices.count * 4 }
            b += textured?.texturePNG.count ?? 0
            b += keyframes.reduce(0) { $0 + $1.jpeg.count }
            return b
        }
    }

    /// Clouds and meshes are large, so the history is bounded by both depth and
    /// a memory budget — deep on small objects, shallow on room-scale scans.
    @ObservationIgnored private var undoStack: [ReviewSnapshot] = []
    @ObservationIgnored private var redoStack: [ReviewSnapshot] = []
    @ObservationIgnored private let maxUndoDepth = 8
    @ObservationIgnored private let undoMemoryBudget = 250_000_000   // ~250 MB
    /// Observable mirrors so the toolbar buttons enable/disable.
    var canUndo = false
    var canRedo = false

    private func currentSnapshot() -> ReviewSnapshot {
        ReviewSnapshot(cloud: capturedCloud, mesh: capturedMesh, textured: texturedMesh,
                       sourceCloud: textureSourceCloud, keyframes: textureKeyframes,
                       normals: capturedCloudNormals, viewDirections: capturedViewDirections,
                       scanKind: scanKind, removeStructure: removeStructure)
    }

    /// Pushes the pre-op state and clears the redo branch. Trims the oldest
    /// entries once the depth or memory budget is exceeded.
    private func pushUndoSnapshot() {
        guard hasResult else { return }
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
        trimUndoStack()
        refreshUndoFlags()
    }

    private func trimUndoStack() {
        while undoStack.count > maxUndoDepth { undoStack.removeFirst() }
        var total = undoStack.reduce(0) { $0 + $1.estimatedBytes }
        while undoStack.count > 1, total > undoMemoryBudget {
            total -= undoStack.removeFirst().estimatedBytes
        }
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard !isBusy, let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(snapshot)
        refreshUndoFlags()
        showToast("Undone")
    }

    func redo() {
        guard !isBusy, let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(snapshot)
        refreshUndoFlags()
        showToast("Redone")
    }

    /// Applies a snapshot. Order matters: the captured-cloud/mesh `didSet`s clear
    /// normals/directions/texture, so those are restored afterwards.
    private func restore(_ s: ReviewSnapshot) {
        capturedMesh = s.mesh            // didSet clears texturedMesh
        capturedCloud = s.cloud          // didSet clears normals/directions
        texturedMesh = s.textured
        capturedCloudNormals = s.normals
        capturedViewDirections = s.viewDirections
        textureSourceCloud = s.sourceCloud
        textureKeyframes = s.keyframes
        scanKind = s.scanKind
        removeStructure = s.removeStructure   // didSet rebuilds the crop
        pointCount = s.mesh?.triangleCount ?? s.cloud?.count ?? 0
    }

    /// Drops the undo/redo history — a new capture or loaded scan is a fresh
    /// context where restoring the previous one makes no sense.
    func clearEditHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        refreshUndoFlags()
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
    /// Live count (points or triangles) at the last autosave write. The autosave
    /// only re-encodes + rewrites the snapshot when the scan has grown materially
    /// since this — a full atomic rewrite of a multi-million-point cloud every
    /// 12 s was dirtying gigabytes of file-backed memory over a session (the
    /// `.diskwrites` watchdog) for no recovery benefit.
    @ObservationIgnored private var lastAutosavedCount = 0
    /// ARKit's own scene mesh, captured alongside an Object point scan. ARKit's
    /// regularised geometry omits the silhouette "flying pixels" the raw LiDAR
    /// cloud carries, so it doubles as a surface mask that strips bleed the
    /// geometric isolation leaves behind. Nil for room/area scans (memory) and
    /// devices without scene reconstruction.
    @ObservationIgnored var captureSceneMesh: MeshData?

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
        recorder.onOrbitCoverage = { [weak self] fraction, sectors, heading, bands in
            guard let self else { return }
            // Subtle milestone haptics (Apple-style): a light tick on each newly
            // covered sector / elevation band, and a success cue the first time the
            // scan is genuinely complete — a full orbit *with* a side view, so a
            // flat top-down sweep never earns the "done" reward.
            let gainedCoverage = (sectors & ~self.scanOrbitSectors) != 0
                || (bands & ~self.scanElevationBands) != 0
            let wasComplete = self.scanOrbitFraction >= 0.85 && (self.scanElevationBands & 1) != 0
            self.scanOrbitFraction = fraction
            self.scanOrbitSectors = sectors
            self.scanOrbitHeading = heading
            self.scanElevationBands = bands
            let nowComplete = fraction >= 0.85 && (bands & 1) != 0
            if nowComplete && !wasComplete {
                Haptics.success()
            } else if gainedCoverage {
                Haptics.impact(.light)
            }
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
        captureSceneMesh = nil
        pointCount = 0
        scanConfidence = 0
        scanCoverage = 0
        scanOrbitFraction = 0
        scanOrbitSectors = 0
        scanOrbitHeading = -1
        scanElevationBands = 0
        didAutoObject = false
        subjectAnchor = nil
        userIsolated = false
        if scanKind == .points {
            // Use the unified profile's config so bespoke modes (Object's fine
            // voxels + short range) apply, not just the four-tier mapping.
            recorder.configure(effectiveScanConfig)
        } else {
            // Mesh mode now also captures a dense depth cloud (ARKit's live mesh is
            // just the preview); a scene/room mesh is reconstructed from it on
            // finish so it can be finer than ARKit's fixed-resolution mesh.
            recorder.configure(ScanConfig.meshCapture)
        }
        meshCollector.reset()
        phase = .scanning
        Diagnostics.shared.log("scan start", "\(scanKind.rawValue) · \(captureQuality.rawValue)")
        if scanKind == .points {
            // Record the exact capture profile so a later bleed/quality report can
            // be tied to the voxel size, range, confidence floor, edge trim and
            // carving that produced it — the levers we tune for those complaints.
            let c = effectiveScanConfig
            Diagnostics.shared.log("scan config", String(
                format: "voxel %.0fmm · depth %.1fm · conf≥%d · edge %.2f · carve %@ · cap %@",
                c.voxelSize * 1000, c.maxDepth, Int(c.minConfidence), c.edgeThreshold,
                c.carveEnabled ? "on" : "off", MeasurementFormat.count(c.maxPoints)))
        }
        startAutoSave()
    }

    /// Periodically snapshots the in-progress scan to disk so a crash or
    /// watchdog kill mid-scan loses at most one interval of work.
    private func startAutoSave() {
        autoSaveTask?.cancel()
        lastAutosavedCount = 0
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard let self, self.phase == .scanning else { return }
                // Only rewrite the snapshot once the scan has grown materially.
                // The threshold scales with the saved size (≈15 %, min 25 k) so
                // early growth still checkpoints often (small files, cheap) while
                // a large, slowly-settling cloud stops rewriting tens of MB every
                // tick. `pointCount` is the live count for both kinds (points, or
                // triangles in mesh mode) and is cheap to read.
                let live = self.pointCount
                let grew = live - self.lastAutosavedCount
                guard grew >= max(25_000, self.lastAutosavedCount / 6) else { continue }
                self.lastAutosavedCount = live
                switch self.scanKind {
                case .points:
                    let recorder = self.recorder
                    Task.detached(priority: .utility) {
                        let snap = recorder.snapshotWithDirections()
                        ScanAutoSave.saveCloud(snap.cloud, directions: snap.directions)
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
            // Object scans also keep ARKit's scene mesh as a surface mask.
            let collector = self.meshCollector
            let wantsSceneMesh = self.captureWantsSceneMesh
            let rawCount = recorder.pointCount   // before the denoise drop, for diagnostics
            Task { [weak self] in
                let result = await Task.detached(priority: .utility) {
                    recorder.snapshotDenoised(minNeighbors: minNeighbors)
                }.value
                let sceneMesh = wantsSceneMesh
                    ? await Task.detached(priority: .utility) { collector.snapshot() }.value
                    : nil
                self?.finishPointScan(result.cloud, viewDirections: result.viewDirections,
                                      sceneMesh: sceneMesh, rawCount: rawCount)
            }
        case .mesh:
            let recorder = self.recorder
            let collector = self.meshCollector
            let objectMode = self.meshObjectMode
            let detail = self.meshDetail
            let rawCount = recorder.pointCount
            Task { [weak self] in
                // Scene/room mesh: reconstruct from the dense LiDAR cloud
                // (density-driven → finer than ARKit's fixed-resolution mesh).
                // Object mode keeps ARKit's mesh path (its small-component cleanup),
                // and a too-thin cloud falls back there too — so mesh mode can never
                // end up worse than before.
                if !objectMode {
                    let denoised = await Task.detached(priority: .utility) {
                        recorder.snapshotDenoised(minNeighbors: 2)
                    }.value
                    if denoised.cloud.count >= 20_000 {
                        self?.finishMeshFromCloud(denoised.cloud,
                                                  viewDirections: denoised.viewDirections,
                                                  rawCount: rawCount)
                        return
                    }
                }
                let mesh = await Task.detached(priority: .userInitiated) { () -> MeshData in
                    var m = collector.snapshot()
                    // Object mode: drop the floating stray anchors so the result is
                    // the subject, not the room speckle around it.
                    if objectMode { m = m.removingSmallComponents() }
                    // Detail: Ultra keeps ARKit's full mesh; lower tiers decimate to
                    // a coarser grid for fewer, larger triangles.
                    if detail != .ultra, !m.isEmpty {
                        m = MeshDecimator.decimate(m, gridResolution: detail.resolution)
                    }
                    return m
                }.value
                self?.finishMeshScan(mesh)
            }
        }
    }

    private func finishPointScan(_ cloud: PointCloud, viewDirections: [SIMD3<Float>],
                                 sceneMesh: MeshData? = nil, rawCount: Int = 0) {
        guard phase == .finishing else { return }   // discarded mid-finish
        autoSaveTask?.cancel()
        pointCount = cloud.count
        captureSceneMesh = (sceneMesh?.isEmpty == false) ? sceneMesh : nil
        Diagnostics.shared.log("scan finished", "points · \(cloud.count) pts"
            + (captureSceneMesh != nil ? " · ARKit mask" : ""))
        // Quality telemetry: how many points the denoise dropped, how many bleed/
        // ghost points carving removed during the scan, and the confidence spread
        // of what survived — so a "still bleeds / low quality" report is debuggable.
        let stats = recorder.captureStats()
        let hist = Self.confidenceHistogram(cloud)
        Diagnostics.shared.log("scan quality", String(
            format: "raw %d → kept %d · carved %d · content-coarse %d · shake %d · drift %.1fcm · cells %d · conf L%d%%/M%d%%/H%d%%",
            rawCount, cloud.count, stats.carved, stats.contentCoarsened, stats.motionSkipped,
            stats.driftCorrected * 100, stats.fusionCells, hist.low, hist.mid, hist.high))
        clearEditHistory()
        if cloud.isEmpty {
            phase = .idle
            showToast("No points captured — scan textured surfaces up close")
        } else {
            capturedCloud = cloud   // didSet clears the directions — set after
            capturedViewDirections = viewDirections.count == cloud.count ? viewDirections : nil
            textureKeyframes = recorder.snapshotKeyframes()
            phase = .reviewing
            // Snapshot the final result too: it is in memory but not yet saved.
            // Carry the view rays so a crash-recovery restore rebuilds with
            // fusion-rays, not the slower est-normals fallback.
            let box = UncheckedSendableBox(cloud)
            let dirsBox = UncheckedSendableBox(capturedViewDirections)
            Task.detached(priority: .utility) {
                ScanAutoSave.saveCloud(box.value, directions: dirsBox.value)
            }
            // No auto-reconstruction: a room/area cloud isn't always meant to
            // become a closed 3D model — sometimes you just want the textured
            // surface (e.g. outdoors, where the scan is open). Let the user pick
            // in review (Build Surface / Make 3D Model / Bake texture).
        }
    }

    /// Confidence distribution of a cloud as integer percentages (sampled, so it
    /// stays cheap on a multi-million-point cloud). Confidences are the
    /// fusion-weighted average per point in [0,1]: low <0.4, high >0.7. A scan
    /// dominated by "low" usually means glossy / dark / over-distance surfaces or
    /// motion smear — exactly what the user asked us to be able to see after a scan.
    nonisolated static func confidenceHistogram(_ cloud: PointCloud)
        -> (low: Int, mid: Int, high: Int) {
        let n = cloud.count
        guard n > 0 else { return (0, 0, 0) }
        let stride = max(n / 20_000, 1)
        var low = 0, mid = 0, high = 0, total = 0
        var i = 0
        while i < n {
            let c = cloud.confidences[i]
            if c < 0.4 { low += 1 } else if c > 0.7 { high += 1 } else { mid += 1 }
            total += 1
            i += stride
        }
        guard total > 0 else { return (0, 0, 0) }
        return (low * 100 / total, mid * 100 / total, high * 100 / total)
    }

    private func finishMeshScan(_ mesh: MeshData) {
        guard phase == .finishing else { return }
        autoSaveTask?.cancel()
        Diagnostics.shared.log("scan finished", "mesh · \(mesh.triangleCount) tris")
        clearEditHistory()
        if mesh.isEmpty {
            phase = .idle
            showToast("No mesh captured — sweep the space slowly")
        } else {
            capturedMesh = mesh
            // Object mode hides walls/floor by default (a no-op on an unclassified
            // mesh); the review toggle can flip it back.
            removeStructure = meshObjectMode
            pointCount = mesh.triangleCount
            // Keyframes collected during the sweep let Bake texture work on
            // mesh scans too (photo-projected colour).
            textureKeyframes = recorder.snapshotKeyframes()
            phase = .reviewing
            let box = UncheckedSendableBox(mesh)
            Task.detached(priority: .utility) { ScanAutoSave.saveMesh(box.value) }
        }
    }

    /// Mesh-mode finish for a scene/room when a dense depth cloud was captured:
    /// hand it to the density-driven reconstruction so the result is finer than
    /// ARKit's fixed-resolution mesh. Mirrors a point scan landing on a mesh — the
    /// cloud stays the texture/colour source; reconstructMesh sets scanKind = .mesh.
    private func finishMeshFromCloud(_ cloud: PointCloud, viewDirections: [SIMD3<Float>],
                                     rawCount: Int = 0) {
        guard phase == .finishing else { return }
        autoSaveTask?.cancel()
        pointCount = cloud.count
        let hist = Self.confidenceHistogram(cloud)
        Diagnostics.shared.log("scan finished", String(
            format: "mesh→cloud · %d pts (raw %d · conf L%d%%/M%d%%/H%d%%) reconstructing",
            cloud.count, rawCount, hist.low, hist.mid, hist.high))
        clearEditHistory()
        capturedCloud = cloud   // didSet clears directions — set after
        capturedViewDirections = viewDirections.count == cloud.count ? viewDirections : nil
        textureKeyframes = recorder.snapshotKeyframes()
        // Measured view rays drive Fusion; the mesh-mode detail tier caps density.
        reconstructMethod = .fusion
        reconstructDetail = meshDetail
        let snapshot = UncheckedSendableBox(cloud)
        let dirsBox = UncheckedSendableBox(capturedViewDirections)
        Task.detached(priority: .utility) {
            ScanAutoSave.saveCloud(snapshot.value, directions: dirsBox.value)
        }
        phase = .reviewing
        reconstructMesh()   // density-driven → capturedMesh, scanKind = .mesh
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
        scanOrbitFraction = 0
        scanOrbitSectors = 0
        scanOrbitHeading = -1
        scanElevationBands = 0
        recorder.reset()
        meshCollector.reset()
        hasScanTarget = false
        placementMesh = nil
        placementPosition = nil
        clearEditHistory()
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
                let restored = await Task.detached(priority: .userInitiated) {
                    ScanAutoSave.restoreCloud()
                }.value
                guard let self else { return }
                if let restored, !restored.cloud.isEmpty {
                    self.loadSaved(restored.cloud, directions: restored.directions)
                    self.showToast("Recovered unsaved scan · \(restored.cloud.count) pts")
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
        scanOrbitFraction = 0
        scanOrbitSectors = 0
        scanOrbitHeading = -1
        scanElevationBands = 0
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
        // In Object mode a tap should hug the subject rather than carve a 0.6 m
        // (1.2 m-wide) sphere that scoops up the table and background as the user
        // orbits the object. Size the world-anchored ROI to the tapped point's
        // distance. The subject-mask auto-target already supplies its own fitted
        // radius and calls in without a distance, so that path stays untouched.
        if (switchedToObject || captureQuality == .object), let distance = cameraDistance {
            // Tighter default (was 0.45 / 0.18…0.6): a generous sphere scooped up
            // the table + background ("bere okolí"). Hug the subject and let the
            // radius slider grow it if it clips — starting tight captures a clean
            // object; growing is one slider drag.
            scanTargetRadius = min(max(distance * 0.4, 0.15), 0.45)
        }
        recorder.setRegion(center: center, radius: scanTargetRadius)
        // Restart accumulation so the result is just the subject, not what was
        // already captured around it.
        recorder.clearAccumulation()
        pointCount = 0
        hasScanTarget = true
        subjectAnchor = center   // the tap = the subject, for review-time isolation
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
        subjectAnchor = nil
        didAutoObject = false   // a fresh target may re-evaluate Auto-Object
        showToast("Target cleared — scanning everything")
    }

    // MARK: - Load (from gallery)

    func loadSaved(_ cloud: PointCloud, directions: [SIMD3<Float>]? = nil) {
        capturedMesh = nil
        capturedCloud = cloud   // didSet clears directions — re-attach below
        // Persisted view rays (v2 .mcscan) let a reloaded scan rebuild with
        // fusion-rays; nil for legacy/ray-less clouds → est-normals as before.
        capturedViewDirections = (directions?.count == cloud.count) ? directions : nil
        textureSourceCloud = nil
        textureKeyframes = []
        removeStructure = false
        clearEditHistory()
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
        clearEditHistory()
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
