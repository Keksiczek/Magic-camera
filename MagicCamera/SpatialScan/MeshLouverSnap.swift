//
//  MeshLouverSnap.swift
//  Magic Camera
//
//  Regularises a PERIODIC STACK OF THIN SLATS — venetian blinds, shutters,
//  radiator fins, fence pickets, a louvred vent, a comb of ribs — the one common
//  family that neither the planar regulariser (each slat is a plane, but their
//  spacing is the point) nor the surface-of-revolution snapper covers. A LiDAR
//  reconstruction of a blind comes out with uneven, wavy slat spacing; this finds
//  the repeat and snaps every slat back onto an even grid, so the stack reads as
//  the manufactured, regular object it is.
//
//  Detection is 1-D and deliberately narrow, so it can't be confused with the
//  other pattern families (revolution decoration, a plain wall's own lattice
//  ripple). Along a candidate axis, the vertices' projected DENSITY of a slat
//  stack is periodic with DEEP gaps between slats; a plain continuous surface has
//  no gaps and is rejected outright. The period is found by autocorrelation, then
//  refined to sub-bin precision by a linear fit of the detected slat-centre
//  positions against their index (`centre = t0 + k·period`); a stack only counts
//  when it has ≥ `minSlats` evenly-spaced repeats. Regularisation shifts each slat
//  rigidly ALONG the axis onto its ideal grid line — even spacing, every slat's
//  own shape and thickness untouched — clamped so a mis-detection can only nudge.
//
//  Pure value math, ARKit-free, off-main, deterministic.
//

import simd

enum MeshLouverSnap {

    struct Stack {
        var axis: SIMD3<Float>   // unit, the stacking direction
        var t0: Float            // first slat centre (projected onto axis)
        var period: Float
        var count: Int
        var strength: Float      // autocorrelation peak, 0…1
    }

    struct Stats {
        var slats = 0
        var moved = 0
        var total = 0
        var period: Float = 0
        var summary: String {
            "louver — \(slats) slats · period \(String(format: "%.1f", period * 100))cm"
                + " · moved \(moved)/\(total)"
        }
    }

    /// Min distance a slat may be shifted onto the grid — smaller than the round
    /// snappers' 3 cm, since this only corrects spacing, and a bad detection must
    /// stay a nudge.
    private static let maxShift: Float = 0.02
    private static let minPeriod: Float = 0.01     // 1 cm slats
    private static let maxPeriod: Float = 0.30
    private static let minSlats = 5                // a real stack, not a coincidence of 2–3
    private static let minStrength: Float = 0.40   // autocorrelation must be strong
    private static let maxTroughRatio: Float = 0.40 // gaps must be deep (rejects a wall)

    /// Detects the dominant periodic slat stack (if any) and evens its spacing.
    /// Returns the mesh unchanged when no stack is found.
    static func snap(_ input: MeshData,
                     up: SIMD3<Float> = SIMD3(0, 1, 0)) -> (mesh: MeshData, stats: Stats) {
        var stats = Stats()
        let mesh = input.weldingDuplicateVertices()
        let n = mesh.vertices.count
        stats.total = n
        guard n >= 600 else { return (input, stats) }

        // World axes (a blind stacks vertically, fins horizontally) plus world-up
        // in case gravity isn't axis-aligned; the strongest passing stack wins.
        var axes = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        if abs(up.y) < 0.99 { axes.append(simd_normalize(up)) }
        var best: Stack?
        for axis in axes {
            guard let s = detectStack(mesh.vertices, axis: axis) else { continue }
            if best == nil || s.strength > best!.strength { best = s }
        }
        guard let stack = best else { return (input, stats) }

        var verts = mesh.vertices
        let moved = regularise(&verts, stack)
        guard moved > 0 else { return (input, stats) }
        stats.slats = stack.count; stats.moved = moved; stats.period = stack.period

        var out = mesh
        out.vertices = verts
        out.normals = recomputeNormals(vertices: verts, indices: mesh.indices)
        return (out, stats)
    }

    // MARK: - Detection

    static func detectStack(_ verts: [SIMD3<Float>], axis: SIMD3<Float>) -> Stack? {
        let bin: Float = 0.002
        let (d, tmin) = density(verts, axis: axis, bin: bin)
        let n = d.count
        guard n >= 8 else { return nil }
        let mean = d.reduce(0, +) / Float(n)
        guard mean > 0 else { return nil }
        let dc = d.map { $0 - mean }
        let energy = dc.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }

        // Autocorrelation → rough period (the lag of the strongest repeat).
        let loLag = max(2, Int(minPeriod / bin)), hiLag = min(n / minSlats, Int(maxPeriod / bin))
        guard hiLag > loLag else { return nil }
        var bestLag = 0, bestCorr: Float = 0
        for lag in loLag...hiLag {
            var c: Float = 0
            for i in 0..<(n - lag) { c += dc[i] * dc[i + lag] }
            let norm = c / energy
            if norm > bestCorr { bestCorr = norm; bestLag = lag }
        }
        guard bestLag > 0, bestCorr > minStrength else { return nil }
        let roughPeriod = Float(bestLag) * bin

        // Deep-gap gate: at the best comb phase the teeth must stand well above the
        // mid-gaps. A continuous surface (a wall) has no gaps and dies here.
        var bestPhase = 0, bestSum: Float = -1
        for phase in 0..<bestLag {
            var s: Float = 0, k = phase
            while k < n { s += d[k]; k += bestLag }
            if s > bestSum { bestSum = s; bestPhase = phase }
        }
        var peakSum: Float = 0, troughSum: Float = 0, teeth = 0, kk = bestPhase
        while kk < n {
            peakSum += d[kk]
            let mid = kk + bestLag / 2
            if mid < n { troughSum += d[mid] }
            teeth += 1; kk += bestLag
        }
        guard teeth >= minSlats, peakSum > 0,
              troughSum / Float(teeth) < maxTroughRatio * (peakSum / Float(teeth)) else { return nil }

        // Precise period: detect the density peaks, then fit centre = t0 + k·period.
        let thresh = 0.4 * (d.max() ?? 0), minSep = max(1, Int(roughPeriod * 0.5 / bin))
        var peaks: [Float] = []
        for i in 0..<n where d[i] > thresh && (i == 0 || d[i] >= d[i - 1]) && (i == n - 1 || d[i] >= d[i + 1]) {
            let t = tmin + Float(i) * bin + bin * 0.5
            if let last = peaks.last, (t - last) < Float(minSep) * bin {
                if d[i] > d[min(n - 1, max(0, Int((last - tmin) / bin)))] { peaks[peaks.count - 1] = t }
            } else {
                peaks.append(t)
            }
        }
        guard peaks.count >= minSlats else { return nil }
        var ks: [Float] = [0]
        for m in 1..<peaks.count { ks.append(ks[m - 1] + ((peaks[m] - peaks[m - 1]) / roughPeriod).rounded()) }
        guard let (period, t0) = linearFit(ks, peaks), period >= minPeriod, period <= maxPeriod else { return nil }
        // Even-ness: every detected centre must sit near its ideal grid line.
        var maxRes: Float = 0
        for m in 0..<peaks.count { maxRes = max(maxRes, abs(peaks[m] - (t0 + ks[m] * period))) }
        guard maxRes < 0.3 * period else { return nil }
        let count = Int(ks.last!) + 1
        guard count >= minSlats else { return nil }
        return Stack(axis: axis, t0: t0, period: period, count: count, strength: bestCorr)
    }

    private static func density(_ verts: [SIMD3<Float>], axis: SIMD3<Float>,
                                bin: Float) -> (d: [Float], tmin: Float) {
        var tmin = Float.greatestFiniteMagnitude, tmax = -Float.greatestFiniteMagnitude
        for v in verts { let t = simd_dot(v, axis); tmin = min(tmin, t); tmax = max(tmax, t) }
        let n = max(1, Int((tmax - tmin) / bin) + 1)
        var d = [Float](repeating: 0, count: n)
        for v in verts { d[min(n - 1, max(0, Int((simd_dot(v, axis) - tmin) / bin)))] += 1 }
        return (d, tmin)
    }

    private static func linearFit(_ xs: [Float], _ ys: [Float]) -> (slope: Float, intercept: Float)? {
        let count = Float(xs.count)
        guard count >= 2 else { return nil }
        var sx: Float = 0, sy: Float = 0, sxx: Float = 0, sxy: Float = 0
        for i in 0..<xs.count { sx += xs[i]; sy += ys[i]; sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i] }
        let denom = count * sxx - sx * sx
        guard abs(denom) > 1e-9 else { return nil }
        let slope = (count * sxy - sx * sy) / denom
        return (slope, (sy - slope * sx) / count)
    }

    // MARK: - Regularise

    /// Rigidly shifts each slat onto its ideal grid line along the axis; clamped.
    private static func regularise(_ verts: inout [SIMD3<Float>], _ s: Stack) -> Int {
        let slots = s.count + 2
        var sumT = [Float](repeating: 0, count: slots), cnt = [Int](repeating: 0, count: slots)
        var slatOf = [Int](repeating: -1, count: verts.count)
        for i in 0..<verts.count {
            let k = Int(((simd_dot(verts[i], s.axis) - s.t0) / s.period).rounded())
            guard k >= 0, k < slots else { continue }
            slatOf[i] = k; sumT[k] += simd_dot(verts[i], s.axis); cnt[k] += 1
        }
        var actual = [Float](repeating: .nan, count: slots)
        for k in 0..<slots where cnt[k] > 0 { actual[k] = sumT[k] / Float(cnt[k]) }
        var moved = 0
        for i in 0..<verts.count {
            let k = slatOf[i]
            guard k >= 0, !actual[k].isNaN else { continue }
            let shift = max(-maxShift, min(maxShift, (s.t0 + Float(k) * s.period) - actual[k]))
            if abs(shift) > 1e-5 { verts[i] += s.axis * shift; moved += 1 }
        }
        return moved
    }

    private static func recomputeNormals(vertices: [SIMD3<Float>],
                                         indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let f = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            normals[a] += f; normals[b] += f; normals[c] += f
            i += 3
        }
        for v in 0..<normals.count {
            let l = simd_length(normals[v])
            normals[v] = l > 1e-6 ? normals[v] / l : SIMD3<Float>(0, 1, 0)
        }
        return normals
    }
}
