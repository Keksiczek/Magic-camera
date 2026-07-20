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
    /// Frame-to-model ICP registration. ARKit's pose is ±1–2 cm frame-to-frame
    /// (measured ~16 mm local-plane RMS on device clouds) — the noise floor
    /// that reads as crinkled walls, drift-doubled object orbits, wavy ceramic
    /// edges and shattered UV charts. Before a frame's depth is fused, a
    /// damped point-to-plane ICP aligns the frame against the model fused so
    /// far, and the (tiny) correction rides a cumulative ARKit→model transform
    /// applied to every accepted candidate and keyframe pose. Needs
    /// `fusionEnabled` (the model IS the fusion cloud); kill switch in
    /// Settings ("Frame alignment") à la the GPU texture bake.
    var icpEnabled: Bool = true
    /// Tikhonov damping of the per-frame ICP step toward the ARKit prior, as a
    /// fraction of the evidence (0 = trust ICP fully). Directions the visible
    /// geometry doesn't constrain (a single flat wall → its tangent plane)
    /// stay exactly on ARKit's answer; constrained directions converge to the
    /// ICP optimum across the solver's internal iterations.
    var icpPriorStrength: Float = 0.15

    /// ICP needs the fusion cells as its model — both switches must be on.
    var icpActive: Bool { icpEnabled && fusionEnabled }
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
    /// Finish-time multi-view visibility trim: drop points that several
    /// pose-diverse keyframes saw THROUGH (their depth at the projected pixel
    /// lands clearly behind the point) while at most one supports them — the
    /// surviving silhouette bleed that capture-side carving can't reach (its
    /// protective end-margin shields exactly the near-edge band bleed hugs).
    /// Keyframes only bank on movement, so the evidence is dwell-independent;
    /// occluded points yield no evidence and are kept. Needs keyframes.
    var finishVisibilityTrim: Bool = true
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
    /// Chunked capture ceiling: how many `maxPoints`-sized chunks one scan session
    /// may accumulate before the live cloud just plateaus at the cap (the old
    /// behaviour). When the live chunk fills `maxPoints` mid-scan it is sealed off
    /// and accumulation continues into a fresh grid in the *same* ARSession world
    /// frame — so a big space can be captured in one continuous sweep past the
    /// single-buffer ceiling, and the sealed chunks union by concatenation (no ICP)
    /// at finish. Peak memory stays bounded: the expensive fusion grid is always
    /// capped, sealed chunks are flat arrays. 1 disables chunking (hard cap as
    /// before); 4 lets a session reach ≈4× the point cap.
    var maxCaptureChunks: Int = 4
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
    /// Mesh-mode capture, tuned for what the sweep actually is. The shared base is
    /// the same everywhere (8 mm near voxel + distance coarsening, carving,
    /// keyframes, plane seeds); only the scene-vs-subject specifics differ — mesh
    /// mode used to carry SUBJECT tuning even while sweeping a whole room, which
    /// is why a Mesh room scan behaved worse than the equivalent Room point scan:
    /// it stopped at 5 m (far walls never registered), filled its cap at 2 M (so a
    /// big sweep chunked early, seaming), carved at the object strength 1.4 (which
    /// erodes a room's sparsely-sampled far walls into holes) and trimmed depth
    /// edges at 0.09 (a whole room is mostly *legitimate* depth edges). Scene mode
    /// now mirrors the Room preset's reach, cap, carving and edge policy.
    static func meshCapture(objectMode: Bool) -> ScanConfig {
        var config = ScanConfig(frameStride: 3, pixelStride: 2, minConfidence: 1,
                                voxelSize: 0.008,
                                maxPoints: objectMode ? 2_000_000 : 3_000_000,
                                maxDepth: objectMode ? 5.0 : 7.0)
        config.adaptiveVoxelEnabled = true
        config.adaptiveVoxelNearDistance = 2.5
        // Silhouette flying pixels are a SUBJECT defect; a room's depth edges are real.
        config.edgeThreshold = objectMode ? 0.09 : 0
        // Aggressive carving clears a subject's bleed in one close orbit; a room's
        // far walls are seen from farther and fewer times, so the same strength
        // erodes them (Room point scans use 1.0 for exactly this reason).
        config.carveStrength = objectMode ? 1.4 : 1.0
        // Plane anchors seed the review-time wall flattening (same as Room point
        // scans) — mesh scans were the one capture path without them (a mesh-mode
        // window scan logged 'planes 5 (0 seeded)').
        config.wantsPlanes = true
        return config
    }
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
    /// Per-voxel fusion bookkeeping. `seen`/`carves` implement scene-consensus
    /// carving: silhouette bleed hugging an edge is protected from the weight
    /// carve twice over (the end-margin shields the band near a grazing hit,
    /// and every look at the silhouette re-supports it), so a cell that is
    /// SEEN only a couple of times but has free-space rays pass through it
    /// again and again dies on the vote ratio — "walking around the chair
    /// recomputes the corner", exactly the re-observation logic the user asked
    /// for. Real surface keeps seen growing in step with carves and is immune.
    struct FusionCell {
        var index: Int32
        var weight: Float
        var seen: UInt16
        var carves: UInt16
    }
    /// Voxel → fusion cell (stored point index, accumulated weight, votes).
    private var fusionCells: [SIMD3<Int32>: FusionCell] = [:]
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
    /// Whether a high-resolution still request is outstanding (queue-confined;
    /// the completion clears it back on `queue`). Bounds how many ARFrames the
    /// upgrade path can hold off the camera pipeline — see `upgradeKeyframe`.
    private var highResInFlight = false
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

    // MARK: - Frame-to-model registration (ICP) state

    /// Correspondence grid for the per-frame ICP: a fixed 24 mm cell holding
    /// the index of a recently re-confirmed (seen ≥3) fused point inside it.
    /// Fixed cell because the search reach must cover ARKit's ±1–2 cm
    /// inter-frame jitter regardless of the fusion voxel — probing ±1 cell of
    /// an Object scan's 3 mm lattice would only reach 6 mm. The seen-gate
    /// keeps one-look geometry (silhouette bleed lives at seen 1–2) out of
    /// the ICP model so the solver can't chase it. Which member represents a
    /// cell doesn't matter: point-to-plane residuals are insensitive to
    /// tangential slack, and every stored position keeps refining toward its
    /// local fused mean. Maintained by `fuse`, remapped on compaction,
    /// rebuilt on a rigid carry, cleared with the live grid (a sealed chunk
    /// leaves the model empty and ICP just re-warms).
    private static let icpCellSize: Float = 0.024
    private var icpCells: [SIMD3<Int32>: Int32] = [:]
    /// Cumulative ARKit-world → model-world correction. Every accepted
    /// candidate (and keyframe pose) is premultiplied with it, so the fused
    /// cloud stays internally registered even as ARKit's world estimate
    /// breathes underneath. Identity until the first accepted solve.
    private var icpCorrection = matrix_identity_float4x4
    private var icpHasCorrection = false
    /// Where the model actually is, in ARKit space: the centroid of the last
    /// frame's matched samples. The cumulative correction must be *measured at
    /// the data* — the transform's own translation column is taken about the
    /// world origin, so it carries a rotation lever arm of |centroid| × angle
    /// and says nothing about how far the geometry moved. A room scanned 7.7 m
    /// from where the session started read `cum 302mm` off 2.3° of perfectly
    /// ordinary yaw drift and tripped the runaway freeze 27 s into a 4.5-minute
    /// scan. `FrameToModelICP.Solution.translation` already reports the
    /// per-frame correction this way; the cumulative bound just never did.
    private var icpReference: SIMD3<Float>?
    /// Diagnostics: frames the solver ran on / corrections accepted, and the
    /// per-frame correction magnitudes' running sum & max (metres).
    private var icpAttempted = 0
    private var icpApplied = 0
    private var icpTranslationSum: Float = 0
    private var icpTranslationMax: Float = 0
    /// One-shot latch for the "cumulative bound hit" breadcrumb.
    private var icpFreezeLogged = false

    /// How far the cumulative correction `m` drags the model, measured at the
    /// data rather than at the world origin. Zero until ICP has a reference.
    private func icpDrag(_ m: simd_float4x4, at reference: SIMD3<Float>?) -> Float {
        guard let reference else { return 0 }
        return FrameToModelICP.drag(of: m, at: reference)
    }

    @inline(__always)
    private func icpKey(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        let s = p / Self.icpCellSize
        return SIMD3<Int32>(Int32(s.x.rounded(.down)),
                            Int32(s.y.rounded(.down)),
                            Int32(s.z.rounded(.down)))
    }
    /// Chunked capture: sealed segments of the session. When the live cloud fills
    /// the point cap mid-scan it is moved here (tombstones dropped) and the live
    /// grid is cleared, so accumulation continues into a fresh chunk. All chunks
    /// share the one ARSession world frame, so `snapshot*` unions them by
    /// concatenation — no ICP. Emptied on reset/configure/clearAccumulation.
    private var sealedChunks: [(cloud: PointCloud, directions: [SIMD3<Float>])] = []
    /// Running point total across sealed chunks (so `pointCount`/progress reflect
    /// the whole session, not just the live chunk that resets to 0 after a seal).
    private var sealedPointTotal = 0
    /// One-shot latch so the "session full — capture plateaued" note fires once.
    private var sessionFullReported = false

    // MARK: - Live photo coverage
    /// Coarse world cells holding captured surface, and the subset some texture
    /// keyframe has actually photographed. Their difference is precisely what the
    /// bake later reports as `unseen` — the triangles that fall back to soft cloud
    /// colour. Tracking it live lets the sweep overlay show the user *where* to
    /// point the camera, which neither the point-density hint (samples, not photos)
    /// nor the orbit ring (camera angles, not surface) can.
    // 9 cm (was 12): fine enough that chair legs, shelf edges and window frames
    // get their own hint cells instead of vanishing into a wall's cell, while
    // the overlay mesh stays bounded (a room is a few thousand cells either way).
    private static let coverageCellSize: Float = 0.09
    private var surfaceCells: Set<SIMD3<Int32>> = []
    private var photoCells: Set<SIMD3<Int32>> = []
    private var lastReportedPhotoCoverage: Float = -1
    /// Pose at the last coverage mark, and whether THIS frame qualifies — a spaced,
    /// photo-worthy viewpoint, independent of the keyframe store's cap.
    private var lastCoverageTransform: simd_float4x4?
    private var markCoverageThisFrame = false

    @inline(__always)
    private func coverageKey(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        let s = p / Self.coverageCellSize
        return SIMD3<Int32>(Int32(s.x.rounded(.down)),
                            Int32(s.y.rounded(.down)),
                            Int32(s.z.rounded(.down)))
    }

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
    /// Fired on the main actor when the fraction of captured surface that some
    /// keyframe photo has covered changes noticeably (0…1). Drives the live
    /// "photos N%" readout beside the point count.
    var onPhotoCoverage: (@MainActor @Sendable (Float) -> Void)?
    /// Fired on the main actor when chunked capture seals a full chunk mid-scan
    /// (`sessionFull` = false, with the running session total) so the UI can coach
    /// "keep sweeping — N points so far" without stopping, and once more when the
    /// session chunk ceiling is hit and capture plateaus (`sessionFull` = true).
    var onChunkSealed: (@MainActor @Sendable (_ sessionTotal: Int, _ sessionFull: Bool) -> Void)?

    // MARK: - Lifecycle
    init(config: ScanConfig = ScanConfig()) {
        self.config = config
        self.voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
    }

    // MARK: - Configuration
    func configure(_ config: ScanConfig) {
        // Write-only: async so a tap/start on the main thread never waits for a
        // frame mid-fusion; the serial queue keeps ordering for later reads.
        queue.async {
            self.config = config
            self.voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
            self.cloud.removeAll()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.icpCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.frameCounter = 0
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.supportPlane = nil
            self.lastAnchorTransform = nil
            self.silhouette = nil
            self.clearSealedChunks()
            self.resetReportingState()
        }
    }

    var pointCount: Int {
        queue.sync { self.sealedPointTotal + self.cloud.count }
    }

    func snapshot() -> PointCloud {
        queue.sync { self.unionedLocked().cloud }
    }

    /// Cloud paired with its per-point view rays, read atomically off the recorder
    /// queue. Directions are nil unless they line up 1:1 with the cloud, so a
    /// persisted snapshot keeps the Fusion orientation across a reload.
    func snapshotWithDirections() -> (cloud: PointCloud, directions: [SIMD3<Float>]?) {
        queue.sync {
            let unioned = self.unionedLocked()
            let aligned = unioned.directions.count == unioned.cloud.count
            return (unioned.cloud, aligned ? unioned.directions : nil)
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
        /// Whether a scan target (ROI) was set — `support-crop 0` is expected
        /// without one (the crop needs the target to place its protective disc),
        /// a diagnosis the export couldn't make before.
        var hadTarget: Bool
        /// Frame-to-model ICP telemetry: frames the solver ran on, corrections
        /// accepted, the mean/max per-frame correction and the final cumulative
        /// ARKit→model correction (all metres). `applied ≈ attempted` with a
        /// small mean is the healthy signature; `applied ≪ attempted` means the
        /// acceptance gates rejected most solves (bad normals? moving scene?).
        var icpAttempted: Int
        var icpApplied: Int
        var icpMeanCorrection: Float
        var icpMaxCorrection: Float
        var icpCumulative: Float
    }

    func captureStats() -> CaptureStats {
        queue.sync {
            // At the data, not at the origin — see `icpDrag`. Reporting the
            // transform's translation column made every room look like it had
            // drifted decimetres when the model had barely moved.
            let cumulative = self.icpDrag(self.icpCorrection, at: self.icpReference)
            return CaptureStats(rawPoints: self.cloud.count, carved: self.carvedTotal,
                                fusionCells: self.fusionCells.count, voxelSize: self.voxelGrid.voxelSize,
                                driftCorrected: self.driftCorrectedTotal, motionSkipped: self.motionSkipped,
                                contentCoarsened: self.contentCoarsenedTotal,
                                supportCropped: self.supportCroppedTotal,
                                hadTarget: self.regionCenter != nil,
                                icpAttempted: self.icpAttempted,
                                icpApplied: self.icpApplied,
                                icpMeanCorrection: self.icpApplied > 0
                                    ? self.icpTranslationSum / Float(self.icpApplied) : 0,
                                icpMaxCorrection: self.icpTranslationMax,
                                icpCumulative: cumulative)
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
        queue.async {
            self.highResRequester = requester
            // A still requested against the previous session may never call
            // back; re-arming the hook re-arms the in-flight latch with it.
            self.highResInFlight = false
        }
    }

    /// Kicks the keyframe-quality upgrade: request the sensor's photo-resolution
    /// still and swap it into the keyframe captured at `token`. Best-effort —
    /// unsupported formats, a nil still or a drifted pose all just keep the
    /// video-resolution baseline that is already stored.
    private func upgradeKeyframe(token: simd_float4x4) {
        // One still in flight at a time. Every banked keyframe used to fire a
        // `captureHighResolutionFrame` unconditionally, and each pending
        // completion holds an ARFrame off the camera pipeline: a long room
        // sweep banks them faster than a 12 MP still round-trips, so they
        // stacked up until ARKit warned it was "retaining 11 ARFrames" and
        // throttled camera delivery — starving depth fusion, ICP *and* the
        // very keyframes the upgrade exists to sharpen (53 banked in 4.5 min,
        // where a 47 s scan banks 36). A skipped upgrade costs one keyframe
        // its 12 MP pixels and keeps the 1920×1440 video frame; a throttled
        // camera costs the whole scan.
        guard let requester = highResRequester, !highResInFlight else { return }
        highResInFlight = true
        requester { [weak self] frame in
            guard let self else { return }
            self.queue.async {
                self.highResInFlight = false
                guard let frame else { return }
                // The still arrives within a frame or two of the keyframe, so
                // the current ICP correction is the right one for its pose.
                self.keyframeRecorder.upgradeKeyframe(
                    token: token, with: frame,
                    poseCorrection: self.icpHasCorrection ? self.icpCorrection : nil)
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
            // Union the whole session (sealed chunks ++ live). When nothing has
            // sealed this is just the live cloud + its grid (the fast path).
            let (source, sourceDirs) = self.unionedLocked()
            guard minNeighbors > 1, !source.isEmpty else { return (source, sourceDirs) }
            // The live `voxelGrid` only knows the current chunk; sealed-chunk points
            // would fail the neighbour test against it. Rebuild occupancy over the
            // whole union so every point is filtered against its real neighbourhood.
            // (Skipped when no chunks sealed — the live grid already covers it.)
            let grid: VoxelGrid
            if self.sealedChunks.isEmpty {
                grid = self.voxelGrid
            } else {
                var built = VoxelGrid(voxelSize: self.voxelGrid.voxelSize)
                for i in 0..<source.count where source.confidences[i] >= 0 {
                    _ = built.insert(source.positions[i])
                }
                grid = built
            }
            let hasDirections = sourceDirs.count == source.count
            var filtered = PointCloud()
            filtered.reserveCapacity(source.count)
            var directions: [SIMD3<Float>] = []
            if hasDirections { directions.reserveCapacity(source.count) }
            for i in 0..<source.count
            where source.confidences[i] >= 0
                && grid.hasOccupiedNeighbors(of: source.positions[i], atLeast: minNeighbors) {
                filtered.append(position: source.positions[i],
                                color: source.colors[i],
                                confidence: source.confidences[i])
                if hasDirections { directions.append(sourceDirs[i]) }
            }
            return (filtered, directions)
        }
    }

    // Note: true statistical outlier removal (mean k-NN distance + std-dev
    // threshold) lives in `PointCloudDenoiser.removeOutliers`, applied at review
    // time. The recorder keeps only the cheap voxel-neighbour pre-filter above,
    // which is fast enough to run inline when a scan stops.

    func reset() {
        queue.async {
            self.cloud.removeAll()
            self.voxelGrid.reset()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.icpCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.frameCounter = 0
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.supportPlane = nil
            self.lastAnchorTransform = nil
            self.silhouette = nil
            self.clearSealedChunks()
            self.resetReportingState()
        }
    }

    // MARK: - Chunked capture

    /// Empties everything that spans a whole capture session: the sealed chunks and
    /// the live photo-coverage maps. Must run on `queue`. Sealing a chunk
    /// deliberately does NOT call this — coverage accumulates across chunks.
    private func clearSealedChunks() {
        sealedChunks.removeAll(keepingCapacity: true)
        sealedPointTotal = 0
        sessionFullReported = false
        surfaceCells.removeAll(keepingCapacity: true)
        photoCells.removeAll(keepingCapacity: true)
        lastReportedPhotoCoverage = -1
        lastCoverageTransform = nil
    }

    /// The whole session as one cloud (+ aligned view directions): sealed chunks
    /// ++ the live chunk. Must run on `queue`. When nothing has sealed this is the
    /// live cloud verbatim, so the common (sub-cap) scan pays no extra cost.
    private func unionedLocked() -> (cloud: PointCloud, directions: [SIMD3<Float>]) {
        guard !sealedChunks.isEmpty else { return (cloud, viewDirections) }
        var union = PointCloud()
        union.reserveCapacity(sealedPointTotal + cloud.count)
        var directions: [SIMD3<Float>] = []
        directions.reserveCapacity(sealedPointTotal + cloud.count)
        var aligned = true
        for chunk in sealedChunks {
            union.append(contentsOf: chunk.cloud)
            if chunk.directions.count == chunk.cloud.count {
                directions.append(contentsOf: chunk.directions)
            } else { aligned = false }
        }
        union.append(contentsOf: cloud)
        if viewDirections.count == cloud.count {
            directions.append(contentsOf: viewDirections)
        } else { aligned = false }
        return (union, aligned && directions.count == union.count ? directions : [])
    }

    /// Seals the live chunk (dropping tombstoned points) into `sealedChunks` and
    /// clears the live fusion grid so accumulation continues into a fresh chunk in
    /// the same world frame. Keyframes, ROI/target, support plane, anchor drift
    /// tracking and orbit coverage are session-wide and deliberately kept. Must
    /// run on `queue`.
    private func sealCurrentChunk() {
        guard !cloud.isEmpty else { return }
        let hasDirections = viewDirections.count == cloud.count
        var chunk = PointCloud()
        chunk.reserveCapacity(cloud.count)
        var chunkDirs: [SIMD3<Float>] = []
        if hasDirections { chunkDirs.reserveCapacity(cloud.count) }
        for i in 0..<cloud.count where cloud.confidences[i] >= 0 {
            chunk.append(position: cloud.positions[i],
                         color: cloud.colors[i],
                         confidence: cloud.confidences[i])
            if hasDirections { chunkDirs.append(viewDirections[i]) }
        }
        sealedChunks.append((chunk, chunkDirs))
        sealedPointTotal += chunk.count
        cloud.removeAll()
        voxelGrid.reset()
        fusionCells.removeAll(keepingCapacity: true)
        icpCells.removeAll(keepingCapacity: true)
        viewDirections.removeAll(keepingCapacity: true)
        tombstones = 0
    }

    // MARK: - Region of interest
    func setRegion(center: SIMD3<Float>, radius: Float) {
        queue.async {
            self.regionCenter = center
            self.regionRadiusSq = radius * radius
        }
    }

    func setRegionRadius(_ radius: Float) {
        queue.async {
            if self.regionCenter != nil {
                self.regionRadiusSq = radius * radius
            }
        }
    }

    func clearRegion() {
        queue.async {
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.silhouette = nil
        }
    }

    /// Latest subject silhouette for targeted capture (nil clears it).
    func setSilhouette(_ newSilhouette: ScanSilhouette?) {
        queue.async { self.silhouette = newSilhouette }
    }

    func clearAccumulation() {
        queue.async {
            self.cloud.removeAll()
            self.voxelGrid.reset()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.icpCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.clearSealedChunks()
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
        icpCorrection = matrix_identity_float4x4
        icpHasCorrection = false
        icpReference = nil
        icpAttempted = 0
        icpApplied = 0
        icpTranslationSum = 0
        icpTranslationMax = 0
        icpFreezeLogged = false
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

    // MARK: - Photo coverage (live)

    /// Rotation angle (radians) between two camera orientations — the coverage
    /// gate's rotational component.
    private func rotationAngle(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let ra = simd_quatf(simd_float3x3(columns: (
            SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
            SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
            SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))))
        let rb = simd_quatf(simd_float3x3(columns: (
            SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
            SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
            SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))))
        return abs((ra.inverse * rb).angle)
    }

    /// Pre-marks coverage from a prior scan when this sweep CONTINUES it.
    /// Without this every previously photographed surface re-appeared amber on
    /// a continue ("resetne ty kostičky i ty co už máme") even though the merge
    /// at finish reuses the saved keyframes. Surface cells come from the saved
    /// cloud; a cell counts as photographed when some saved keyframe saw it
    /// from photo distance (the same 3.5 m gate the live marks use) and roughly
    /// in front of that camera. Async on the recorder queue — a bounded stride
    /// keeps the seeding to a fraction of a second even for multi-million-point
    /// scans.
    func seedCoverage(points: [SIMD3<Float>], keyframePoses: [simd_float4x4]) {
        queue.async {
            let cameras: [(pos: SIMD3<Float>, fwd: SIMD3<Float>)] = keyframePoses.map {
                (SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z),
                 // ARKit camera looks down its −Z axis.
                 -SIMD3($0.columns.2.x, $0.columns.2.y, $0.columns.2.z))
            }
            let stride = max(1, points.count / 120_000)
            var i = 0
            while i < points.count {
                let p = points[i]
                i += stride
                let cell = self.coverageKey(p)
                self.surfaceCells.insert(cell)
                guard !self.photoCells.contains(cell) else { continue }
                for camera in cameras {
                    let d = p - camera.pos
                    let dist = simd_length(d)
                    guard dist > 1e-4, dist <= 3.5 else { continue }
                    if simd_dot(d / dist, camera.fwd) > 0.55 {
                        self.photoCells.insert(cell)
                        break
                    }
                }
            }
        }
    }

    /// Centres of the captured surface cells no keyframe has photographed yet — the
    /// "point the camera here" hint the sweep overlay draws. Capped so a huge room
    /// can't build an unbounded overlay mesh; the nearest ones matter most anyway.
    func uncoveredCells(limit: Int = 4_000) -> (centers: [SIMD3<Float>], cellSize: Float) {
        queue.sync {
            var centers: [SIMD3<Float>] = []
            centers.reserveCapacity(Swift.min(limit, self.surfaceCells.count))
            for cell in self.surfaceCells where !self.photoCells.contains(cell) {
                let corner = SIMD3<Float>(Float(cell.x), Float(cell.y), Float(cell.z))
                centers.append((corner + 0.5) * Self.coverageCellSize)
                if centers.count >= limit { break }
            }
            return (centers, Self.coverageCellSize)
        }
    }

    /// Fraction of captured surface cells a keyframe photo has covered. Must run on
    /// `queue`; reported only on a meaningful change so the UI doesn't churn.
    private func reportPhotoCoverageIfChanged() {
        guard surfaceCells.count >= 40 else { return }
        var covered = 0
        for cell in surfaceCells where photoCells.contains(cell) { covered += 1 }
        let fraction = Float(covered) / Float(surfaceCells.count)
        guard abs(fraction - lastReportedPhotoCoverage) >= 0.01 else { return }
        lastReportedPhotoCoverage = fraction
        DispatchQueue.main.async { [weak self] in self?.onPhotoCoverage?(fraction) }
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
        // Texture keyframes are considered on EVERY tracked frame, before the point
        // pipeline's frame stride and steadiness gates get to skip it. They have
        // their own movement (9 cm / 10°), anti-blur and count-cap gates, so this
        // costs a pose comparison on the frames that don't qualify and only does the
        // expensive JPEG + depth copy when a photo is genuinely due. Sitting behind
        // the stride (3, and up to ×4 more when confidence dips) starved photo
        // coverage exactly where the pipeline is heaviest: a Mesh scene scan banked
        // 25 keyframes over 124 s where a point scan banks 43 over 47 s, leaving 23%
        // of its triangles with no photo at all (`unseen`) and a soft cloud colour.
        if config.keyframesEnabled {
            // Keyframe poses carry the current ICP correction so the bake
            // projects photos from where the frame's geometry actually landed
            // (a keyframe banked between ICP frames uses the last estimate —
            // stale by ≤2 frames, millimetres at drift rates).
            if let token = keyframeRecorder.considerCapture(
                frame: frame, poseCorrection: icpHasCorrection ? icpCorrection : nil) {
                upgradeKeyframe(token: token)
            }
        }
        // Photo-coverage gate: a cell only counts as "photographed" when the
        // CURRENT pose is close enough to a BANKED keyframe that the bake will
        // actually reproject a photo onto what this frame sees. The previous
        // gate was just "moved 6 cm since the last mark" — completely decoupled
        // from whether a keyframe existed — so a fast blurred sweep cleared the
        // amber hints while the bake later reported 46 k triangles `unseen` (15%)
        // on a device room: the overlay promised photo texture the bake could
        // not deliver. Scanning near a banked pose keeps clearing (this is what
        // survives the keyframe cap + thinning: proximity is checked against the
        // *kept* keyframes, so the overlay never freezes when the cap is hit —
        // thinned-away viewpoints simply need a fresh photo again, which is the
        // honest answer). Slack beyond the 9 cm / 10° banking gate: a pose is
        // covered until it drifts ~1.5 gates from every kept keyframe, at which
        // point the recorder is about to bank a new one anyway.
        markCoverageThisFrame = false
        let camXform = frame.camera.transform
        let camPos = SIMD3<Float>(camXform.columns.3.x, camXform.columns.3.y, camXform.columns.3.z)
        if config.keyframesEnabled {
            for keyframe in keyframeRecorder.keyframes {
                let kf = keyframe.cameraTransform
                let kp = SIMD3<Float>(kf.columns.3.x, kf.columns.3.y, kf.columns.3.z)
                if simd_distance(kp, camPos) < 0.15,
                   rotationAngle(from: kf, to: camXform) < 0.26 {
                    markCoverageThisFrame = true
                    break
                }
            }
        } else if let last = lastCoverageTransform {
            // No keyframes on this path (internal captures) — keep the old
            // motion-spaced heuristic so the coverage counter still moves.
            if simd_distance(SIMD3<Float>(last.columns.3.x, last.columns.3.y, last.columns.3.z),
                             camPos) >= 0.06
                || rotationAngle(from: last, to: camXform) >= 0.12 {
                markCoverageThisFrame = true
            }
        } else {
            markCoverageThisFrame = true
        }
        if markCoverageThisFrame { lastCoverageTransform = camXform }
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

        guard let candidates = unprojector?.unproject(frame: frame, config: config)
                ?? cpuUnproject(frame: frame) else { return }

        let cameraColumn = frame.camera.transform.columns.3
        let cameraPosition = SIMD3<Float>(cameraColumn.x, cameraColumn.y, cameraColumn.z)
        if config.icpActive {
            // Frame-to-model registration: refine the running ARKit→model
            // correction against the model fused so far. The correction is
            // applied inside `accumulate`, per point AFTER the crop tests —
            // the ROI / silhouette / support entities live in ARKit space.
            refineRegistration(candidates: candidates)
        }
        accumulate(candidates, cameraPosition: cameraPosition,
                   correction: config.icpActive && icpHasCorrection ? icpCorrection : nil)
    }

    // MARK: - Accumulation (voxel fusion / dedup + cap)
    private func accumulate(_ candidates: Candidates, cameraPosition: SIMD3<Float>,
                            correction: simd_float4x4?) {
        let cap = config.maxPoints
        let center = regionCenter
        let radiusSq = regionRadiusSq
        let silhouette = self.silhouette
        let n = candidates.positions.count
        // The ARKit→model ICP correction, decomposed once. Crop tests (ROI
        // sphere, silhouette mask, support plane) run on the RAW ARKit-space
        // positions — those entities are fed live from ARKit, and testing
        // corrected positions against them misaligns by the full cumulative
        // correction (on a pot scan whose correction had drifted to ~25 cm,
        // the silhouette mask stopped catching rim bleed and the support
        // crop cut a shifted plane). Fusion, carving and coverage live in
        // model space, so the correction applies after the tests.
        let hasCorrection = correction != nil
        let rot: simd_float3x3
        let shift: SIMD3<Float>
        if let m = correction {
            rot = simd_float3x3(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            shift = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        } else {
            rot = matrix_identity_float3x3
            shift = .zero
        }
        let cameraModel = hasCorrection ? rot * cameraPosition + shift : cameraPosition
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
            // Crop tests passed — this point is kept. From here on everything
            // (snap lattice, coverage cells, carve rays, fusion) is model space.
            let placed = hasCorrection ? rot * position + shift : position
            // Snap distant OR flat points to a coarser lattice so far/blank surfaces
            // consume fewer points while close-up structured detail stays full-res.
            let detail = details?[i] ?? 1
            if config.contentAdaptiveEnabled, detail < config.contentDetailThreshold {
                contentCoarsenedTotal += 1
            }
            let stored = Self.adaptiveSnap(placed, cameraDistance: simd_distance(placed, cameraModel),
                                           voxelSize: voxelGrid.voxelSize, detail: detail, config: config)
            // This cell holds captured surface; on a photo-worthy viewpoint it's
            // also marked photographed. The difference (captured but not yet seen
            // from a good angle) drives the live "photograph this" hint. The
            // distance gate keeps the hint honest for far surfaces: a wall seen
            // only from 5 m away has a keyframe, but so few pixels land on it
            // that it bakes soft anyway — leave it amber until the user walks
            // closer (a device room ended overlay-clean yet 13% `unseen`).
            let cell = coverageKey(stored)
            surfaceCells.insert(cell)
            let ray = stored - cameraModel
            let rayLength = simd_length(ray)
            if markCoverageThisFrame, rayLength <= 3.5 { photoCells.insert(cell) }
            let direction = rayLength > 1e-6 ? ray / rayLength : SIMD3<Float>(0, 0, -1)
            if config.fusionEnabled, config.carveEnabled {
                // Free-space carving: this ray proves the space in front of
                // its hit is empty, so stored points sitting there (depth
                // ghosts, reflections, moved objects, silhouette bleed) lose
                // weight and die — later views *correct* earlier mistakes
                // instead of only averaging into them. The march itself bails
                // when the corridor is too short, so close object scans (where
                // the bleed is worst) are carved too.
                carveFreeSpace(cameraPosition: cameraModel, direction: direction,
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
        updateOrbitCoverage(cameraPosition: cameraModel)

        // Chunked capture: once the live chunk fills the point cap, seal it and
        // keep sweeping into a fresh grid (same world frame) so a big space isn't
        // stuck at the single-buffer ceiling. Past the session chunk limit the
        // live chunk just plateaus (old behaviour) and we note it once.
        if config.fusionEnabled, config.maxCaptureChunks > 1, cap > 0, cloud.count >= cap {
            if sealedChunks.count < config.maxCaptureChunks - 1 {
                sealCurrentChunk()
                let total = sealedPointTotal
                DispatchQueue.main.async { [weak self] in self?.onChunkSealed?(total, false) }
            } else if !sessionFullReported {
                sessionFullReported = true
                let total = sealedPointTotal + cloud.count
                DispatchQueue.main.async { [weak self] in self?.onChunkSealed?(total, true) }
            }
        }

        // Report progress on the main actor (session total, so the badge keeps
        // climbing across a seal instead of snapping back to the fresh chunk's 0).
        reportAfterAccumulate(cloud.count)
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
        // margin with the voxel (clamped 2.5–12 cm) instead of a fixed 6 cm: on a
        // fine Object scan (2–3 mm voxels) a 6 cm shell protected almost the whole
        // small subject, so carving could never reach bleed hugging its edge.
        // Object scans stay at a ~2.5 cm shell (floor); room scans (12 mm voxels)
        // now get a ~10 cm shell (voxel×8, was ×5 = 6 cm). A device room diag
        // showed carving removing 1.2 M of 2.4 M raw points — at grazing angles a
        // ray skims a wall and the wall voxels a few cm before the hit fell inside
        // the carve corridor and were eroded into holes. A deeper protective shell
        // keeps those grazing walls intact; genuine foreground bleed is farther
        // from the surface and still carved.
        let margin = min(max(voxel * 8, 0.025), 0.12)
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
                let carves = cell.carves == .max ? cell.carves : cell.carves + 1
                // Scene consensus: seen barely, carved repeatedly → free space
                // agreed by many viewpoints — die regardless of the remaining
                // weight the silhouette re-support keeps topping up. The
                // `seen ≤ 3` bound is the thin-structure guard: a wicker strand
                // orbited a few times accumulates seen quickly even though rays
                // legitimately pass through the weave gaps beside it (probe
                // quantisation lands carve votes ON the strand cells — a device
                // room carved 27% of its raw points and shredded the chair
                // worse). Classic silhouette bleed stays at seen 1–2 for the
                // whole scan, so the consensus still catches exactly it.
                let consensus = carves >= 5 && cell.seen <= 3
                    && UInt32(carves) >= 3 * UInt32(cell.seen)
                if weight <= 0 || consensus {
                    let index = Int(cell.index)
                    cloud.update(at: index, position: cloud.positions[index],
                                 color: cloud.colors[index], confidence: -1)
                    fusionCells.removeValue(forKey: key)
                    tombstones += 1
                    carvedTotal += 1
                } else {
                    fusionCells[key] = FusionCell(index: cell.index, weight: weight,
                                                  seen: cell.seen, carves: carves)
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
        var cells: [SIMD3<Int32>: FusionCell] = [:]
        cells.reserveCapacity(fusionCells.count)
        for (key, cell) in fusionCells {
            let mapped = map[Int(cell.index)]
            if mapped >= 0 {
                cells[key] = FusionCell(index: mapped, weight: cell.weight,
                                        seen: cell.seen, carves: cell.carves)
            }
        }
        cloud = compacted
        if hasDirections { viewDirections = directions }
        fusionCells = cells
        // Positions didn't move, so the ICP cell keys stay valid — just remap
        // the stored indices and drop cells whose representative died.
        if !icpCells.isEmpty {
            var remapped: [SIMD3<Int32>: Int32] = [:]
            remapped.reserveCapacity(icpCells.count)
            for (key, index) in icpCells {
                let mapped = map[Int(index)]
                if mapped >= 0 { remapped[key] = mapped }
            }
            icpCells = remapped
        }
        voxelGrid.reset()
        for p in cloud.positions { _ = voxelGrid.insert(p) }
        tombstones = 0
    }

    // MARK: - Frame-to-model registration (ICP)

    /// Refines the running ARKit→model correction against the model fused so
    /// far: samples this frame's candidates, matches each against the coarse
    /// ICP grid (nearest live representative within ~3 cm — the probed
    /// 27-cell block doubles as the local plane-fit neighbourhood), and folds
    /// an accepted damped point-to-plane solve into `icpCorrection`. Rejected
    /// solves (too big = relocalisation-scale, the anchor carry's job; or not
    /// improving their own inliers) leave the ARKit pose untouched — the next
    /// processed frame simply re-measures. Must run on `queue`.
    private func refineRegistration(candidates: Candidates) {
        // Model warm-up: a handful of cells can't constrain 6 DoF. The view
        // rays double as the fallback normals, so require alignment too.
        guard icpCells.count >= 200, viewDirections.count == cloud.count else { return }
        let positions = candidates.positions
        let total = positions.count
        guard total >= FrameToModelICP.minCorrespondences else { return }
        let hasCorrection = icpHasCorrection
        let m = icpCorrection
        let rot = simd_float3x3(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let translation = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let center = regionCenter
        let radiusSq = regionRadiusSq
        // ~2 k samples bound the per-frame cost; the 27-probe search per
        // sample is the same order as one carve ray, well inside the budget.
        // On a targeted scan the budget is spent on the candidates inside the
        // ROI — the model is ROI-cropped, so outside it there is nothing to
        // match. Striding the WHOLE frame instead starved a small subject
        // (shaker filled ~a tenth of the frame) below the solver minimum:
        // object scans logged `icp applied 0/577`.
        let sampleTarget = 2_000
        var sampleIndices: [Int]
        if let center, radiusSq > 0 {
            var eligible: [Int] = []
            eligible.reserveCapacity(4_096)
            for i in 0..<total
            where simd_distance_squared(positions[i], center) <= radiusSq {
                eligible.append(i)
            }
            let stride = max(1, eligible.count / sampleTarget)
            sampleIndices = []
            sampleIndices.reserveCapacity(eligible.count / stride + 1)
            var k = 0
            while k < eligible.count {
                sampleIndices.append(eligible[k])
                k += stride
            }
        } else {
            let stride = max(1, total / sampleTarget)
            sampleIndices = []
            sampleIndices.reserveCapacity(total / stride + 1)
            var k = 0
            while k < total {
                sampleIndices.append(k)
                k += stride
            }
        }
        guard sampleIndices.count >= FrameToModelICP.minCorrespondences else { return }
        icpAttempted += 1
        let maxDistSq: Float = 0.03 * 0.03
        var pairs: [FrameToModelICP.Correspondence] = []
        pairs.reserveCapacity(sampleIndices.count)
        var neighbors: [SIMD3<Float>] = []
        neighbors.reserveCapacity(27)
        /// Uncorrected centroid of the samples that matched — where this
        /// frame's data sits in ARKit space, and so the point at which the
        /// cumulative correction's drag is honest (see `icpDrag`).
        var rawSum = SIMD3<Float>()
        for sampleIndex in sampleIndices {
            var p = positions[sampleIndex]
            if hasCorrection { p = rot * p + translation }
            let key = icpKey(p)
            neighbors.removeAll(keepingCapacity: true)
            var bestIndex = -1
            var bestDistSq = maxDistSq
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let probe = SIMD3<Int32>(key.x &+ Int32(dx),
                                                 key.y &+ Int32(dy),
                                                 key.z &+ Int32(dz))
                        guard let stored = icpCells[probe] else { continue }
                        let index = Int(stored)
                        guard index < cloud.count, cloud.confidences[index] >= 0 else { continue }
                        let q = cloud.positions[index]
                        neighbors.append(q)
                        let distSq = simd_distance_squared(q, p)
                        if distSq < bestDistSq { bestDistSq = distSq; bestIndex = index }
                    }
                }
            }
            guard bestIndex >= 0 else { continue }
            // Normal: local plane over the probed neighbourhood when it is
            // trustworthy, else the fused view ray — the same proxy the
            // Fusion reconstruction itself orients by.
            let toCamera = -viewDirections[bestIndex]
            let normal = FrameToModelICP.planeNormal(neighbors, fallback: toCamera)
            rawSum += positions[sampleIndex]
            pairs.append(.init(source: p, target: cloud.positions[bestIndex], normal: normal))
        }
        if !pairs.isEmpty { icpReference = rawSum / Float(pairs.count) }
        guard let solution = FrameToModelICP.solve(
            pairs, priorStrength: config.icpPriorStrength) else { return }
        // Per-frame corrections are jitter-scale: anything bigger is a bad
        // fit or a relocalisation event (the anchor carry's job) — and a
        // solve that didn't improve its own inliers chased something.
        guard solution.translation <= 0.02, solution.rotation <= 0.0175,
              solution.rmsAfter <= solution.rmsBefore else { return }
        let updated = solution.transform * icpCorrection
        // Runaway guard: the cumulative correction tracks genuine slow drift
        // and should stay centimetre-scale; only a feedback loop would grow
        // it further — freeze (keep applying the last good correction)
        // rather than follow it. Targeted scans get a much tighter bound:
        // they feed the anchor, and a steady anchor (`drift 0.0cm`) with a
        // still-growing correction is self-drift by definition — the pot
        // scan that reached 248 mm proved it.
        //
        // Measured at the data, NOT at the world origin: the correction is a
        // rotation about the scene, so its origin-translation column is
        // ≈ angle × |scene centroid| — pure lever arm. A 131 m² room whose
        // centroid sat 7.7 m from the session origin tripped this bound on
        // 2.3° of ordinary yaw drift, 27 s into a 4.5-minute scan, and spent
        // the rest of the walk with its rotational correction pinned (`applied
        // 2702/3021`). The bound now scales with nothing but how far the model
        // itself is being dragged, so it means the same thing in a cupboard
        // and at the far end of a flat.
        let cumulativeBound: Float = regionCenter != nil ? 0.10 : 0.30
        let drag = icpDrag(updated, at: icpReference)
        guard drag < cumulativeBound else {
            if !icpFreezeLogged {
                icpFreezeLogged = true
                let mm = drag * 1000
                Task { @MainActor in
                    Diagnostics.shared.log("scan icp", String(
                        format: "cum bound hit — correction frozen at %.0fmm", mm))
                }
            }
            return
        }
        icpCorrection = updated
        icpHasCorrection = true
        icpApplied += 1
        icpTranslationSum += solution.translation
        icpTranslationMax = max(icpTranslationMax, solution.translation)
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
        //
        // With per-frame ICP active, gradual drift already belongs to the ICP
        // correction — carrying the cloud for it too would double-apply the
        // same delta (the carry moves the model while ICP keeps holding frames
        // at the old alignment, smearing fusion until ICP re-converges). Raise
        // the bar so only genuine relocalisation jumps — beyond ICP's 2 cm/1°
        // per-frame acceptance — trigger the rigid carry.
        let translationBar = config.icpActive
            ? max(config.driftCorrectMeters, 0.06) : config.driftCorrectMeters
        let rotationBar = config.icpActive
            ? max(config.driftCorrectRadians, 0.07) : config.driftCorrectRadians
        guard translation > translationBar || angle > rotationBar else { return }
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
        var cells: [SIMD3<Int32>: FusionCell] = [:]
        cells.reserveCapacity(fusionCells.count)
        for (_, cell) in fusionCells {
            let idx = Int(cell.index)
            guard idx < cloud.count else { continue }
            let s = cloud.positions[idx] / voxel
            let key = SIMD3<Int32>(Int32(s.x.rounded(.down)),
                                   Int32(s.y.rounded(.down)),
                                   Int32(s.z.rounded(.down)))
            if let existing = cells[key] {
                if cell.weight > existing.weight { cells[key] = cell }
            } else {
                cells[key] = cell
            }
        }
        fusionCells = cells
        // ICP cell keys derive from positions too — re-key the representatives.
        if !icpCells.isEmpty {
            var rebuilt: [SIMD3<Int32>: Int32] = [:]
            rebuilt.reserveCapacity(icpCells.count)
            for (_, index) in icpCells {
                let idx = Int(index)
                guard idx < cloud.count else { continue }
                rebuilt[icpKey(cloud.positions[idx])] = index
            }
            icpCells = rebuilt
        }
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
            let seen = cell.seen == .max ? cell.seen : cell.seen + 1
            fusionCells[key] = FusionCell(
                index: cell.index,
                weight: min(cell.weight + weight, config.fusionMaxWeight),
                seen: seen,
                carves: cell.carves)
            // ICP aligns only against CONFIRMED surface: a cell serves as a
            // correspondence target once it has been seen ≥3 times. Freshly
            // fused silhouette bleed (seen 1–2 for its whole life) never
            // enters the ICP model — without this gate each orbit frame's
            // rim bleed matched the previous frame's rim bleed and dragged
            // the correction along the orbit (a 32 s pot scan self-drifted
            // 248 mm that way). Also self-heals a carved representative.
            if config.icpEnabled, seen >= 3 { icpCells[icpKey(p)] = cell.index }
        } else {
            guard cloud.count < cap else { return }
            fusionCells[key] = FusionCell(index: Int32(cloud.count), weight: weight,
                                          seen: 1, carves: 0)
            _ = voxelGrid.insert(position)   // keeps the denoise neighbour grid in sync
            cloud.append(position: position, color: color, confidence: confidence)
            viewDirections.append(direction)
            recordSubjectSample(position)
        }
    }

    /// Progress/coverage reporting shared by both accumulation paths.
    private func reportAfterAccumulate(_ liveCount: Int) {
        // Session total across sealed chunks + the live chunk, so the live badge and
        // coverage stay monotonic when a chunk seals (live resets to 0). Identical to
        // `liveCount` for a normal sub-cap scan (sealedPointTotal == 0).
        let count = sealedPointTotal + liveCount
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
        reportPhotoCoverageIfChanged()
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
