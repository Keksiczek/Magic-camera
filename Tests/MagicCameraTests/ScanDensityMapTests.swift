//
//  ScanDensityMapTests.swift
//  MagicCameraTests
//
//  The live "scan more here" flags: an under-sampled wall region lights up, a
//  voxel-full one doesn't, the scan frontier is never painted, and a subsample
//  too thin to judge yields no hints at all.
//

import XCTest
import simd
@testable import MagicCamera

final class ScanDensityMapTests: XCTestCase {

    /// A 4×3 m wall in the XY plane: left half sampled at `dense` spacing,
    /// right half at `sparse` spacing. Returns positions plus a which-half flag.
    private func wall(dense: Float, sparse: Float) -> (pos: [SIMD3<Float>], isSparse: [Bool]) {
        var pos: [SIMD3<Float>] = []
        var half: [Bool] = []
        func fill(x0: Float, x1: Float, spacing: Float, sparseHalf: Bool) {
            var x = x0
            while x < x1 {
                var y: Float = 0
                while y < 3 {
                    pos.append(SIMD3<Float>(x, y, 0))
                    half.append(sparseHalf)
                    y += spacing
                }
                x += spacing
            }
        }
        fill(x0: 0, x1: 2, spacing: dense, sparseHalf: false)
        fill(x0: 2, x1: 4, spacing: sparse, sparseHalf: true)
        return (pos, half)
    }

    func testFlagsSparseHalfNotDenseHalf() throws {
        // 12 mm voxel-full left, 36 mm (1/9 density) right — well under the 0.35
        // sparse fraction.
        let (pos, isSparse) = wall(dense: 0.012, sparse: 0.036)
        let flags = ScanDensityMap.sparseFlags(positions: pos, voxelSize: 0.012,
                                               sampleRatio: 1)
        let f = try XCTUnwrap(flags)

        var flaggedSparse = 0, totalSparseInterior = 0
        var flaggedDense = 0, totalDense = 0
        for (i, p) in pos.enumerated() {
            // judge away from the wall border and the halves' boundary, where the
            // frontier filter is entitled to stay quiet
            let interior = p.y > 0.4 && p.y < 2.6
            if isSparse[i] {
                if interior && p.x > 2.4 && p.x < 3.6 {
                    totalSparseInterior += 1
                    if f[i] { flaggedSparse += 1 }
                }
            } else if interior && p.x > 0.4 && p.x < 1.6 {
                totalDense += 1
                if f[i] { flaggedDense += 1 }
            }
        }
        XCTAssertGreaterThan(Float(flaggedSparse) / Float(max(totalSparseInterior, 1)), 0.6,
                             "the under-sampled half lights up")
        XCTAssertLessThan(Float(flaggedDense) / Float(max(totalDense, 1)), 0.02,
                          "the voxel-full half stays quiet")
    }

    func testUniformFullDensityYieldsNoHints() {
        let (pos, _) = wall(dense: 0.012, sparse: 0.012)
        let flags = ScanDensityMap.sparseFlags(positions: pos, voxelSize: 0.012,
                                               sampleRatio: 1)
        if let flags {
            XCTAssertLessThan(Float(flags.filter { $0 }.count) / Float(flags.count), 0.02)
        }   // nil (no sparse cells at all) is equally correct
    }

    func testTooThinSubsampleReturnsNil() {
        let (pos, _) = wall(dense: 0.012, sparse: 0.036)
        // expected points per 20 cm cell = 278 × 0.005 ≈ 1.4 < 3 → refuse to judge
        XCTAssertNil(ScanDensityMap.sparseFlags(positions: pos, voxelSize: 0.012,
                                                sampleRatio: 0.005))
    }
}
