//
//  MeshLouverSnapTests.swift
//  MagicCameraTests
//
//  Verifies the periodic slat-stack regulariser evens the spacing of a blind /
//  louvre / fin stack, recovers the period, and — critically — does NOT mistake a
//  plain continuous wall for a slat stack (a wall's own lattice ripple must not
//  trigger it). Mirrors the scratchpad harness.
//

import XCTest
import Foundation
import simd
@testable import MagicCamera

final class MeshLouverSnapTests: XCTestCase {

    /// A stack of `slats` thin horizontal patches along y, centres at
    /// `k·period + jitter` (uneven, as a reconstruction leaves them).
    private func slatStack(slats: Int, period: Float, jitter: Float, seed: UInt64)
        -> (verts: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        var rng = SeededGenerator(seed: seed)
        var v: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], idx: [UInt32] = []
        let side = 12
        for k in 0..<slats {
            let base = UInt32(v.count)
            let yc = Float(k) * period + (Float(rng.next(upTo: 2001)) / 1000 - 1) * jitter
            for a in 0..<side { for b in 0..<side {
                let jy = (Float(rng.next(upTo: 2001)) / 1000 - 1) * 0.002
                v.append(SIMD3(Float(a) / Float(side - 1) * 0.4 - 0.2, yc + jy,
                               Float(b) / Float(side - 1) * 0.15))
                n.append(SIMD3(0, 1, 0))
            }}
            for a in 0..<(side - 1) { for b in 0..<(side - 1) {
                let p = base + UInt32(a * side + b)
                idx.append(contentsOf: [p, p + UInt32(side), p + 1, p + 1, p + UInt32(side), p + UInt32(side) + 1])
            }}
        }
        return (v, n, idx)
    }

    func testSlatStackEvensSpacing() {
        let period: Float = 0.03
        let s = slatStack(slats: 8, period: period, jitter: 0.003, seed: 3)
        let mesh = MeshData(vertices: s.verts, normals: s.normals, indices: s.indices)
        let r = MeshLouverSnap.snap(mesh)
        XCTAssertGreaterThanOrEqual(r.stats.slats, 7, "the stack is recognised")
        XCTAssertEqual(r.stats.period, period, accuracy: 0.004)
        XCTAssertGreaterThan(r.stats.moved, mesh.vertices.count / 2)

        // Slat centres are now evenly spaced.
        var sum = [Float](repeating: 0, count: 8), cnt = [Int](repeating: 0, count: 8)
        for p in r.mesh.vertices {
            let k = Int((p.y / period).rounded())
            if k >= 0, k < 8 { sum[k] += p.y; cnt[k] += 1 }
        }
        var centres: [Float] = []
        for k in 0..<8 where cnt[k] > 0 { centres.append(sum[k] / Float(cnt[k])) }
        var spacing: [Float] = []
        for k in 1..<centres.count { spacing.append(centres[k] - centres[k - 1]) }
        let mean = spacing.reduce(0, +) / Float(spacing.count)
        let maxDev = spacing.map { abs($0 - mean) }.max() ?? 0
        XCTAssertLessThan(maxDev, 0.002, "slat spacing is evened")
    }

    func testPlainWallIsNotALouver() {
        var rng = SeededGenerator(seed: 9)
        var v: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], idx: [UInt32] = []
        let side = 60
        for a in 0..<side { for b in 0..<side {
            let jz = (Float(rng.next(upTo: 2001)) / 1000 - 1) * 0.006
            v.append(SIMD3(Float(a) / Float(side - 1) * 1.2, Float(b) / Float(side - 1) * 1.2, jz))
            n.append(SIMD3(0, 0, 1))
        }}
        for a in 0..<(side - 1) { for b in 0..<(side - 1) {
            let p = UInt32(a * side + b)
            idx.append(contentsOf: [p, p + UInt32(side), p + 1, p + 1, p + UInt32(side), p + UInt32(side) + 1])
        }}
        let mesh = MeshData(vertices: v, normals: n, indices: idx)
        let r = MeshLouverSnap.snap(mesh)
        XCTAssertEqual(r.stats.moved, 0, "a continuous wall must not be regularised as slats")
        XCTAssertEqual(r.mesh.vertices, mesh.vertices)
    }
}
