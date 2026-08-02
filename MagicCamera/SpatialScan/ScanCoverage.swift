//
//  ScanCoverage.swift
//  Magic Camera
//
//  How much of a subject a scan has actually seen: saturation from the rate new
//  points arrive, azimuth/elevation coverage for an orbit, and the silhouette a
//  targeted capture is masked against. Pure value types — no ARKit state — so
//  the coaching logic is unit-testable away from a live session.
//

import ARKit
import simd

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

