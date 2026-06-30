//
//  MeshHoleFillerTests.swift
//  MagicCameraTests
//
//  Verifies boundary-hole capping: an open fan's rim gets closed, oversized
//  loops are left open, and already-closed meshes are untouched.
//
import XCTest
import simd
@testable import MagicCamera

final class MeshHoleFillerTests: XCTestCase {

    /// A hexagon fan: a central vertex + 6 rim vertices, 6 triangles. Its only
    /// boundary is the 6-edge rim loop.
    private func hexFan() -> MeshData {
        var vertices = [SIMD3<Float>(0, 0, 0)]   // centre = index 0
        for k in 0..<6 {
            let a = Float(k) / 6 * 2 * .pi
            vertices.append(SIMD3<Float>(cos(a), 0, sin(a)))
        }
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: vertices.count)
        var indices: [UInt32] = []
        for k in 0..<6 {
            let a = UInt32(k + 1)
            let b = UInt32((k + 1) % 6 + 1)
            indices.append(contentsOf: [0, a, b])
        }
        return MeshData(vertices: vertices, normals: normals, indices: indices)
    }

    /// A closed tetrahedron — no boundary edges.
    private func tetrahedron() -> MeshData {
        let v = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                 SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        let idx: [UInt32] = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
        let n = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: 4)
        return MeshData(vertices: v, normals: n, indices: idx)
    }

    private func boundaryHalfEdgeCount(_ mesh: MeshData) -> Int {
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { (UInt64(a) << 32) | UInt64(b) }
        var directed = Set<UInt64>()
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
            directed.insert(key(a, b)); directed.insert(key(b, c)); directed.insert(key(c, a))
            i += 3
        }
        var count = 0
        for e in directed {
            let a = UInt32(e >> 32), b = UInt32(e & 0xFFFF_FFFF)
            if !directed.contains(key(b, a)) { count += 1 }
        }
        return count
    }

    func testFillsOpenRim() {
        let fan = hexFan()
        XCTAssertEqual(boundaryHalfEdgeCount(fan), 6)   // the open rim

        let filled = MeshHoleFiller.fill(fan, maxHoleEdges: 10)
        // The rim is a convex planar hexagon, so it ear-clips in-plane: n−2 = 4
        // cap triangles reusing the existing rim vertices, no centroid added.
        XCTAssertEqual(filled.triangleCount, 10)         // 6 original + 4 ear-clip caps
        XCTAssertEqual(boundaryHalfEdgeCount(filled), 0) // now watertight
        XCTAssertEqual(filled.vertices.count, fan.vertices.count) // no new centroid vertex
        XCTAssertEqual(filled.normals.count, filled.vertices.count)
    }

    func testLeavesLoopsLargerThanMaxOpen() {
        let fan = hexFan()
        let result = MeshHoleFiller.fill(fan, maxHoleEdges: 4)   // 6 > 4 → skipped
        XCTAssertEqual(result.triangleCount, fan.triangleCount)
        XCTAssertEqual(boundaryHalfEdgeCount(result), 6)
    }

    func testClosedMeshUnchanged() {
        let tet = tetrahedron()
        XCTAssertEqual(boundaryHalfEdgeCount(tet), 0)
        let result = MeshHoleFiller.fill(tet)
        XCTAssertEqual(result.triangleCount, tet.triangleCount)
        XCTAssertEqual(result.vertices.count, tet.vertices.count)
    }
}
