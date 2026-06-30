//
//  MeshBasePlaneTests.swift
//  MagicCameraTests
//
//  Verifies MeshData.removingBasePlane strips a flat support surface and keeps
//  the object standing on it, and leaves a plain flat mesh (no object) alone.
//

import XCTest
import simd
@testable import MagicCamera

final class MeshBasePlaneTests: XCTestCase {

    /// A flat n×n grid of triangles in the y = 0 plane (the "table").
    private func flatGrid(_ n: Int, spacing: Float) -> ([SIMD3<Float>], [UInt32]) {
        var verts: [SIMD3<Float>] = []
        for z in 0...n { for x in 0...n {
            verts.append(SIMD3<Float>(Float(x) * spacing, 0, Float(z) * spacing))
        }}
        let stride = n + 1
        var idx: [UInt32] = []
        for z in 0..<n { for x in 0..<n {
            let a = UInt32(z * stride + x), b = a + 1
            let c = UInt32((z + 1) * stride + x), d = c + 1
            idx.append(contentsOf: [a, c, b, b, c, d])
        }}
        return (verts, idx)
    }

    /// 12 triangles of an axis-aligned box between `lo` and `hi`.
    private func box(lo: SIMD3<Float>, hi: SIMD3<Float>, base: UInt32) -> ([SIMD3<Float>], [UInt32]) {
        let v = [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(lo.x, lo.y, hi.z),
            SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z),
        ]
        let f: [UInt32] = [0,1,2, 0,2,3, 4,6,5, 4,7,6, 0,4,5, 0,5,1,
                           1,5,6, 1,6,2, 2,6,7, 2,7,3, 3,7,4, 3,4,0]
        return (v, f.map { $0 + base })
    }

    func testRemovesFlatSupportKeepsObject() {
        // 8×8 table (≥50 verts so RANSAC engages) + a box standing on it.
        let (gv, gi) = flatGrid(8, spacing: 0.04)
        let (bv, bi) = box(lo: SIMD3(0.1, 0.1, 0.1), hi: SIMD3(0.2, 0.3, 0.2), base: UInt32(gv.count))
        let mesh = MeshData(vertices: gv + bv,
                            normals: [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: gv.count + bv.count),
                            indices: gi + bi)

        let lifted = mesh.removingBasePlane()
        XCTAssertLessThan(lifted.triangleCount, mesh.triangleCount, "the flat table triangles should be removed")
        XCTAssertGreaterThan(lifted.triangleCount, 0, "the box should survive")
        // Everything left stands above the (removed) y = 0 support.
        for v in lifted.vertices {
            XCTAssertGreaterThan(v.y, 0.05, "no support-plane geometry should remain")
        }
    }

    func testLeavesAPlainFlatMeshAlone() {
        // A bare table with nothing on it — there's no object to keep, so removing
        // the plane would gut it; the guard must return the mesh unchanged.
        let (gv, gi) = flatGrid(8, spacing: 0.04)
        let mesh = MeshData(vertices: gv,
                            normals: [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: gv.count),
                            indices: gi)
        XCTAssertEqual(mesh.removingBasePlane().triangleCount, mesh.triangleCount)
    }
}
