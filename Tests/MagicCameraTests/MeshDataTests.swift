//
//  MeshDataTests.swift
//  MagicCameraTests
//
//  Surface-cleanup mesh ops: trimming the frayed long-edge boundary and lifting
//  an object off its detected support plane.
//

import XCTest
import simd
@testable import MagicCamera

final class MeshDataTests: XCTestCase {

    /// A flat triangle grid in the y = `height` plane, `n`×`n` cells.
    private func planeGrid(_ n: Int, height: Float, spacing: Float = 0.05)
        -> (verts: [SIMD3<Float>], idx: [UInt32]) {
        var v: [SIMD3<Float>] = []
        for j in 0...n {
            for i in 0...n { v.append(SIMD3(Float(i) * spacing, height, Float(j) * spacing)) }
        }
        var idx: [UInt32] = []
        let w = n + 1
        for j in 0..<n {
            for i in 0..<n {
                let a = UInt32(j * w + i), b = UInt32(j * w + i + 1)
                let c = UInt32((j + 1) * w + i), d = UInt32((j + 1) * w + i + 1)
                idx.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        return (v, idx)
    }

    func testTrimmingLongEdgesLeavesAUniformMeshUntouched() {
        let grid = planeGrid(8, height: 0)
        let clean = MeshData(vertices: grid.verts, normals: [], indices: grid.idx)
        XCTAssertEqual(clean.trimmingLongEdges().triangleCount, clean.triangleCount)
    }

    func testTrimmingLongEdgesRemovesStragglers() {
        var grid = planeGrid(8, height: 0)
        // One frayed triangle reaching far across the scene — long edges.
        let s = UInt32(grid.verts.count)
        grid.verts.append(SIMD3(9, 9, 9))
        grid.idx.append(contentsOf: [0, 1, s])
        let frayed = MeshData(vertices: grid.verts, normals: [], indices: grid.idx)
        XCTAssertEqual(frayed.trimmingLongEdges().triangleCount, frayed.triangleCount - 1,
                       "the long-edge straggler is trimmed, the body kept")
    }

    func testRemovingBasePlaneKeepsObjectAboveSupport() {
        var grid = planeGrid(16, height: 0)            // dominant flat support
        // A small flat patch floating 15 cm above the plane (the "object").
        let base = UInt32(grid.verts.count)
        for j in 0...2 {
            for i in 0...2 { grid.verts.append(SIMD3(0.2 + Float(i) * 0.03, 0.15, 0.2 + Float(j) * 0.03)) }
        }
        for j in 0..<2 {
            for i in 0..<2 {
                let a = base + UInt32(j * 3 + i), b = a + 1
                let c = base + UInt32((j + 1) * 3 + i), d = c + 1
                grid.idx.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        let mesh = MeshData(vertices: grid.verts, normals: [], indices: grid.idx)
        let lifted = mesh.removingBasePlane()
        XCTAssertLessThan(lifted.triangleCount, mesh.triangleCount, "the support plane is removed")
        XCTAssertGreaterThan(lifted.triangleCount, 0, "the object survives")
        XCTAssertTrue(lifted.vertices.allSatisfy { $0.y > 0.02 },
                      "only geometry above the support remains")
    }
}
