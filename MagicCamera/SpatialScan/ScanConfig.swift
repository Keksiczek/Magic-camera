//
//  ScanConfig.swift
//  Magic Camera
//
//  Every knob the capture loop reads, in one place, with the reason each value
//  is what it is. `CaptureQuality` maps the user-facing tiers onto these — reach
//  for the tier, not the field, unless the field is genuinely global.
//
//  See docs/analysis/SCAN-TUNING.md for the map of these against the rest of the
//  pipeline's constants.
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
    /// Graded per-sample confidence (see `DepthSampleConfidence`). Instead of
    /// every sample that clears the hard gates entering at full ARKit confidence,
    /// each one is scored by several independent signals — silhouette proximity,
    /// grazing incidence, range, position in frame, camera motion — and the score
    /// multiplies its confidence. Fusion weights by that number and the
    /// reconstruction drops what never earned belief, so bleed dies of neglect
    /// rather than needing a gate loose enough to be safe and tight enough to
    /// work. A sample is only *rejected* when several signals agree.
    /// Kill switch in Settings ("Sample confidence").
    var confidenceGradingEnabled: Bool = true
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
