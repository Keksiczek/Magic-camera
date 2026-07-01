//
//  MeshPlanarRegularizerTests.swift
//  MagicCameraTests
//
//  Verifies the planar regulariser flattens the walls of a scan while leaving
//  organic shapes alone, and that its tolerance scales with the scan's size so a
//  large outdoor building flattens as well as a small room (the "faceted walls on
//  a big scan" fix: only 1–2 planes were caught before).
//

import XCTest
import Foundation
import simd
@testable import MagicCamera

final class MeshPlanarRegularizerTests: XCTestCase {

    // MARK: - Builders

    /// A `cells`×`cells` triangulated grid on the plane spanned by `u`, `v` at
    /// `origin`, jittered along its normal by up to ±`noise` (a noisy LiDAR wall).
    /// Every vertex carries the true plane normal — as a denoised mesh would.
    private func planePatch(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>,
                            cells: Int, noise: Float, base: UInt32,
                            rng: inout SeededGenerator)
        -> (verts: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        let normal = simd_normalize(simd_cross(u, v))
        var verts: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for i in 0...cells { for j in 0...cells {
            let s = Float(i) / Float(cells), t = Float(j) / Float(cells)
            let jitter = (Float(rng.next(upTo: 2001)) / 1000 - 1) * noise
            verts.append(origin + u * s + v * t + normal * jitter)
            normals.append(normal)
        }}
        let stride = cells + 1
        var idx: [UInt32] = []
        for i in 0..<cells { for j in 0..<cells {
            let a = UInt32(i * stride + j) + base, b = a + 1
            let c = UInt32((i + 1) * stride + j) + base, d = c + 1
            idx.append(contentsOf: [a, c, b, b, c, d])
        }}
        return (verts, normals, idx)
    }

    /// A UV sphere — an organic shape with no large flat region.
    private func sphere(radius: Float, rings: Int, sectors: Int)
        -> (verts: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        var verts: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for i in 0...rings { for j in 0...sectors {
            let phi = Float.pi * Float(i) / Float(rings)
            let theta = 2 * Float.pi * Float(j) / Float(sectors)
            let n = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
            verts.append(n * radius)
            normals.append(n)
        }}
        let stride = sectors + 1
        var idx: [UInt32] = []
        for i in 0..<rings { for j in 0..<sectors {
            let a = UInt32(i * stride + j), b = a + 1
            let c = UInt32((i + 1) * stride + j), d = c + 1
            idx.append(contentsOf: [a, c, b, b, c, d])
        }}
        return (verts, normals, idx)
    }

    // MARK: - Tests

    func testAdaptiveToleranceScalesWithScanSize() {
        // Room-scale (~3 m diagonal) → the tight 2.5 cm floor.
        let room: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(2, 2, 1)]
        XCTAssertEqual(MeshPlanarRegularizer.adaptiveTolerance(room), 0.025, accuracy: 1e-4)

        // Building-scale (~19 m diagonal) → relaxes above the floor, below the cap.
        let building: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(15, 3.5, 11)]
        let tol = MeshPlanarRegularizer.adaptiveTolerance(building)
        XCTAssertGreaterThan(tol, 0.03, "a big scan must relax past the room floor")
        XCTAssertLessThanOrEqual(tol, 0.09)

        // Huge → clamped at the ceiling.
        let huge: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(40, 10, 40)]
        XCTAssertEqual(MeshPlanarRegularizer.adaptiveTolerance(huge), 0.09, accuracy: 1e-4)
    }

    func testRoomWallsFlattenAndSnapFlat() {
        var rng = SeededGenerator(seed: 42)
        // Two perpendicular 2×2 m walls, 1 cm noise (a room corner).
        let w1 = planePatch(origin: SIMD3(0, 0, 0), u: SIMD3(2, 0, 0), v: SIMD3(0, 2, 0),
                            cells: 20, noise: 0.01, base: 0, rng: &rng)          // z ≈ 0 plane
        let w2 = planePatch(origin: SIMD3(0, 0, 0), u: SIMD3(0, 0, 2), v: SIMD3(0, 2, 0),
                            cells: 20, noise: 0.01, base: UInt32(w1.verts.count), rng: &rng) // x ≈ 0 plane
        let mesh = MeshData(vertices: w1.verts + w2.verts,
                            normals: w1.normals + w2.normals,
                            indices: w1.indices + w2.indices)

        let result = MeshPlanarRegularizer.regularize(mesh)
        XCTAssertGreaterThanOrEqual(result.planes, 2, "both walls of the corner should flatten")

        // The first wall's interior vertices (weld is a no-op here, so order is
        // preserved) should be snapped flat: their z collapses from ±1 cm noise to
        // ~one value. The x ≈ 0 column is excluded — it sits on the shared corner
        // edge that the perpendicular wall legitimately claims first.
        let wall1 = result.mesh.vertices.prefix(w1.verts.count).filter { $0.x > 0.1 }.map { $0.z }
        let mean = wall1.reduce(0, +) / Float(wall1.count)
        let maxDev = wall1.map { abs($0 - mean) }.max() ?? 0
        XCTAssertLessThan(maxDev, 0.002, "snapped wall vertices must lie on one plane")
    }

    func testFlattensManyWallsOfABuilding() {
        var rng = SeededGenerator(seed: 7)
        // A building-scale open room: floor + four walls, 2 cm noise. Three-random-
        // point RANSAC seeds only the biggest one or two of these; normal-seeding
        // must recover all of them.
        var verts: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        // Each patch is built with the running vertex count as its index base, so
        // its indices are already global — just append the three arrays.
        func add(_ patch: (verts: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])) {
            verts += patch.verts
            normals += patch.normals
            indices += patch.indices
        }
        let floor = planePatch(origin: SIMD3(0, 0, 0), u: SIMD3(8, 0, 0), v: SIMD3(0, 0, 8),
                               cells: 30, noise: 0.02, base: UInt32(verts.count), rng: &rng)
        add(floor)
        let wxPlus = planePatch(origin: SIMD3(8, 0, 0), u: SIMD3(0, 3, 0), v: SIMD3(0, 0, 8),
                                cells: 16, noise: 0.02, base: UInt32(verts.count), rng: &rng)
        add(wxPlus)
        let wxMinus = planePatch(origin: SIMD3(0, 0, 0), u: SIMD3(0, 3, 0), v: SIMD3(0, 0, 8),
                                 cells: 16, noise: 0.02, base: UInt32(verts.count), rng: &rng)
        add(wxMinus)
        let wzPlus = planePatch(origin: SIMD3(0, 0, 8), u: SIMD3(0, 3, 0), v: SIMD3(8, 0, 0),
                                cells: 16, noise: 0.02, base: UInt32(verts.count), rng: &rng)
        add(wzPlus)
        let wzMinus = planePatch(origin: SIMD3(0, 0, 0), u: SIMD3(0, 3, 0), v: SIMD3(8, 0, 0),
                                 cells: 16, noise: 0.02, base: UInt32(verts.count), rng: &rng)
        add(wzMinus)

        let mesh = MeshData(vertices: verts, normals: normals, indices: indices)
        let result = MeshPlanarRegularizer.regularize(mesh)
        XCTAssertGreaterThanOrEqual(result.planes, 4,
            "a building's floor and walls should nearly all flatten, not just 1–2")
        XCTAssertGreaterThan(result.tolerance, 0.03, "building-scale scan should relax the tolerance")
    }

    func testOrganicSphereIsNoOp() {
        let s = sphere(radius: 0.5, rings: 24, sectors: 24)
        let mesh = MeshData(vertices: s.verts, normals: s.normals, indices: s.indices)
        let result = MeshPlanarRegularizer.regularize(mesh)
        XCTAssertEqual(result.planes, 0, "a sphere has no large flat region to snap")
        XCTAssertEqual(result.mesh.vertices.count, mesh.vertices.count)
    }
}
