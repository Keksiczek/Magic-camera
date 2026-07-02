//
//  AdaptiveSurfaceReconstructorTests.swift
//  MagicCameraTests
//
//  Verifies the variable-resolution reconstruction wrapper (octree + nearest-point
//  field + adaptive mesher) produces a surface that hugs the scanned geometry — a
//  one-sided plane (façade) and a closed sphere.
//

import XCTest
import Foundation
import simd
@testable import MagicCamera

final class AdaptiveSurfaceReconstructorTests: XCTestCase {

    func testReconstructsAPlaneNearItsSurface() {
        // A 1×1 m wall of points at z = 0, normals facing +z (a one-sided façade).
        var cloud = PointCloud()
        var normals: [SIMD3<Float>] = []
        let n = 60
        for i in 0...n { for j in 0...n {
            let x = Float(i) / Float(n), y = Float(j) / Float(n)
            cloud.append(position: SIMD3(x, y, 0), color: SIMD3(repeating: 0.5), confidence: 1)
            normals.append(SIMD3(0, 0, 1))
        }}
        guard let result = AdaptiveSurfaceReconstructor.reconstruct(cloud, normals: normals) else {
            return XCTFail("reconstruction returned nil for a dense plane")
        }
        XCTAssertGreaterThan(result.mesh.triangleCount, 0)
        // Every reconstructed vertex hugs the z = 0 plane (within a cell or two).
        let maxZ = result.mesh.vertices.map { abs($0.z) }.max() ?? .greatestFiniteMagnitude
        XCTAssertLessThan(maxZ, 0.1, "surface should hug the scanned plane")
    }

    func testReconstructsASphereShell() {
        // Sphere of radius 0.3 m, outward normals.
        var cloud = PointCloud()
        var normals: [SIMD3<Float>] = []
        let rings = 44, sectors = 44, r: Float = 0.3
        for i in 0...rings { for j in 0...sectors {
            let phi = Float.pi * Float(i) / Float(rings)
            let th = 2 * Float.pi * Float(j) / Float(sectors)
            let nrm = SIMD3<Float>(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
            cloud.append(position: nrm * r, color: SIMD3(repeating: 0.5), confidence: 1)
            normals.append(nrm)
        }}
        guard let result = AdaptiveSurfaceReconstructor.reconstruct(cloud, normals: normals) else {
            return XCTFail("reconstruction returned nil for a dense sphere")
        }
        XCTAssertGreaterThan(result.mesh.triangleCount, 0)
        // Most vertices sit on the sphere shell (allow a cell of slack).
        let within = result.mesh.vertices.filter { abs(simd_length($0) - r) < 0.06 }.count
        XCTAssertGreaterThan(Float(within) / Float(max(result.mesh.vertices.count, 1)), 0.8,
                             "most vertices should sit on the sphere shell")
    }
}

final class AdaptiveMesherStitchTests: XCTestCase {
    private func hasEdge(_ mesh: MeshData, _ a: UInt32, _ b: UInt32) -> Bool {
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = [mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2]]
            if tri.contains(a), tri.contains(b) { return true }
            t += 3
        }
        return false
    }

    func testStitchesACoarseFineTJunction() {
        // A coarse triangle (A,B,C) whose edge A–B is bisected by M, with fine
        // triangles below that use M — the classic level-boundary T-junction.
        let verts: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(1, 2, 0),   // A B C
            SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(2, -1, 0)  // M D E
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 3, 4, 3, 1, 5]
        let mesh = MeshData(vertices: verts, normals: [], indices: indices)
        let stitched = AdaptiveMesher.stitchTJunctions(mesh, quantum: 1.0)
        XCTAssertEqual(stitched.triangleCount, 4, "the coarse triangle should split at M")
        XCTAssertTrue(hasEdge(stitched, 3, 2), "M should now share a triangle with C (crack welded)")
    }

    func testLeavesACleanMeshUnchanged() {
        // Two triangles sharing a proper interior edge, no mid-edge vertex.
        let verts: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let mesh = MeshData(vertices: verts, normals: [], indices: indices)
        XCTAssertEqual(AdaptiveMesher.stitchTJunctions(mesh, quantum: 1.0).triangleCount, 2)
    }
}
