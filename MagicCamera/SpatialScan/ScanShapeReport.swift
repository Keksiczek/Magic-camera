//
//  ScanShapeReport.swift
//  Magic Camera
//
//  Three numbers the diagnostics export could not produce, each of which cost a
//  round to compute by hand from the user's own scan files (see
//  docs/analysis/HANDOFF-r88.md, "The measurements, so the next round can repeat
//  them"):
//
//    • Is what a stage kept a PANCAKE? `isFlat` decides it, but the breadcrumb
//      only ever carried counts, so "isolate funnel — … cluster 1174" said
//      nothing about the shape of those 1174 points. The lamp that reconstructed
//      to 108 × 125 × 1 mm and the mug that came back as its own top 4.6 cm were
//      both invisible here and both had to be measured off an exported USDZ.
//
//    • WHERE did a stage take its points from? A room's table was 450 k points
//      in the cloud and simply absent from the mesh; the count funnel showed the
//      loss but not the band it came out of. A height profile of the same cloud
//      before and after names the band, which turns "why did my table vanish"
//      into "which of these two stages emptied 0.7–0.9 m".
//
//    • How hot was the phone? ARKit throttles its depth cadence under thermal
//      pressure, so a slow, sparse, drifting late-scan sweep and a healthy one
//      look identical in every field the export had.
//
//  All three are pure functions over positions, cheap enough (one linear pass)
//  to sit on a breadcrumb path, and none of them changes behaviour.
//

import Foundation
import simd

enum ScanShapeReport {

    // MARK: - Shape

    /// `bbox 108×125×1 mm · thin 0.008` — extents largest-axis-last, plus the
    /// thinness ratio (shortest extent ÷ longest). **A subject under ~0.15 is
    /// the pancake `SpatialScanViewModel.isFlat` refuses**, so the number and
    /// the gate can be read against each other in one line.
    static func shape(_ positions: [SIMD3<Float>]) -> String {
        guard let first = positions.first else { return "bbox —" }
        var lo = first, hi = first
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let e = hi - lo
        let dims = [e.x, e.y, e.z]
        let longest = dims.max() ?? 0
        let shortest = dims.min() ?? 0
        let thin = longest > 0 ? shortest / longest : 0
        return String(format: "bbox %@ · thin %.3f", extents(dims), thin)
    }

    static func shape(_ cloud: PointCloud) -> String { shape(cloud.positions) }

    /// Millimetres while the object still fits a table, metres once it is a room
    /// — the same reading the user gets in the Measurements sheet.
    private static func extents(_ dims: [Float]) -> String {
        let longest = dims.max() ?? 0
        if longest < 2 {
            let mm = dims.map { String(format: "%.0f", $0 * 1000) }
            return mm.joined(separator: "×") + " mm"
        }
        let m = dims.map { String(format: "%.2f", $0) }
        return m.joined(separator: "×") + " m"
    }

    // MARK: - Height profile

    /// `y 0.00→2.41 m · 12/31/18/9/6/8/11/5%` — the share of points in each of
    /// `buckets` equal height bands, floor first.
    ///
    /// Run it on the cloud and on the delivered mesh's vertices and compare the
    /// same band: a band that goes from a fifth of the points to nothing is the
    /// furniture a stage deleted, and it names the band without anyone having to
    /// parse a PLY.
    static func heightProfile(_ positions: [SIMD3<Float>], buckets: Int = 8) -> String {
        guard !positions.isEmpty, buckets > 0 else { return "y —" }
        var lo = positions[0].y, hi = positions[0].y
        for p in positions {
            lo = min(lo, p.y)
            hi = max(hi, p.y)
        }
        let span = hi - lo
        guard span > 0.001 else { return String(format: "y %.2f m · flat", lo) }
        var bins = [Int](repeating: 0, count: buckets)
        for p in positions {
            let t = (p.y - lo) / span
            let index = min(buckets - 1, max(0, Int(t * Float(buckets))))
            bins[index] += 1
        }
        let total = Float(positions.count)
        let shares = bins.map { String(format: "%.0f", Float($0) / total * 100) }
        return String(format: "y %.2f→%.2f m · %@%%", lo, hi, shares.joined(separator: "/"))
    }

    static func heightProfile(_ cloud: PointCloud, buckets: Int = 8) -> String {
        heightProfile(cloud.positions, buckets: buckets)
    }

    // MARK: - Thermal

    /// `thermal nominal` … `thermal critical`. ARKit sheds depth frames well
    /// before the user notices heat, so a sweep that went sparse late needs this
    /// to be told apart from one that was captured badly.
    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "thermal nominal"
        case .fair:     return "thermal fair"
        case .serious:  return "thermal serious"
        case .critical: return "thermal critical"
        @unknown default: return "thermal unknown"
        }
    }
}
