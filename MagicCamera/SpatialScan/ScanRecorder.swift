//
//  ScanRecorder.swift
//  Magic Camera
//
//  Accumulates a coloured point cloud from ARFrames. Per-pixel depth
//  unprojection + colour sampling runs on the GPU (ScanComputeUnprojector) with
//  a CPU fallback; voxel dedup, capping and outlier filtering stay on the CPU.
//
import ARKit
import simd

/// Configuration for the scanning process.
struct ScanConfig {
    var frameStride: Int = 3
    var pixelStride: Int = 2
    var minConfidence: UInt8 = 1     // 0 low, 1 medium, 2 high
    var voxelSize: Float = 0.012
    var maxPoints: Int = 600_000
    var maxDepth: Float = 5.0
    /// Reject a depth texel whose 4-neighbour depth jumps more than this fraction
    /// of its own depth — the silhouette "flying pixels" that smear between a
    /// subject and its background. 0 disables it (room/area scans keep their real
    /// depth edges); Object mode turns it on to clean up subject outlines.
    var edgeThreshold: Float = 0
    /// If true, the recorder will adapt its effective frameStride based on
    /// average confidence of the incoming frame (lower confidence → higher stride).
    var adaptiveStrideEnabled: Bool = true
    /// If true, points farther from the camera are snapped to a coarser voxel
    /// lattice before insertion, so distant (noisier, sparser) surfaces consume
    /// fewer points while close-up detail stays full-resolution. Points closer
    /// than `adaptiveVoxelNearDistance` are never coarsened.
    var adaptiveVoxelEnabled: Bool = true
    /// Distance (metres) within which adaptive voxel coarsening is disabled.
    var adaptiveVoxelNearDistance: Float = 1.5
    /// Distance band width (metres): each band beyond the near distance bumps the
    /// voxel-size multiplier by one, up to `adaptiveVoxelMaxMultiplier`.
    var adaptiveVoxelBandWidth: Float = 1.0
    /// Maximum voxel-size multiplier applied to the farthest points.
    var adaptiveVoxelMaxMultiplier: Int = 4
    /// Content-adaptive capture density: coarsen the voxel lattice on flat regions
    /// (walls / floor) while keeping it fine on structured detail (the objects in a
    /// room), so a room scan spends its point budget where the geometry actually is
    /// instead of on blank walls — finer object detail without scanning the whole
    /// room at object resolution. The base `voxelSize` is the FINE size; a point
    /// whose local surface variation (`CaptureDensity.surfaceVariation`) is below
    /// `contentDetailThreshold` coarsens up to `contentMaxMultiplier`. Off by
    /// default; Room mode turns it on. Inert for objects (everything reads as detail).
    var contentAdaptiveEnabled: Bool = false
    /// Surface-variation σ below which a point is flat enough to coarsen. Tuned
    /// above the LiDAR depth-noise floor so a noisy wall still reads flat (a noisy
    /// plane sits ≈0.013, an object's curvature ≳0.06 — see CaptureDensityTests).
    var contentDetailThreshold: Float = 0.04
    /// Max voxel-size multiplier applied to the flattest captured regions. Kept
    /// gentle (2× → a 10 mm base coarsens to at most 20 mm on a wall) so flat
    /// surfaces stay dense enough to read as solid: a higher cap emptied walls out
    /// into holes while the coverage metric still read "done".
    var contentMaxMultiplier: Float = 2
    /// TSDF-style weighted voxel fusion: instead of "first sample per voxel
    /// wins", every depth sample falling into a voxel refines the stored point
    /// as a confidence-weighted running average (position, colour and
    /// confidence). Dramatically reduces depth noise on repeated sweeps.
    var fusionEnabled: Bool = true
    /// Per-voxel weight cap so very old observations don't freeze the average.
    var fusionMaxWeight: Float = 48
    /// Free-space carving: every new depth ray proves the space *in front of*
    /// its hit is empty, so fused points sitting in that corridor lose weight
    /// and eventually die. This is the mechanism that lets a later orbit
    /// *correct* the silhouette bleed captured from an earlier angle, instead
    /// of the new geometry simply welding onto the old floaters. Gated on
    /// `fusionEnabled` (the carve runs against the fusion cells).
    var carveEnabled: Bool = true
    /// Weight removed from a contradicted voxel per carve pass. The accumulator
    /// adds ≈0.5–1.25 per genuine sighting, so a value ≥1 means an unconfirmed
    /// ghost dies in a handful of passes while a surface that keeps being
    /// re-seen holds its weight. 1.4 clears typical bleed within one slow orbit.
    var carveStrength: Float = 1.4
    /// Max voxels sampled along one carve ray — bounds the per-point cost (the
    /// carve runs for every accepted candidate every frame, so this is the main
    /// capture-speed lever). 24 keeps capture fluid while still clearing bleed;
    /// long corridors stride coarser to stay within it.
    var carveMaxSteps: Int = 24
    /// Re-glue the accumulated cloud to the subject as ARKit refines its world
    /// map. The recorder is fed the target anchor's transform every frame
    /// (targeted / object scans); when the anchor has moved more than this from
    /// the baseline, the whole cloud is rigidly carried along the same delta so a
    /// later orbit pass lands *on* the existing geometry instead of beside it —
    /// the drift doubling that leaves bleed carving can't reach. The baseline only
    /// advances when a correction is applied, so *gradual* drift accumulates to
    /// the bar instead of being averaged away one sub-threshold frame at a time
    /// (the previous code only caught >5 cm relocalisation jumps, so a slow orbit
    /// went uncorrected). A rigid carry preserves the object's shape and keeps old
    /// and new points consistent, so a spurious correction can't smear the mesh.
    /// 0 disables the carry. Untargeted (room) scans never feed an anchor, so this
    /// is inert for them regardless. Tunable like the carving levers.
    var driftCorrectMeters: Float = 0.02
    /// Companion rotational bar for the drift carry (radians, ~2°).
    var driftCorrectRadians: Float = 0.035
    /// Steadiness gate: skip *fusing a frame's depth* when the camera is moving
    /// faster than this between processed frames (angular rad/s, linear m/s).
    /// Hand-shake motion-blurs the depth map, and those smeared samples fuse into
    /// the "flying pixels" carving then has to chase. Deliberate slow orbiting
    /// stays well under these, so only jerks/shake are dropped; the keyframe
    /// recorder already has its own (stricter) anti-blur gate for photos. 0
    /// disables it. Object mode turns it on (a close subject shows shake worst);
    /// room/area scans leave it off — walking is legitimately faster and far-field
    /// depth blur matters far less. Tunable like the carving levers; the dropped
    /// count surfaces on the `scan quality` diagnostics line (`shake N`).
    var steadyMaxAngularSpeed: Float = 0   // rad/s, 0 = gate off
    var steadyMaxLinearSpeed: Float = 0    // m/s,   0 = gate off
    /// Capture camera keyframes (photo + pose + depth) during the scan so a
    /// reconstructed mesh can be photo-textured instead of point-coloured.
    var keyframesEnabled: Bool = true
    /// Run ARKit scene reconstruction alongside a *point* scan and keep its mesh
    /// as a surface mask in review. ARKit's regularised geometry omits the
    /// silhouette flying pixels the raw cloud carries, so masking the cloud to it
    /// strips the bleed that geometric isolation leaves behind. Object mode only
    /// (a close subject keeps the extra mesh small); off for room/area scans.
    var wantsSceneMesh: Bool = false
    /// Ask ARKit to detect planes (floor/walls) during the scan so the support
    /// surface and background can be cropped from a reliable source rather than
    /// inferred by RANSAC alone.
    var wantsPlanes: Bool = false
}

extension ScanConfig {
    /// Preset for the RoomPlan hybrid walkthrough. A room has far more surface
    /// than a tabletop scan, but the old 25 mm voxel read as a *sparse* cloud
    /// next to the Spatial-Scan room mode (20 mm + adaptive). This now matches
    /// (actually beats) that density: 18 mm near voxels with distance-adaptive
    /// coarsening so far walls thin out instead of saturating the cap, a 2 M cap
    /// for the large surface area, and 7 m range. frameStride 1 because the poll
    /// (RoomPlan owns the session) is already the stride; the recorder's own
    /// backpressure throttles if the poll outruns fusion.
    static let roomWalkthrough: ScanConfig = {
        var config = ScanConfig(frameStride: 1, pixelStride: 2, minConfidence: 1,
                                voxelSize: 0.018, maxPoints: 2_000_000, maxDepth: 7.0)
        config.adaptiveVoxelEnabled = true
        config.adaptiveVoxelNearDistance = 2.0
        return config
    }()

    /// Mesh-mode capture. ARKit's live scene mesh stays the on-screen preview, but
    /// the *result* is reconstructed from this dense LiDAR depth cloud
    /// (density-driven), so a mesh scan can be finer than ARKit's fixed-resolution
    /// mesh — the "I want higher quality / dynamic triangles in mesh mode" ask. An
    /// 8 mm near voxel with distance coarsening + a 2 M cap covers both objects and
    /// whole rooms; carving + keyframes stay on (bleed removal + texture baking).
    static let meshCapture: ScanConfig = {
        var config = ScanConfig(frameStride: 3, pixelStride: 2, minConfidence: 1,
                                voxelSize: 0.008, maxPoints: 2_000_000, maxDepth: 5.0)
        config.edgeThreshold = 0.09
        config.adaptiveVoxelEnabled = true
        config.adaptiveVoxelNearDistance = 2.5
        // Plane anchors seed the review-time wall flattening (same as Room point
        // scans) — mesh scans were the one capture path without them (a mesh-mode
        // window scan logged 'planes 5 (0 seeded)').
        config.wantsPlanes = true
        return config
    }()
}

/// Estimates how "saturated" a scan is from the rate at which new points are
/// still being added. Early on, sweeping fresh surface adds points fast (low
/// coverage — keep scanning); once the rate falls off relative to its peak, the
/// visible area is largely captured (high coverage). Pure value type so it is
/// unit-testable in isolation from ARKit.
struct ScanCoverageEstimator {
    /// Smoothing factor for the growth EMA (0…1; higher = more reactive).
    var smoothing: Float = 0.3
    /// Points must exceed this before coverage is reported, so the unstable
    /// first frames don't produce a misleading number.
    var warmupPoints: Int = 2_000

    private var lastCount = 0
    private var emaGrowth: Float = 0
    private var peakGrowth: Float = 0
    private var started = false

    /// Feeds the latest total point count and returns the coverage estimate in
    /// [0, 1], or `nil` while still warming up.
    mutating func update(totalCount: Int) -> Float? {
        defer { lastCount = totalCount }
        let delta = Float(max(0, totalCount - lastCount))
        if !started {
            started = true
            emaGrowth = delta
        } else {
            emaGrowth += smoothing * (delta - emaGrowth)
        }
        peakGrowth = max(peakGrowth, emaGrowth)
        guard totalCount >= warmupPoints, peakGrowth > 0 else { return nil }
        return min(max(1 - emaGrowth / peakGrowth, 0), 1)
    }

    mutating func reset() {
        lastCount = 0
        emaGrowth = 0
        peakGrowth = 0
        started = false
    }
}

/// Tracks which azimuth sectors around a subject the camera has observed from,
/// so the scan UI can show an Apple-style "how much of the orbit have you
/// covered" ring (kolik z 360° jsi obešel). Gravity-up world, so the ground
/// plane is XZ and the orbit angle is the camera's bearing around the subject.
/// Pure value type — unit-testable without ARKit.
struct OrbitCoverageTracker {
    /// Number of azimuth sectors the 360° orbit is split into.
    let sectorCount: Int
    /// Minimum horizontal camera→subject distance for the bearing to be
    /// meaningful (right on top of the centre the azimuth is just noise).
    var minRadius: Float = 0.2
    /// Bitmask of covered sectors (bit i = sector i). 32-bit, so ≤ 32 sectors.
    private(set) var sectors: UInt32 = 0
    /// Live camera bearing around the subject as a fraction of the circle
    /// [0, 1), or −1 when unknown (too close to the centre). Drives the "you are
    /// here" marker on the coverage ring.
    private(set) var headingFraction: Float = -1
    /// Elevation bands the subject has been viewed from: bit 0 = level / side
    /// (the views that give an object its volume), bit 1 = angled-down, bit 2 =
    /// top-down. A sweep that only ever sets bit 2 is a top-down scan that will
    /// reconstruct flat — coaching reads this to nudge the user to the sides.
    private(set) var elevationBands: UInt8 = 0

    init(sectorCount: Int = 24) { self.sectorCount = min(max(sectorCount, 1), 32) }

    /// Marks the sector the camera currently sits in (and updates the live
    /// heading + elevation band), relative to `center`. Returns true only when
    /// this reveals a *new* sector, so the caller can tell genuine coverage
    /// progress from a mere heading nudge.
    mutating func observe(camera: SIMD3<Float>, center: SIMD3<Float>) -> Bool {
        let dx = camera.x - center.x
        let dz = camera.z - center.z
        let horiz2 = dx * dx + dz * dz
        guard horiz2 >= minRadius * minRadius else { return false }
        // Elevation of the camera above the subject — split into side / angled /
        // top-down so coaching can tell a flat top-down sweep from a full orbit.
        let elevation = atan2(camera.y - center.y, horiz2.squareRoot())   // radians
        if elevation < 0.35 { elevationBands |= 1 }        // < ~20° → level / side
        else if elevation < 0.96 { elevationBands |= 2 }   // ~20–55° → angled
        else { elevationBands |= 4 }                        // > ~55° → top-down
        var angle = atan2(dz, dx)             // [-π, π]
        if angle < 0 { angle += 2 * .pi }     // [0, 2π)
        headingFraction = angle / (2 * .pi)
        let sector = min(Int(angle / (2 * .pi) * Float(sectorCount)), sectorCount - 1)
        let bit = UInt32(1) << UInt32(sector)
        guard sectors & bit == 0 else { return false }
        sectors |= bit
        return true
    }

    /// Fraction of the orbit covered, in [0, 1].
    var fraction: Float { Float(sectors.nonzeroBitCount) / Float(sectorCount) }

    mutating func reset() { sectors = 0; headingFraction = -1; elevationBands = 0 }
}

/// A one-shot subject silhouette plus the camera that saw it. Candidate world
/// points are reprojected into that view and tested against the mask, so a
/// targeted scan keeps the subject and rejects the clutter around it. Points
/// outside the silhouette's frustum can't be judged and are accepted — the
/// ROI sphere still bounds those.
struct ScanSilhouette {
    let mask: SubjectMasker.MaskBitmap
    let worldToCamera: simd_float4x4
    /// Intrinsics in full image-pixel units (matching `width`/`height`).
    let fx: Float, fy: Float, cx: Float, cy: Float
    let width: Float, height: Float

    func rejects(_ p: SIMD3<Float>) -> Bool {
        let camera = worldToCamera * SIMD4<Float>(p, 1)
        let depth = -camera.z
        guard depth > 0.05 else { return false }
        let u = camera.x / depth * fx + cx
        let v = -camera.y / depth * fy + cy
        guard u >= 0, v >= 0, u < width, v < height else { return false }
        return !mask.contains(normalizedX: u / width, normalizedY: v / height)
    }
}

/// Thread‑safe point‑cloud recorder using a private serial queue.
final class ScanRecorder: @unchecked Sendable {
    typealias Candidates = ScanComputeUnprojector.Candidates

    // MARK: - State
    private let queue = DispatchQueue(label: "com.keks.MagicCamera.scanRecorder")
    /// Backpressure for frame ingestion. ARKit delivers frames on its delegate
    /// queue; forwarding each one into `queue.async` unbounded let the backlog
    /// (and every ARFrame it retains) pile up until ARKit throttled the camera
    /// — the "delegate is retaining N ARFrames" warning, after which capture
    /// stalls and a scan never finishes. Drop frames while the recorder is
    /// already saturated: the frame stride drops most frames anyway, so a
    /// couple in flight is plenty and keeps the capture pipeline healthy.
    private let frameBackpressureLock = NSLock()
    private var framesInFlight = 0
    private let maxFramesInFlight = 2
    private var config: ScanConfig
    private var cloud = PointCloud()
    private var voxelGrid: VoxelGrid
    /// Voxel → (stored point index, accumulated weight) for weighted fusion.
    private var fusionCells: [SIMD3<Int32>: (index: Int32, weight: Float)] = [:]
    /// Per-point mean view direction (camera → point), index-aligned with the
    /// cloud — feeds the ray-carved "Fusion" (TSDF-style) reconstruction.
    private var viewDirections: [SIMD3<Float>] = []
    private var frameCounter = 0
    /// Previous processed frame's pose + time, for the steadiness gate.
    private var lastSteadyTransform: simd_float4x4?
    private var lastSteadyTime: TimeInterval = 0
    /// Frames whose depth was dropped because the camera was shaking (diagnostics).
    private var motionSkipped = 0
    private var regionCenter: SIMD3<Float>?
    private var regionRadiusSq: Float = 0
    /// Live support-plane crop for targeted Object scans: ARKit's detected
    /// horizontal plane under the subject (fed ~1 Hz by the AR coordinator).
    /// Candidates at/below it are rejected at CAPTURE, outside a protective
    /// disc under the subject — the pad/table never enters the cloud, so the
    /// review shows the clean object instead of post-processing the mat away.
    private var supportPlane: (normal: SIMD3<Float>, offset: Float)?
    private var supportCroppedTotal = 0
    /// Coordinator-provided hook for ARSession.captureHighResolutionFrame.
    private var highResRequester: (@Sendable (@escaping @Sendable (ARFrame?) -> Void) -> Void)?
    /// Latest subject silhouette for targeted scans (refreshed ~1 Hz by the
    /// scan view); nil when no target is set or nothing lifts.
    private var silhouette: ScanSilhouette?
    /// Points killed by free-space carving since the last compaction.
    private var tombstones = 0
    /// Lifetime count of points carved away this scan (diagnostics only) — a
    /// healthy orbit that corrects bleed shows a non-trivial number here.
    private var carvedTotal = 0
    /// Candidates snapped to a coarser lattice by content-adaptive density this
    /// scan (diagnostics only) — the telemetry for tuning `contentDetailThreshold`.
    private var contentCoarsenedTotal = 0
    /// Total metres the cloud was rigidly carried to follow ARKit drift this scan
    /// (diagnostics only) — a non-zero value means orbit drift was being corrected.
    private var driftCorrectedTotal: Float = 0
    /// The target anchor's last world transform, the baseline for drift / jump
    /// correction (targeted scans only). nil until the first anchor transform
    /// arrives; only advances when a correction is applied.
    private var lastAnchorTransform: simd_float4x4?

    private let unprojector = ScanComputeUnprojector()
    /// Keyframe photos for texture baking (owned by `queue`).
    private let keyframeRecorder = ScanKeyframeRecorder()

    var onProgress: (@MainActor @Sendable (Int) -> Void)?
    /// Called on the main actor when scan confidence changes noticeably (0 = low, 1 = high).
    /// Only fired when adaptive stride is enabled and a confidence map is available.
    var onQualityUpdate: (@MainActor @Sendable (Float) -> Void)?
    /// Called on the main actor when the coverage estimate changes noticeably
    /// (0 = sweeping fresh surface, 1 = the visible area is largely captured).
    var onCoverageUpdate: (@MainActor @Sendable (Float) -> Void)?
    /// Called on the main actor as the orbit progresses (object / targeted scans).
    /// Args: orbit fraction [0,1], the covered-sector bitmask, and the live camera
    /// bearing [0,1) (−1 = unknown) for the "you are here" marker.
    var onOrbitCoverage: (@MainActor @Sendable (Float, UInt32, Float, UInt8) -> Void)?

    // MARK: - Lifecycle
    init(config: ScanConfig = ScanConfig()) {
        self.config = config
        self.voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
    }

    // MARK: - Configuration
    func configure(_ config: ScanConfig) {
        queue.sync {
            self.config = config
            self.voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
            self.cloud.removeAll()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.frameCounter = 0
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.supportPlane = nil
            self.lastAnchorTransform = nil
            self.silhouette = nil
            self.resetReportingState()
        }
    }

    var pointCount: Int {
        queue.sync { self.cloud.count }
    }

    func snapshot() -> PointCloud {
        queue.sync { self.cloud }
    }

    /// Cloud paired with its per-point view rays, read atomically off the recorder
    /// queue. Directions are nil unless they line up 1:1 with the cloud, so a
    /// persisted snapshot keeps the Fusion orientation across a reload.
    func snapshotWithDirections() -> (cloud: PointCloud, directions: [SIMD3<Float>]?) {
        queue.sync {
            let aligned = self.viewDirections.count == self.cloud.count
            return (self.cloud, aligned ? self.viewDirections : nil)
        }
    }

    /// Capture telemetry for the diagnostics breadcrumb, read atomically off the
    /// recorder queue. `carved` is how many bleed/ghost points free-space carving
    /// removed this scan — the field signal that "orbit to fix bleed" is working.
    struct CaptureStats: Sendable {
        var rawPoints: Int
        var carved: Int
        var fusionCells: Int
        var voxelSize: Float
        /// Metres the cloud was rigidly carried to follow ARKit drift this scan.
        var driftCorrected: Float
        /// Frames whose depth was dropped by the steadiness (anti-shake) gate.
        var motionSkipped: Int
        /// Candidates coarsened by content-adaptive density (flat regions).
        var contentCoarsened: Int
        /// Candidates rejected by the live support-plane crop (the pad/table).
        var supportCropped: Int
    }

    func captureStats() -> CaptureStats {
        queue.sync {
            CaptureStats(rawPoints: self.cloud.count, carved: self.carvedTotal,
                         fusionCells: self.fusionCells.count, voxelSize: self.voxelGrid.voxelSize,
                         driftCorrected: self.driftCorrectedTotal, motionSkipped: self.motionSkipped,
                         contentCoarsened: self.contentCoarsenedTotal,
                         supportCropped: self.supportCroppedTotal)
        }
    }

    /// Keyframes captured so far (photo + pose + depth, for texture baking).
    func snapshotKeyframes() -> [ScanKeyframe] {
        queue.sync { self.keyframeRecorder.keyframes }
    }

    /// A strided snapshot capped at `maxCount` points — cheap to rebuild for the
    /// live overlay even when the full cloud has grown into the millions.
    func overlaySnapshot(maxCount: Int) -> PointCloud {
        queue.sync { self.cloud.downsampled(maxCount: maxCount) }
    }

    /// How the recorder asks ARKit for a high-resolution still (the recorder
    /// never sees the session — the AR coordinator wires this in). Called on the
    /// recorder queue right after a keyframe is taken; the completion may arrive
    /// on any queue.
    func setHighResRequester(_ requester: (@Sendable (@escaping @Sendable (ARFrame?) -> Void) -> Void)?) {
        queue.async { self.highResRequester = requester }
    }

    /// Kicks the keyframe-quality upgrade: request the sensor's photo-resolution
    /// still and swap it into the keyframe captured at `token`. Best-effort —
    /// unsupported formats, a nil still or a drifted pose all just keep the
    /// video-resolution baseline that is already stored.
    private func upgradeKeyframe(token: simd_float4x4) {
        guard let requester = highResRequester else { return }
        requester { [weak self] frame in
            guard let self, let frame else { return }
            self.queue.async {
                self.keyframeRecorder.upgradeKeyframe(token: token, with: frame)
            }
        }
    }

    /// Feeds (or refreshes) the detected support plane under the scan target.
    /// Set-only during a scan — plane anchors flicker, the crop shouldn't.
    func setSupportPlane(normal: SIMD3<Float>, offset: Float) {
        let n = simd_normalize(normal)
        queue.async { self.supportPlane = (n.y < 0 ? -n : n, n.y < 0 ? -offset : offset) }
    }

    /// What the live density hints need to scale their expectation: the fusion
    /// voxel size, the configured depth (rooms only — a close object sweep is
    /// dense by construction), and the full cloud count for the sample ratio.
    func densityHintContext() -> (voxelSize: Float, maxDepth: Float, totalCount: Int) {
        queue.sync { (self.config.voxelSize, self.config.maxDepth, self.cloud.count) }
    }

    /// Snapshot with a cheap voxel‑neighbour outlier filter applied. Points whose
    /// 3x3x3 voxel block holds fewer than `minNeighbors` occupied cells are
    /// dropped; the per-point view directions stay index-aligned through the
    /// filter so the Fusion reconstruction can use them.
    ///
    /// Heavy on a large cloud (millions of points), so callers MUST run this off
    /// the main thread — doing it inline on `stopScan` blocked the main thread
    /// long enough for the watchdog to SIGKILL the app.
    func snapshotDenoised(minNeighbors: Int)
        -> (cloud: PointCloud, viewDirections: [SIMD3<Float>]) {
        queue.sync {
            guard minNeighbors > 1, !self.cloud.isEmpty else {
                return (self.cloud, self.viewDirections)
            }
            let hasDirections = self.viewDirections.count == self.cloud.count
            var filtered = PointCloud()
            filtered.reserveCapacity(self.cloud.count)
            var directions: [SIMD3<Float>] = []
            if hasDirections { directions.reserveCapacity(self.cloud.count) }
            for i in 0..<self.cloud.count
            where self.cloud.confidences[i] >= 0
                && self.voxelGrid.hasOccupiedNeighbors(of: self.cloud.positions[i], atLeast: minNeighbors) {
                filtered.append(position: self.cloud.positions[i],
                                color: self.cloud.colors[i],
                                confidence: self.cloud.confidences[i])
                if hasDirections { directions.append(self.viewDirections[i]) }
            }
            return (filtered, directions)
        }
    }

    // Note: true statistical outlier removal (mean k-NN distance + std-dev
    // threshold) lives in `PointCloudDenoiser.removeOutliers`, applied at review
    // time. The recorder keeps only the cheap voxel-neighbour pre-filter above,
    // which is fast enough to run inline when a scan stops.

    func reset() {
        queue.sync {
            self.cloud.removeAll()
            self.voxelGrid.reset()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.frameCounter = 0
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.supportPlane = nil
            self.lastAnchorTransform = nil
            self.silhouette = nil
            self.resetReportingState()
        }
    }

    // MARK: - Region of interest
    func setRegion(center: SIMD3<Float>, radius: Float) {
        queue.sync {
            self.regionCenter = center
            self.regionRadiusSq = radius * radius
        }
    }

    func setRegionRadius(_ radius: Float) {
        queue.sync {
            if self.regionCenter != nil {
                self.regionRadiusSq = radius * radius
            }
        }
    }

    func clearRegion() {
        queue.sync {
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.silhouette = nil
        }
    }

    /// Latest subject silhouette for targeted capture (nil clears it).
    func setSilhouette(_ newSilhouette: ScanSilhouette?) {
        queue.sync { self.silhouette = newSilhouette }
    }

    func clearAccumulation() {
        queue.sync {
            self.cloud.removeAll()
            self.voxelGrid.reset()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.resetReportingState()
        }
    }

    /// Resets progress/quality/coverage tracking. Must be called on `queue`.
    private func resetReportingState() {
        tombstones = 0
        carvedTotal = 0
        supportCroppedTotal = 0
        contentCoarsenedTotal = 0
        driftCorrectedTotal = 0
        motionSkipped = 0
        lastSteadyTransform = nil
        lastReportedCount = 0
        lastReportedConfidence = -1
        lastReportedCoverage = -1
        coverageEstimator.reset()
        orbitTracker.reset()
        orbitMean = .zero
        orbitSamples = 0
        lastReportedHeading = -1
    }

    var hasRegion: Bool {
        queue.sync { self.regionCenter != nil }
    }

    // MARK: - Frame processing

    /// Movement-gated keyframe capture only — used by mesh scans, which skip
    /// the point pipeline but still want photos for texture baking in review.
    func considerKeyframe(frame: ARFrame) {
        enqueueFrameWork {
            guard case .normal = frame.camera.trackingState else { return }
            if let token = self.keyframeRecorder.considerCapture(frame: frame) {
                self.upgradeKeyframe(token: token)
            }
        }
    }

    func process(frame: ARFrame) {
        enqueueFrameWork { self._process(frame: frame) }
    }

    /// Forwards frame work onto the recorder queue unless the backlog is already
    /// saturated, in which case the frame is dropped. The ARFrame `work`
    /// captures is released the moment the work runs, so at most
    /// `maxFramesInFlight` frames are ever held off the camera pipeline.
    private func enqueueFrameWork(_ work: @escaping @Sendable () -> Void) {
        frameBackpressureLock.lock()
        guard framesInFlight < maxFramesInFlight else {
            frameBackpressureLock.unlock()
            return
        }
        framesInFlight += 1
        frameBackpressureLock.unlock()
        queue.async {
            work()
            self.frameBackpressureLock.lock()
            self.framesInFlight -= 1
            self.frameBackpressureLock.unlock()
        }
    }

    private func _process(frame: ARFrame) {
        // Only accumulate while tracking is solid: during excessive motion,
        // relocalisation or feature loss the pose drifts, and points fused
        // then land smeared across the cloud.
        guard case .normal = frame.camera.trackingState else { return }
        frameCounter += 1
        let effectiveStride: Int
        if config.adaptiveStrideEnabled,
           let confMap = frame.smoothedSceneDepth?.confidenceMap {
            let avgConf = computeAverageConfidence(from: confMap)
            reportQualityIfChanged(avgConf)
            // Map confidence [0,1] to stride multiplier [1,4]: poor quality → sample less
            let multiplier = 1 + Int((1.0 - avgConf) * 3)
            effectiveStride = max(config.frameStride, 1) * multiplier
        } else {
            effectiveStride = max(config.frameStride, 1)
        }
        guard frameCounter % effectiveStride == 0 else { return }

        // Steadiness gate: drop a frame's depth when the camera is moving too fast
        // between processed frames — motion-blurred depth fuses into flying pixels.
        // Velocity is measured pose-to-pose; a deliberate orbit stays under the bar.
        if config.steadyMaxAngularSpeed > 0 || config.steadyMaxLinearSpeed > 0 {
            let transform = frame.camera.transform
            let now = frame.timestamp
            defer { lastSteadyTransform = transform; lastSteadyTime = now }
            if let last = lastSteadyTransform, now > lastSteadyTime {
                let dt = Float(now - lastSteadyTime)
                let delta = transform * last.inverse
                let dc = delta.columns.3
                let linear = simd_length(SIMD3<Float>(dc.x, dc.y, dc.z)) / dt
                let angular = abs(simd_quatf(delta).angle) / dt
                if (config.steadyMaxAngularSpeed > 0 && angular > config.steadyMaxAngularSpeed)
                    || (config.steadyMaxLinearSpeed > 0 && linear > config.steadyMaxLinearSpeed) {
                    motionSkipped += 1
                    return
                }
            }
        }

        if config.keyframesEnabled {
            if let token = keyframeRecorder.considerCapture(frame: frame) {
                upgradeKeyframe(token: token)
            }
        }

        guard let candidates = unprojector?.unproject(frame: frame, config: config)
                ?? cpuUnproject(frame: frame) else { return }

        let cameraPosition = frame.camera.transform.columns.3
        accumulate(candidates, cameraPosition: SIMD3<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z))
    }

    // MARK: - Accumulation (voxel fusion / dedup + cap)
    private func accumulate(_ candidates: Candidates, cameraPosition: SIMD3<Float>) {
        let cap = config.maxPoints
        let center = regionCenter
        let radiusSq = regionRadiusSq
        let silhouette = self.silhouette
        let n = candidates.positions.count
        // Content-adaptive density: classify each candidate's local surface as flat
        // (wall/floor) or structured (object) so the snap below can coarsen the flats
        // and keep detail fine. One cheap pass per frame; nil when disabled (objects).
        let details: [Float]? = config.contentAdaptiveEnabled
            ? CaptureDensity.surfaceVariation(candidates.positions,
                                              cellSize: max(voxelGrid.voxelSize * 3, 0.03))
            : nil
        var i = 0
        while i < n {
            let position = candidates.positions[i]
            if let center,
               simd_distance_squared(position, center) > radiusSq {
                i += 1; continue
            }
            if let silhouette, silhouette.rejects(position) {
                i += 1; continue
            }
            if let support = supportPlane {
                let d = simd_dot(support.normal, position) - support.offset
                if d < 0.010 {
                    // At/below the support plane. Keep a protective disc (half the
                    // ROI radius) under the subject so a flat object lying on the
                    // pad survives; everything further out is the pad itself.
                    var isProtected = false
                    if let center = regionCenter, regionRadiusSq > 0 {
                        let dc = simd_dot(support.normal, center) - support.offset
                        let lateral = (position - support.normal * d)
                            - (center - support.normal * dc)
                        isProtected = simd_length_squared(lateral) < regionRadiusSq * 0.25
                    }
                    if !isProtected {
                        supportCroppedTotal += 1
                        i += 1; continue
                    }
                }
            }
            // Snap distant OR flat points to a coarser lattice so far/blank surfaces
            // consume fewer points while close-up structured detail stays full-res.
            let detail = details?[i] ?? 1
            if config.contentAdaptiveEnabled, detail < config.contentDetailThreshold {
                contentCoarsenedTotal += 1
            }
            let stored = Self.adaptiveSnap(position, cameraDistance: simd_distance(position, cameraPosition),
                                           voxelSize: voxelGrid.voxelSize, detail: detail, config: config)
            let ray = stored - cameraPosition
            let rayLength = simd_length(ray)
            let direction = rayLength > 1e-6 ? ray / rayLength : SIMD3<Float>(0, 0, -1)
            if config.fusionEnabled, config.carveEnabled {
                // Free-space carving: this ray proves the space in front of
                // its hit is empty, so stored points sitting there (depth
                // ghosts, reflections, moved objects, silhouette bleed) lose
                // weight and die — later views *correct* earlier mistakes
                // instead of only averaging into them. The march itself bails
                // when the corridor is too short, so close object scans (where
                // the bleed is worst) are carved too.
                carveFreeSpace(cameraPosition: cameraPosition, direction: direction,
                               hitDistance: rayLength)
            }
            if config.fusionEnabled {
                fuse(position: stored, color: candidates.colors[i],
                     confidence: candidates.confidences[i], direction: direction, cap: cap)
            } else {
                if cloud.count >= cap { break }
                if voxelGrid.insert(stored) {
                    cloud.append(position: stored,
                                 color: candidates.colors[i],
                                 confidence: candidates.confidences[i])
                    viewDirections.append(direction)
                    recordSubjectSample(stored)
                }
            }
            i += 1
        }
        compactTombstonesIfNeeded()
        updateOrbitCoverage(cameraPosition: cameraPosition)

        let count = cloud.count
        // Report progress on the main actor.
        reportAfterAccumulate(count)
    }

    /// Marks the orbit sector the camera is in around the subject (the ROI when
    /// targeting, else the running mean of captured points) and reports a new
    /// sector so the coverage ring fills as the user walks around. Must run on
    /// `queue`. Needs a stable centre, so the tapless path waits for warmup.
    private func updateOrbitCoverage(cameraPosition: SIMD3<Float>) {
        let center = regionCenter ?? (orbitSamples >= 200 ? orbitMean : nil)
        guard let center else { return }
        let bandsBefore = orbitTracker.elevationBands
        let newSector = orbitTracker.observe(camera: cameraPosition, center: center)
        let heading = orbitTracker.headingFraction
        let bands = orbitTracker.elevationBands
        let newBand = bands != bandsBefore
        // Report on a new sector or elevation band OR when the live heading moved
        // enough (the "you are here" marker), wrap-aware so the 0/1 seam doesn't
        // spam updates.
        let delta = heading < 0 ? 0 : abs(heading - lastReportedHeading)
        let headingMoved = heading >= 0 && min(delta, 1 - delta) > 0.012
        guard newSector || newBand || headingMoved else { return }
        lastReportedHeading = heading
        let fraction = orbitTracker.fraction
        let sectors = orbitTracker.sectors
        DispatchQueue.main.async { [weak self] in
            self?.onOrbitCoverage?(fraction, sectors, heading, bands)
        }
    }

    /// Folds one captured point into the running subject-centre mean (O(1),
    /// numerically stable). Used as the orbit centre when no ROI is set.
    private func recordSubjectSample(_ p: SIMD3<Float>) {
        orbitSamples += 1
        orbitMean += (p - orbitMean) / Float(orbitSamples)
    }

    /// Marches the camera→hit ray and contradicts every fused voxel sitting in
    /// the empty corridor ahead of the surface: each loses `carveStrength`
    /// weight, and at zero it is tombstoned (confidence −1) and its cell freed
    /// so an honest re-observation can reclaim it. A safety margin before the
    /// hit keeps the real surface shell intact; the step count is capped
    /// (`carveMaxSteps`) so a long room ray can't blow the per-frame budget.
    ///
    /// Sampling the *whole* corridor (not two fixed probes) is what makes a
    /// slow orbit actually erase silhouette bleed: every later ray that grazes
    /// the floaters between the subject and its background now hits them. Must
    /// run on `queue`.
    private func carveFreeSpace(cameraPosition: SIMD3<Float>, direction: SIMD3<Float>,
                                hitDistance: Float) {
        guard !fusionCells.isEmpty else { return }
        let voxel = voxelGrid.voxelSize
        // Never carve the noise band hugging the actual surface, and skip the
        // few cm right at the lens (own hand / housing reflections). Scale the
        // margin with the voxel (clamped 2.5–10 cm) instead of a fixed 6 cm: on a
        // fine Object scan (2–3 mm voxels) a 6 cm shell protected almost the whole
        // small subject, so carving could never reach bleed hugging its edge.
        // Now object scans get a ~2.5 cm shell (carving reaches close bleed) while
        // room scans (20 mm voxels, noisier far walls) keep a ~10 cm shell.
        let margin = min(max(voxel * 5, 0.025), 0.10)
        let start = max(voxel, 0.05)
        let end = hitDistance - margin
        guard end > start else { return }
        let span = end - start
        // Sample roughly every ~1.2 voxels, but hard-capped at `carveMaxSteps`
        // probes per ray so the per-point cost is bounded regardless of corridor
        // length (CPU-watchdog safety). Long room corridors stride coarser; short
        // object corridors still get fine coverage (≈2 voxels apart at the cap).
        let steps = min(max(config.carveMaxSteps, 1), max(1, Int(span / (voxel * 1.2))))
        let step = span / Float(steps)
        let strength = config.carveStrength
        for stepIndex in 0...steps {
            let probe = cameraPosition + direction * (start + step * Float(stepIndex))
            let scaled = probe / voxel
            let key = SIMD3<Int32>(Int32(scaled.x.rounded(.down)),
                                   Int32(scaled.y.rounded(.down)),
                                   Int32(scaled.z.rounded(.down)))
            if let cell = fusionCells[key] {
                let weight = cell.weight - strength
                if weight <= 0 {
                    let index = Int(cell.index)
                    cloud.update(at: index, position: cloud.positions[index],
                                 color: cloud.colors[index], confidence: -1)
                    fusionCells.removeValue(forKey: key)
                    tombstones += 1
                    carvedTotal += 1
                } else {
                    fusionCells[key] = (cell.index, weight)
                }
            }
        }
    }

    /// Rebuilds the cloud without tombstoned points once they pass ~5%:
    /// indices shift, so fusion cells and view directions re-align and the
    /// dedup grid is re-seeded. Must run on `queue`.
    private func compactTombstonesIfNeeded() {
        guard tombstones >= 2_000, tombstones * 20 >= cloud.count else { return }
        var map = [Int32](repeating: -1, count: cloud.count)
        var compacted = PointCloud()
        compacted.reserveCapacity(cloud.count - tombstones)
        let hasDirections = viewDirections.count == cloud.count
        var directions: [SIMD3<Float>] = []
        if hasDirections { directions.reserveCapacity(cloud.count - tombstones) }
        for i in 0..<cloud.count where cloud.confidences[i] >= 0 {
            map[i] = Int32(compacted.count)
            compacted.append(position: cloud.positions[i], color: cloud.colors[i],
                             confidence: cloud.confidences[i])
            if hasDirections { directions.append(viewDirections[i]) }
        }
        var cells: [SIMD3<Int32>: (index: Int32, weight: Float)] = [:]
        cells.reserveCapacity(fusionCells.count)
        for (key, cell) in fusionCells {
            let mapped = map[Int(cell.index)]
            if mapped >= 0 { cells[key] = (mapped, cell.weight) }
        }
        cloud = compacted
        if hasDirections { viewDirections = directions }
        fusionCells = cells
        voxelGrid.reset()
        for p in cloud.positions { _ = voxelGrid.insert(p) }
        tombstones = 0
    }

    // MARK: - Drift / relocalisation recovery (targeted scans)

    /// Feeds the target anchor's current world transform. As ARKit refines its
    /// world map (continuous drift correction *and* relocalisation jumps) the
    /// anchor pose shifts while the already-fused points stay at their old
    /// coordinates, so new points land offset and the scan doubles / bleeds. When
    /// the anchor has moved past `driftCorrectMeters`/`Radians` from the baseline
    /// we rigidly carry the accumulated cloud along the same delta so old geometry
    /// stays glued to the physical subject. No-op for untargeted (room) scans,
    /// which never feed an anchor.
    func setAnchorTransform(_ transform: simd_float4x4) {
        queue.async { self.applyAnchorTransform(transform) }
    }

    /// Drops the drift baseline so a freshly tapped target doesn't diff against
    /// the previous anchor. Called when a new target anchor is created.
    func resetAnchorTracking() {
        queue.async { self.lastAnchorTransform = nil }
    }

    private func applyAnchorTransform(_ transform: simd_float4x4) {
        guard let last = lastAnchorTransform else { lastAnchorTransform = transform; return }
        let delta = transform * last.inverse
        let dt = delta.columns.3
        let translation = simd_length(SIMD3<Float>(dt.x, dt.y, dt.z))
        let angle = abs(simd_quatf(delta).angle)
        // Hold the baseline until the anchor has actually moved past the bar, so
        // *gradual* drift accumulates rather than being averaged away one
        // sub-threshold frame at a time (a slow orbit never produces a single
        // >5 cm jump, so the old fixed-5 cm bar left the cloud drifting). A real
        // relocalisation jump clears the bar in one step; smooth drift clears it
        // over several frames. Either way: re-glue the cloud, advance the baseline
        // to the corrected pose, and only then start accumulating the next delta.
        guard translation > config.driftCorrectMeters || angle > config.driftCorrectRadians else { return }
        rigidlyTransformCloud(by: delta)
        lastAnchorTransform = transform
        driftCorrectedTotal += translation
        let shifted = translation
        Task { @MainActor in
            Diagnostics.shared.log("scan", String(format: "drift-corrected %.1fcm", shifted * 100))
        }
    }

    /// Applies a rigid transform to every accumulated point + view direction and
    /// rebuilds the voxel index + fusion map (cell keys derive from positions, and
    /// carving runs against the fusion map). Modelled on the tombstone-compaction
    /// rebuild. O(n), but only fires when a drift / jump correction crosses the
    /// bar — a handful of times per scan, on the recorder queue.
    private func rigidlyTransformCloud(by m: simd_float4x4) {
        guard !cloud.isEmpty else { return }
        let rot = simd_float3x3(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let t = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        for i in 0..<cloud.count {
            cloud.update(at: i, position: rot * cloud.positions[i] + t,
                         color: cloud.colors[i], confidence: cloud.confidences[i])
        }
        if viewDirections.count == cloud.count {
            for i in 0..<viewDirections.count { viewDirections[i] = rot * viewDirections[i] }
        }
        // Cell keys derive from positions, so rebuild the dedup grid + fusion map.
        voxelGrid.reset()
        for p in cloud.positions { _ = voxelGrid.insert(p) }
        guard !fusionCells.isEmpty else { return }
        let voxel = voxelGrid.voxelSize
        var cells: [SIMD3<Int32>: (index: Int32, weight: Float)] = [:]
        cells.reserveCapacity(fusionCells.count)
        for (_, cell) in fusionCells {
            let idx = Int(cell.index)
            guard idx < cloud.count else { continue }
            let s = cloud.positions[idx] / voxel
            let key = SIMD3<Int32>(Int32(s.x.rounded(.down)),
                                   Int32(s.y.rounded(.down)),
                                   Int32(s.z.rounded(.down)))
            if let existing = cells[key] {
                if cell.weight > existing.weight { cells[key] = (cell.index, cell.weight) }
            } else {
                cells[key] = (cell.index, cell.weight)
            }
        }
        fusionCells = cells
    }

    /// Weighted running average per voxel (TSDF-style fusion): the stored point
    /// converges to the confidence-weighted mean of every sample that hit its
    /// voxel, which suppresses LiDAR depth noise instead of keeping the first
    /// (possibly noisy) sample. New voxels still respect the point cap; updates
    /// to existing voxels are free refinements. Must run on `queue`.
    private func fuse(position: SIMD3<Float>, color: SIMD3<Float>,
                      confidence: Float, direction: SIMD3<Float>, cap: Int) {
        let voxel = voxelGrid.voxelSize
        let s = position / voxel
        let key = SIMD3<Int32>(Int32(s.x.rounded(.down)),
                               Int32(s.y.rounded(.down)),
                               Int32(s.z.rounded(.down)))
        let weight = 0.25 + confidence   // low-confidence samples count, but less

        if let cell = fusionCells[key] {
            let index = Int(cell.index)
            let t = weight / (cell.weight + weight)
            let p = cloud.positions[index] + (position - cloud.positions[index]) * t
            let c = cloud.colors[index] + (color - cloud.colors[index]) * t
            let conf = cloud.confidences[index] + (confidence - cloud.confidences[index]) * t
            cloud.update(at: index, position: p, color: c, confidence: conf)
            let blended = viewDirections[index] + (direction - viewDirections[index]) * t
            let blendedLength = simd_length(blended)
            if blendedLength > 1e-6 { viewDirections[index] = blended / blendedLength }
            fusionCells[key] = (cell.index, min(cell.weight + weight, config.fusionMaxWeight))
        } else {
            guard cloud.count < cap else { return }
            fusionCells[key] = (Int32(cloud.count), weight)
            _ = voxelGrid.insert(position)   // keeps the denoise neighbour grid in sync
            cloud.append(position: position, color: color, confidence: confidence)
            viewDirections.append(direction)
            recordSubjectSample(position)
        }
    }

    /// Progress/coverage reporting shared by both accumulation paths.
    private func reportAfterAccumulate(_ count: Int) {
        if abs(count - lastReportedCount) >= 250 || (count > 0 && lastReportedCount == 0) {
            lastReportedCount = count
            let reported = count
            // Hop to MainActor to invoke the callback.
            DispatchQueue.main.async { [weak self] in
                self?.onProgress?(reported)
            }
        }
        if let coverage = coverageEstimator.update(totalCount: count) {
            reportCoverageIfChanged(coverage)
        }
    }

    /// Snaps `position` onto a distance-scaled voxel lattice. Points within
    /// `adaptiveVoxelNearDistance` (or when adaptive voxel is off) are returned
    /// unchanged; farther points snap to a lattice `multiplier`× coarser, where
    /// the multiplier grows one step per `adaptiveVoxelBandWidth` of distance up
    /// to `adaptiveVoxelMaxMultiplier`. Static + pure so it is unit-testable.
    static func adaptiveSnap(_ position: SIMD3<Float>, cameraDistance d: Float,
                             voxelSize: Float, detail: Float, config: ScanConfig) -> SIMD3<Float> {
        var multiplier: Float = 1
        // Distance coarsening: far surfaces are noisier/sparser, snap them coarser.
        if config.adaptiveVoxelEnabled, d > config.adaptiveVoxelNearDistance {
            let band = (d - config.adaptiveVoxelNearDistance) / max(config.adaptiveVoxelBandWidth, 0.01)
            let distMul = min(1 + Int(band), max(config.adaptiveVoxelMaxMultiplier, 1))
            multiplier = max(multiplier, Float(distMul))
        }
        // Content coarsening: a flat region (low surface variation) spends its
        // points on a coarser lattice while structured detail keeps the fine base.
        // Aligned-integer stepping: the multiplier is rounded to a whole number so a
        // coarse cell (2× voxelSize) nests inside the fine grid — every coarse lattice
        // line coincides with a fine one. A *fractional* ramp (the earlier fix) made
        // the cell size drift continuously across a wall and aliased into moiré
        // stripes + torn holes; a whole-number step keeps the flats solid and the
        // fine↔coarse boundary crack-free for the adaptive octree mesher to consume.
        // Gentle 2× cap so a flat wall never thins enough to hole.
        if config.contentAdaptiveEnabled, detail < config.contentDetailThreshold {
            let t = max(detail, 0) / config.contentDetailThreshold   // 0 flattest … 1 at threshold
            let maxMul = max(config.contentMaxMultiplier, 1)
            let stepped = (maxMul - (maxMul - 1) * t).rounded()      // whole multiples only
            multiplier = max(multiplier, max(stepped, 1))
        }
        guard multiplier > 1.001 else { return position }
        let cell = voxelSize * multiplier
        let s = position / cell
        return SIMD3<Float>(s.x.rounded(), s.y.rounded(), s.z.rounded()) * cell
    }

    // MARK: - CPU fallback unprojection
    private func cpuUnproject(frame: ARFrame) -> Candidates? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let captured = frame.capturedImage

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let imageRes = frame.camera.imageResolution
        let intrinsics = DepthMath.scaledIntrinsics(
            frame.camera.intrinsics, imageWidth: Float(imageRes.width), depthWidth: Float(depthWidth))
        let cameraTransform = frame.camera.transform

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        CVPixelBufferLockBaseAddress(captured, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            CVPixelBufferUnlockBaseAddress(captured, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let depthRowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride

        let confidencePtr = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }?
            .assumingMemoryBound(to: UInt8.self)
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let yBase = CVPixelBufferGetBaseAddressOfPlane(captured, 0)?.assumingMemoryBound(to: UInt8.self)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(captured, 0)
        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(captured, 1)?.assumingMemoryBound(to: UInt8.self)
        let cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(captured, 1)
        let imageWidth = CVPixelBufferGetWidthOfPlane(captured, 0)
        let imageHeight = CVPixelBufferGetHeightOfPlane(captured, 0)

        let sx = Float(imageWidth) / Float(depthWidth)
        let sy = Float(imageHeight) / Float(depthHeight)
        let stride = max(config.pixelStride, 1)

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        var confidences: [Float] = []

        var v = 0
        while v < depthHeight {
            var u = 0
            while u < depthWidth {
                let depth = depthPtr[v * depthRowStride + u]
                if depth <= 0 || !depth.isFinite || depth > config.maxDepth { u += stride; continue }
                if let confidencePtr,
                   confidencePtr[v * confidenceRowBytes + u] < config.minConfidence {
                    u += stride; continue
                }
                // Mirror the GPU kernel's silhouette-edge rejection (see
                // ScanCompute.metal): drop texels whose neighbour depth jumps,
                // which would otherwise unproject to flying pixels at the subject
                // outline. Disabled (threshold 0) for non-Object scans.
                if config.edgeThreshold > 0 {
                    let maxJump = config.edgeThreshold * depth
                    let dl = depthPtr[v * depthRowStride + (u > 0 ? u - 1 : 0)]
                    let dr = depthPtr[v * depthRowStride + min(u + 1, depthWidth - 1)]
                    let du = depthPtr[(v > 0 ? v - 1 : 0) * depthRowStride + u]
                    let dd = depthPtr[min(v + 1, depthHeight - 1) * depthRowStride + u]
                    if abs(dl - depth) > maxJump || abs(dr - depth) > maxJump
                        || abs(du - depth) > maxJump || abs(dd - depth) > maxJump {
                        u += stride; continue
                    }
                }
                let world = DepthMath.worldPoint(
                    u: Float(u), v: Float(v), depth: depth,
                    intrinsics: intrinsics, cameraTransform: cameraTransform)
                let color = sampleColor(
                    u: Int(Float(u) * sx), v: Int(Float(v) * sy),
                    width: imageWidth, height: imageHeight,
                    yBase: yBase, yRowBytes: yRowBytes,
                    cbcrBase: cbcrBase, cbcrRowBytes: cbcrRowBytes)
                let confidence = confidencePtr.map { Float($0[v * confidenceRowBytes + u]) / 2.0 } ?? 1.0
                positions.append(world)
                colors.append(color)
                confidences.append(confidence)
                u += stride
            }
            v += stride
        }
        return Candidates(positions: positions, colors: colors, confidences: confidences)
    }

    private func sampleColor(u: Int, v: Int, width: Int, height: Int,
                             yBase: UnsafePointer<UInt8>?, yRowBytes: Int,
                             cbcrBase: UnsafePointer<UInt8>?, cbcrRowBytes: Int) -> SIMD3<Float> {
        guard let yBase, let cbcrBase else { return SIMD3<Float>(repeating: 0.5) }
        let cu = min(max(u, 0), width - 1)
        let cv = min(max(v, 0), height - 1)
        let y = Float(yBase[cv * yRowBytes + cu]) / 255.0
        let chromaIndex = (cv / 2) * cbcrRowBytes + (cu / 2) * 2
        let cb = Float(cbcrBase[chromaIndex]) / 255.0
        let cr = Float(cbcrBase[chromaIndex + 1]) / 255.0
        let r = y + 1.4020 * cr - 0.7010
        let g = y - 0.3441 * cb - 0.7141 * cr + 0.5291
        let b = y + 1.7720 * cb - 0.8860
        return simd_clamp(SIMD3<Float>(r, g, b),
                          SIMD3<Float>(repeating: 0),
                          SIMD3<Float>(repeating: 1))
    }

    // MARK: - Helper
    private var lastReportedCount = 0
    private var lastReportedConfidence: Float = -1
    private var lastReportedCoverage: Float = -1
    private var coverageEstimator = ScanCoverageEstimator()
    private var orbitTracker = OrbitCoverageTracker()
    /// Running mean of captured points — the orbit centre when no ROI is set, so
    /// the coverage ring works even without a tap-to-target. O(1) per new point.
    private var orbitMean = SIMD3<Float>(repeating: 0)
    private var orbitSamples = 0
    private var lastReportedHeading: Float = -1

    /// Computes average ARKit confidence, normalised to [0, 1].
    /// ARConfidenceLevel pixels are 0 (low), 1 (medium), or 2 (high) — NOT 0–255.
    /// Samples every `sampleStride` pixels to stay cheap on the serial queue.
    private func computeAverageConfidence(from map: CVPixelBuffer) -> Float {
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(map) else { return 0 }
        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowStride = CVPixelBufferGetBytesPerRow(map)
        let sampleStride = 8
        var sum: Float = 0
        var count = 0
        var y = 0
        while y < height {
            let rowOffset = y * rowStride
            var x = 0
            while x < width {
                sum += Float(base[rowOffset + x])
                count += 1
                x += sampleStride
            }
            y += sampleStride
        }
        // Divide by 2 to normalise values 0/1/2 → 0.0/0.5/1.0.
        return count > 0 ? (sum / Float(count)) / 2.0 : 0
    }

    private func reportQualityIfChanged(_ confidence: Float) {
        guard abs(confidence - lastReportedConfidence) > 0.05 else { return }
        lastReportedConfidence = confidence
        DispatchQueue.main.async { [weak self] in
            self?.onQualityUpdate?(confidence)
        }
    }

    private func reportCoverageIfChanged(_ coverage: Float) {
        guard abs(coverage - lastReportedCoverage) > 0.03 else { return }
        lastReportedCoverage = coverage
        DispatchQueue.main.async { [weak self] in
            self?.onCoverageUpdate?(coverage)
        }
    }
}
