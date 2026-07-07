//
//  ReconstructionPipelineTests.swift
//  MagicCameraTests
//
//  Guards the shared cloud→surface spine `ReconstructionPipeline` — the sequence
//  Build Surface and the one-tap model both run. The contract that keeps the two
//  paths correct is that every stage only *removes* points, so the index-aligned
//  view directions (and normals) ride through each subset. These tests exercise
//  that contract on random-sampled clouds (a regular grid doesn't trip the
//  density guards — the r11 lesson) with the real production helpers.
//

import XCTest
import simd
@testable import MagicCamera

final class ReconstructionPipelineTests: XCTestCase {

    /// A random-sampled wall slab with per-point view rays (NOT a regular grid).
    private func randomWall(_ n: Int, seed: UInt64)
        -> (cloud: PointCloud, directions: [SIMD3<Float>]) {
        var s = seed
        func rnd() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float((s >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        var cloud = PointCloud()
        cloud.reserveCapacity(n)
        var directions: [SIMD3<Float>] = []
        directions.reserveCapacity(n)
        for _ in 0..<n {
            let x = rnd() * 3, y = rnd() * 2.5, z = (rnd() - 0.5) * 0.04
            // Confidence spread so ~70 % clears the 0.25 cut (keeps a clear majority).
            let conf = 0.15 + rnd() * 0.85
            cloud.append(position: SIMD3(x, y, z), color: SIMD3(rnd(), rnd(), rnd()), confidence: conf)
            directions.append(simd_normalize(SIMD3<Float>(rnd() - 0.5, rnd() - 0.5, -1)))
        }
        return (cloud, directions)
    }

    // MARK: - Direction-alignment contract

    /// After every stage the view directions must stay index-aligned to the cloud
    /// (same count) and the cloud must only shrink — the whole reason the rays
    /// survive isolation → reconstruction with the robust Fusion orientation.
    func testDirectionsStayAlignedThroughStages() {
        let (cloud, directions) = randomWall(8_000, seed: 42)
        var pipeline = ReconstructionPipeline(cloud: cloud, directions: directions)

        pipeline.dropLowConfidence()
        XCTAssertEqual(pipeline.directions?.count, pipeline.cloud.count)
        XCTAssertLessThan(pipeline.cloud.count, cloud.count)   // low-confidence points dropped

        pipeline.curvaturePrepass(enabled: true)
        XCTAssertEqual(pipeline.directions?.count, pipeline.cloud.count)

        pipeline.removeOutliersAndStrays()
        XCTAssertEqual(pipeline.directions?.count, pipeline.cloud.count)
        XCTAssertGreaterThan(pipeline.cloud.count, 0)
    }

    /// A ray-less cloud (gallery-loaded / hand-edited) must flow through the whole
    /// pipeline with directions staying nil — that's what makes the caller fall
    /// back to estimated normals instead of crashing on a mismatched aux array.
    func testRaylessCloudStaysRayless() {
        let (cloud, _) = randomWall(6_000, seed: 7)
        var pipeline = ReconstructionPipeline(cloud: cloud, directions: nil)
        pipeline.dropLowConfidence()
        pipeline.subsample(resolution: 180)
        pipeline.curvaturePrepass(enabled: true)
        pipeline.removeOutliersAndStrays()
        XCTAssertNil(pipeline.directions)
        XCTAssertGreaterThan(pipeline.cloud.count, 0)
    }

    /// The bilateral denoise (variable-resolution path) rebuilds the cloud with the
    /// same count/order, so the directions stay aligned and the count is unchanged.
    func testBilateralDenoisePreservesAlignmentAndCount() {
        let (cloud, directions) = randomWall(5_000, seed: 11)
        var pipeline = ReconstructionPipeline(cloud: cloud, directions: directions)
        let before = pipeline.cloud.count
        pipeline.bilateralDenoise(enabled: true)
        XCTAssertEqual(pipeline.cloud.count, before)
        XCTAssertEqual(pipeline.directions?.count, pipeline.cloud.count)

        // Disabled → a strict no-op.
        var untouched = ReconstructionPipeline(cloud: cloud, directions: directions)
        untouched.bilateralDenoise(enabled: false)
        XCTAssertEqual(untouched.cloud.positions, cloud.positions)
    }

    /// Supplied normals ride through the confident cut alongside the cloud, then
    /// are invalidated by the outlier pass (the denoised cloud re-estimates its
    /// own) — the exact behaviour Build Surface's `.fusion`/`meshNormals()` relies
    /// on.
    func testSuppliedNormalsCarryThenInvalidate() {
        let (cloud, directions) = randomWall(6_000, seed: 5)
        let normals = directions.map { -$0 }
        var pipeline = ReconstructionPipeline(cloud: cloud, directions: directions, normals: normals)
        pipeline.dropLowConfidence()
        XCTAssertEqual(pipeline.normals?.count, pipeline.cloud.count)
        pipeline.removeOutliersAndStrays()
        XCTAssertNil(pipeline.normals)   // dropped for re-estimation on the denoised cloud
    }

    // MARK: - recoverViewDirections

    /// A pure subset recovers each kept point's original ray by position; a
    /// verbatim pass-through short-circuits to the same array.
    func testRecoverViewDirectionsThroughSubset() {
        let (cloud, directions) = randomWall(4_000, seed: 3)
        // Keep every third point — a genuine positional subset.
        let kept = stride(from: 0, to: cloud.count, by: 3).map { $0 }
        let subset = cloud.subset(kept)
        let recovered = ReconstructionPipeline.recoverViewDirections(
            for: subset, from: cloud, directions: directions)
        XCTAssertEqual(recovered?.count, subset.count)
        for (i, k) in kept.enumerated() {
            XCTAssertEqual(recovered![i], directions[k])
        }
        // Same-count input returns the array verbatim.
        let identity = ReconstructionPipeline.recoverViewDirections(
            for: cloud, from: cloud, directions: directions)
        XCTAssertEqual(identity, directions)
    }

    /// Moved positions break the subset assumption → nil, so the caller estimates
    /// normals instead of applying stale rays.
    func testRecoverViewDirectionsRejectsMovedCloud() {
        let (cloud, directions) = randomWall(3_000, seed: 9)
        var moved = PointCloud()
        moved.reserveCapacity(cloud.count / 2)
        for i in 0..<(cloud.count / 2) {
            moved.append(position: cloud.positions[i] + SIMD3<Float>(10, 10, 10),
                         color: cloud.colors[i], confidence: cloud.confidences[i])
        }
        XCTAssertNil(ReconstructionPipeline.recoverViewDirections(
            for: moved, from: cloud, directions: directions))
    }

    // MARK: - Mesh stages

    /// `assemble` cleans without gutting a solid connected mesh; adaptive vs
    /// non-adaptive both return a non-empty surface.
    func testAssembleKeepsSolidMesh() {
        let mesh = subdividedPlane(cols: 12, rows: 12)
        XCTAssertGreaterThan(ReconstructionPipeline.assemble(mesh, adaptive: false).triangleCount, 0)
        XCTAssertGreaterThan(ReconstructionPipeline.assemble(mesh, adaptive: true).triangleCount, 0)
    }

    /// A flat grid of triangles: one connected component with uniform edges, so
    /// small-component removal and long-edge trimming both keep it.
    private func subdividedPlane(cols: Int, rows: Int) -> MeshData {
        var vertices: [SIMD3<Float>] = []
        for r in 0...rows {
            for c in 0...cols {
                vertices.append(SIMD3<Float>(Float(c) * 0.1, Float(r) * 0.1, 0))
            }
        }
        let stride = cols + 1
        var indices: [UInt32] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let a = UInt32(r * stride + c)
                let b = UInt32(r * stride + c + 1)
                let d = UInt32((r + 1) * stride + c)
                let e = UInt32((r + 1) * stride + c + 1)
                indices.append(contentsOf: [a, b, d, b, e, d])
            }
        }
        return MeshData(vertices: vertices, normals: [], indices: indices)
    }
}
