//
//  PointCloudBilateralDenoiserTests.swift
//  MagicCameraTests
//
//  Verifies the bilateral denoiser's two promises — the ~1 cm noise band averages
//  flat while a real step edge above the range sigma survives — plus the CSR/radix
//  neighbourhood machinery it stands on (the fast path for -Onone device builds).
//

import XCTest
import Foundation
import simd
@testable import MagicCamera

final class PointCloudBilateralDenoiserTests: XCTestCase {

    /// Deterministic jitter in [-1, 1].
    private func jitter(_ state: inout UInt64) -> Float {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z % 2000) / 1000 - 1
    }

    /// A y-up plane grid split into two halves, the right half raised by `step`,
    /// with ±`noise` jitter along y. Returns positions, normals, and which half.
    private func steppedPlane(side: Int, spacing: Float, noise: Float, step: Float)
        -> (pos: [SIMD3<Float>], nrm: [SIMD3<Float>], isRight: [Bool]) {
        var state: UInt64 = 7
        var pos: [SIMD3<Float>] = []
        var nrm: [SIMD3<Float>] = []
        var isRight: [Bool] = []
        for ix in 0..<side {
            for iz in 0..<side {
                let x = Float(ix) * spacing
                let right = ix >= side / 2
                let y = (right ? step : 0) + jitter(&state) * noise
                pos.append(SIMD3<Float>(x, y, Float(iz) * spacing))
                nrm.append(SIMD3<Float>(0, 1, 0))
                isRight.append(right)
            }
        }
        return (pos, nrm, isRight)
    }

    private func yStd(_ pts: [SIMD3<Float>], where keep: (Int) -> Bool) -> Float {
        var sum: Float = 0, sum2: Float = 0, count: Float = 0
        for (i, p) in pts.enumerated() where keep(i) {
            sum += p.y; sum2 += p.y * p.y; count += 1
        }
        let mean = sum / count
        return max((sum2 / count) - mean * mean, 0).squareRoot()
    }

    func testFlattensNoiseButKeepsStepEdge() {
        // 12 mm spacing with ±10 mm noise, a 50 mm step — the room-scan shape.
        let (pos, nrm, isRight) = steppedPlane(side: 60, spacing: 0.012,
                                               noise: 0.010, step: 0.05)
        let out = PointCloudBilateralDenoiser.denoise(
            pos, normals: nrm, spatialSigma: 0.03, rangeSigma: 0.012, iterations: 1)

        XCTAssertEqual(out.count, pos.count)
        let noiseBefore = yStd(pos) { !isRight[$0] }
        let noiseAfter = yStd(out) { !isRight[$0] }
        XCTAssertLessThan(noiseAfter, noiseBefore * 0.5,
                          "the noise band should average out substantially")

        // Edge preserved: the two halves keep their 50 mm separation instead of
        // blurring toward the 25 mm mean.
        var leftSum: Float = 0, leftN: Float = 0, rightSum: Float = 0, rightN: Float = 0
        for (i, p) in out.enumerated() {
            if isRight[i] { rightSum += p.y; rightN += 1 } else { leftSum += p.y; leftN += 1 }
        }
        let separation = rightSum / rightN - leftSum / leftN
        XCTAssertGreaterThan(separation, 0.04, "the step must survive the smoothing")
    }

    func testNoOpOnMismatchedOrEmptyInput() {
        let pos = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)]
        let oneNormal = [SIMD3<Float>(0, 1, 0)]
        XCTAssertEqual(PointCloudBilateralDenoiser.denoise(
            pos, normals: oneNormal, spatialSigma: 0.03, rangeSigma: 0.012), pos)
        XCTAssertEqual(PointCloudBilateralDenoiser.denoise(
            [], normals: [], spatialSigma: 0.03, rangeSigma: 0.012), [])
        XCTAssertEqual(PointCloudBilateralDenoiser.denoise(
            pos, normals: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)],
            spatialSigma: 0, rangeSigma: 0.012), pos)
    }

    func testRadixSortedOrderMatchesComparatorSort() {
        var state: UInt64 = 99
        var keys: [Int64] = []
        for _ in 0..<10_000 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            // duplicates on purpose: many points share a cell (keys are
            // non-negative by construction, matching the packed cell keys)
            keys.append(Int64(bitPattern: z >> 12) & 0x1FF)
        }
        let radix = PointCloudBilateralDenoiser.radixSortedOrder(keys: keys)
        let sorted = radix.map { keys[Int($0)] }
        XCTAssertEqual(sorted, sorted.sorted(), "radix order must be non-decreasing")
        XCTAssertEqual(Set(radix).count, keys.count, "every index exactly once")
    }
}
