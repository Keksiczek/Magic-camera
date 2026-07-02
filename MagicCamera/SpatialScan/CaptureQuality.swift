//
//  CaptureQuality.swift
//  Magic Camera
//
//  One quality dial for the whole spatial-scan pipeline. A CaptureQuality level
//  (Draft / Balanced / Max) maps to a capture ScanConfig *and* the reconstruction
//  defaults (detail + method) so the two stages stay consistent, and a shared
//  estimator turns the chosen settings into an upfront cost — expected points and
//  memory before a scan, expected triangles and memory before a reconstruction.
//
//  ScanQuality (the four-tier capture preset) stays the underlying capture config
//  and still backs RoomPlan and the persisted default; CaptureQuality is the
//  unified front the Spatial Scan UI drives, plus the home of the estimates.
//

import Foundation
import simd

/// Predicted cost of a capture at a given quality.
struct CaptureEstimate {
    let maxPoints: Int
    let memoryMB: Double

    var pointsText: String { MeasurementFormat.count(maxPoints) + " pts" }
    var memoryText: String { String(format: "~%.0f MB", memoryMB) }
    var summary: String { "up to \(pointsText) · \(memoryText)" }
}

/// Predicted cost of a cloud → surface reconstruction.
struct ReconstructionEstimate {
    let triangles: Int
    let memoryMB: Double

    /// Coarse, device-independent speed band from the triangle budget.
    var timeBand: String {
        switch triangles {
        case ..<60_000:   return "fast"
        case ..<250_000:  return "moderate"
        default:          return "slow"
        }
    }
    var summary: String {
        String(format: "≈ %@ tris · ~%.0f MB · %@",
               MeasurementFormat.count(triangles), memoryMB, timeBand)
    }
}

/// Shared cost model. Pure value math (ARKit-free, unit-testable); deliberately
/// rough — these are upfront hints, not promises.
enum QualityEstimator {
    /// Peak resident bytes per accumulated point during a scan: the cloud's
    /// position/colour/confidence arrays plus the per-point view directions and
    /// the fusion/dedup bookkeeping. Padded SIMD3 strides dominate.
    static let captureBytesPerPoint = 80
    /// Bytes per output triangle: shared vertices (≈ half a vertex/triangle,
    /// position + normal) plus the index triple.
    static let reconstructBytesPerTriangle = 30

    static func capture(maxPoints: Int) -> CaptureEstimate {
        CaptureEstimate(maxPoints: maxPoints,
                        memoryMB: Double(maxPoints * captureBytesPerPoint) / 1_000_000)
    }

    /// Estimated triangle count for meshing `cloud` at `detail` with `method`.
    /// Interpolating ball-pivot scales with point density; the lattice methods
    /// scale with surface area over the cell size squared.
    static func reconstruction(cloud: PointCloud, detail: MeshDetail,
                               method: ReconstructionMethod) -> ReconstructionEstimate {
        let points = cloud.count
        guard points > 0, let box = cloud.boundingBox() else {
            return ReconstructionEstimate(triangles: 0, memoryMB: 0)
        }
        let triangles: Int
        if method == .ballPivot {
            // Roughly two triangles per surviving point.
            triangles = Int(Double(points) * 1.8)
        } else {
            let extent = box.max - box.min
            let maxExtent = max(extent.x, extent.y, extent.z, 0.01)
            // Smooth/Fusion run the lattice 16 steps finer (see reconstructMesh).
            let resolution = method == .voxel ? detail.resolution : detail.resolution + 16
            let cell = maxExtent / Float(max(resolution, 1))
            // Bounding-box surface area, halved for the typically-open back.
            let area = 2 * (extent.x * extent.y + extent.x * extent.z + extent.y * extent.z) * 0.5
            let surfaceCells = Double(area / max(cell * cell, 1e-6))
            // ~2.5 triangles per surface cell, but never more than the sampling
            // density can actually support.
            triangles = min(Int(surfaceCells * 2.5), points * 6)
        }
        let clamped = max(triangles, 0)
        return ReconstructionEstimate(
            triangles: clamped,
            memoryMB: Double(clamped * reconstructBytesPerTriangle) / 1_000_000)
    }
}

/// The unified quality dial. Drives capture and reconstruction together.
enum CaptureQuality: String, CaseIterable, Identifiable {
    case draft = "Draft"
    case balanced = "Balanced"
    case max = "Max"
    case object = "Object"
    case room = "Room"
    var id: String { rawValue }

    /// Underlying capture preset (also what RoomPlan / settings speak). Object
    /// and Room have no four-tier equivalent, so they borrow existing slots.
    var scanQuality: ScanQuality {
        switch self {
        case .draft:    return .fast
        case .balanced: return .balanced
        case .max, .object: return .ultra
        case .room:     return .detailed
        }
    }

    var scanConfig: ScanConfig {
        switch self {
        case .object:
            return Self.objectConfig(fine: false, rangeMeters: 1.5)
        case .room:
            return Self.roomConfig()
        default:
            // A milder version of Object mode's silhouette-bleed trim: with a
            // higher threshold only the largest depth jumps (clear foreground /
            // background gaps) are dropped, so general scans shed their worst
            // flying pixels without holing legitimate scene edges. Room stays off
            // (handled above) — a whole room is mostly legitimate depth edges.
            var config = scanQuality.config
            config.edgeThreshold = 0.09
            return config
        }
    }

    /// Tunable Object-mode config. `fine` drops to 2 mm voxels (Object+, for
    /// coins/jewellery — much more memory); `rangeMeters` is the max capture
    /// depth (clamped 1.0…2.5 m). Adaptive voxel coarsening is off so density
    /// stays uniform across the whole close-up subject.
    static func objectConfig(fine: Bool, rangeMeters: Float) -> ScanConfig {
        var config = ScanConfig(frameStride: 2, pixelStride: 1, minConfidence: 1,
                                voxelSize: fine ? 0.002 : 0.003,
                                maxPoints: 2_000_000,
                                // Qualified: inside this enum the `max` case
                                // shadows the global `max(_:_:)`.
                                maxDepth: Swift.min(Swift.max(rangeMeters, 1.0), 2.5))
        config.adaptiveVoxelEnabled = false
        // Object scans frame a subject against a background, so the LiDAR
        // silhouette bleeds "flying pixels" around its outline. Reject sharp
        // depth discontinuities (≈4% of depth) so the subject's edges stay clean.
        config.edgeThreshold = 0.04
        // Close subjects show hand-shake worst, and shake motion-blurs the depth
        // map into flying pixels. Skip fusing frames captured mid-jerk; a
        // deliberate orbit (~0.3–0.5 rad/s) stays well under these bars.
        config.steadyMaxAngularSpeed = 1.0   // ~57°/s
        config.steadyMaxLinearSpeed = 0.5    // m/s
        // Capture ARKit's scene mesh + planes alongside the cloud so review can
        // mask the cloud to ARKit's clean geometry (the floaters ARKit omits are
        // exactly the bleed) and crop the floor from a detected plane.
        config.wantsSceneMesh = true
        config.wantsPlanes = true
        return config
    }

    /// Room preset: long range so far walls register, a high point cap for the
    /// large surface area, a moderate voxel (sub-cm detail is wasted on a whole
    /// room and just burns memory), and adaptive voxel coarsening so distant
    /// walls thin out instead of saturating the cap mid-room. Pairs with the
    /// (now bounded) Fusion reconstruction.
    static func roomConfig() -> ScanConfig {
        // 12 mm uniform near voxel — a touch finer than the long-standing 15 mm
        // (so room objects get a little more detail) but still a single, even
        // density for the default (uniform) pipeline. Distance coarsening (aligned
        // integer multiples, no aliasing) always thins far walls under the 2 M cap;
        // the wide near band keeps the close room full-res.
        var config = ScanConfig(frameStride: 3, pixelStride: 2, minConfidence: 1,
                                voxelSize: 0.012, maxPoints: 2_000_000, maxDepth: 7.0)
        config.adaptiveVoxelEnabled = true
        config.adaptiveVoxelNearDistance = 2.5
        // Content-adaptive capture stays OFF even with "Variable-resolution surfaces"
        // on. Coarsening the flat walls at CAPTURE time makes them a visibly sparse
        // grid in the point-cloud review ("mřížky") — any coarsened cloud reads as a
        // lattice of dots — and there's no point budget to reclaim (a room scan sits
        // far under the 2 M cap; this one kept 54 k). The variable-resolution benefit
        // is delivered at RECONSTRUCTION time instead: the adaptive octree meshes the
        // walls coarse and the objects fine from a dense, even cloud, so the cloud
        // stays smooth and only the model goes adaptive. (adaptiveSnap's content path
        // is left in, just unused, for a future capture-side experiment.)
        config.contentAdaptiveEnabled = false
        return config
    }

    var reconstructDetail: MeshDetail {
        switch self {
        case .draft:    return .draft
        case .balanced: return .standard
        case .max, .object: return .ultra
        case .room:     return .detailed
        }
    }

    var reconstructMethod: ReconstructionMethod {
        switch self {
        case .draft:    return .voxel
        case .balanced: return .smooth
        case .max, .object, .room: return .fusion
        }
    }

    var detailLine: String {
        switch self {
        case .draft:    return "Fastest, lightest — good for a quick look."
        case .balanced: return "A solid trade-off of detail and size."
        case .max:      return "Finest detail — needs a dense, patient scan."
        case .object:   return "Small objects up close — fine detail, short range."
        case .room:     return "Whole rooms — long range, wide coverage."
        }
    }

    var captureEstimate: CaptureEstimate { QualityEstimator.capture(maxPoints: scanConfig.maxPoints) }

    /// Nearest unified level for a stored four-tier preset (so the persisted
    /// default still picks a sensible starting profile).
    init(scanQuality: ScanQuality) {
        switch scanQuality {
        case .fast:               self = .draft
        case .balanced:           self = .balanced
        case .detailed, .ultra:   self = .max
        }
    }
}

extension ScanQuality {
    /// Upfront capture cost for this preset.
    var estimate: CaptureEstimate { QualityEstimator.capture(maxPoints: config.maxPoints) }
}
