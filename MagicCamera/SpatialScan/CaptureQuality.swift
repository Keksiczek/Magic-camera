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
    var id: String { rawValue }

    /// Underlying capture preset (also what RoomPlan / settings speak). Object
    /// has no four-tier equivalent, so it borrows Ultra's slot for storage.
    var scanQuality: ScanQuality {
        switch self {
        case .draft:    return .fast
        case .balanced: return .balanced
        case .max, .object: return .ultra
        }
    }

    var scanConfig: ScanConfig {
        switch self {
        case .object:
            // Small objects scanned up close: fine 3 mm voxels for crisp
            // detail, a short 1.5 m range so the room beyond never floods the
            // budget, and the full cap so the subject isn't point-starved.
            // pixelStride 1 + frameStride 2 keeps near-field density high.
            return ScanConfig(frameStride: 2, pixelStride: 1, minConfidence: 1,
                              voxelSize: 0.003, maxPoints: 2_000_000, maxDepth: 1.5)
        default:
            return scanQuality.config
        }
    }

    var reconstructDetail: MeshDetail {
        switch self {
        case .draft:    return .draft
        case .balanced: return .standard
        case .max, .object: return .ultra
        }
    }

    var reconstructMethod: ReconstructionMethod {
        switch self {
        case .draft:    return .voxel
        case .balanced: return .smooth
        case .max, .object: return .fusion
        }
    }

    var detailLine: String {
        switch self {
        case .draft:    return "Fastest, lightest — good for a quick look."
        case .balanced: return "A solid trade-off of detail and size."
        case .max:      return "Finest detail — needs a dense, patient scan."
        case .object:   return "Small objects up close — fine detail, short range."
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
