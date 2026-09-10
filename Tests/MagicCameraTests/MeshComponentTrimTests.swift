//
//  MeshComponentTrimTests.swift
//  Magic Camera
//
//  `MeshData.removingSmallComponents` runs on six paths — every reconstruction,
//  Smart finish, the quick model, the ghost-sheet trim and the ARKit mesh finish —
//  and had no tests at all. It also had no floor guard, unlike the point-cloud
//  filter it mirrors, so a scan holding two subjects of unequal size lost the
//  smaller one with no way to ask for it back. That is the case these pin.
//

import XCTest
import simd
@testable import MagicCamera

final class MeshComponentTrimTests: XCTestCase {

    /// A grid patch of `cells`×`cells` quads (2 triangles each) at `origin`,
    /// disconnected from anything else — its own connected component.
    private func patch(cells: Int, origin: SIMD3<Float>, spacing: Float = 0.05) -> MeshData {
        var mesh = MeshData()
        let row = cells + 1
        for z in 0...cells {
            for x in 0...cells {
                mesh.vertices.append(origin + SIMD3(Float(x) * spacing, 0, Float(z) * spacing))
                mesh.normals.append(SIMD3(0, 1, 0))
            }
        }
        for z in 0..<cells {
            for x in 0..<cells {
                let a = UInt32(z * row + x), b = a + 1
                let c = UInt32((z + 1) * row + x), d = c + 1
                mesh.indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return mesh
    }

    private func combined(_ meshes: [MeshData]) -> MeshData {
        var out = MeshData()
        for mesh in meshes {
            let base = UInt32(out.vertices.count)
            out.vertices.append(contentsOf: mesh.vertices)
            out.normals.append(contentsOf: mesh.normals)
            out.indices.append(contentsOf: mesh.indices.map { $0 + base })
        }
        return out
    }

    // MARK: - What it is for

    /// The job it exists to do: a big subject plus a floating speck.
    func testDropsAFloatingSpeck() {
        let subject = patch(cells: 12, origin: .zero)              // 288 triangles
        let speck = patch(cells: 1, origin: SIMD3(5, 5, 5))        // 2 triangles
        let trimmed = combined([subject, speck]).removingSmallComponents()
        XCTAssertEqual(trimmed.triangleCount, subject.triangleCount)
        // Nothing survives out where the speck was.
        XCTAssertFalse(trimmed.vertices.contains { $0.x > 4 })
    }

    // MARK: - The guard

    /// The regression this is about. Two real subjects, the smaller well under the
    /// 5 % relative bar — dropping it would remove most of the scan, so the filter
    /// must decline entirely rather than choose between them.
    func testDeclinesRatherThanKeepingLessThanHalf() {
        // 4 small patches, each 8 triangles, plus one 18-triangle body: the
        // largest is under half the total, so trimming to it would gut the mesh.
        let bodies = [patch(cells: 3, origin: .zero)]
            + (1...4).map { patch(cells: 2, origin: SIMD3(Float($0) * 3, 0, 0)) }
        let mesh = combined(bodies)
        let trimmed = mesh.removingSmallComponents(minFraction: 0.9)
        XCTAssertEqual(trimmed.triangleCount, mesh.triangleCount,
                       "a cut that keeps less than half must not happen at all")
    }

    /// Two subjects of comparable size: neither is a speck, so both survive under
    /// the ordinary threshold too.
    func testTwoComparableSubjectsBothSurvive() {
        let a = patch(cells: 10, origin: .zero)
        let b = patch(cells: 8, origin: SIMD3(4, 0, 0))
        let mesh = combined([a, b])
        let trimmed = mesh.removingSmallComponents()
        XCTAssertEqual(trimmed.triangleCount, mesh.triangleCount)
        XCTAssertTrue(trimmed.vertices.contains { $0.x > 3.5 }, "the second subject is gone")
    }

    /// A subject with a speck AND a second real object: the speck goes, the object
    /// stays. This is the case the missing guard used to get wrong in the other
    /// direction — it is not enough to decline everything.
    func testSpeckGoesButTheSecondSubjectStays() {
        let main = patch(cells: 12, origin: .zero)             // 288
        let second = patch(cells: 6, origin: SIMD3(4, 0, 0))   // 72, 25 % of main
        let speck = patch(cells: 1, origin: SIMD3(9, 9, 9))    // 2
        let trimmed = combined([main, second, speck]).removingSmallComponents()
        XCTAssertEqual(trimmed.triangleCount, main.triangleCount + second.triangleCount)
        XCTAssertTrue(trimmed.vertices.contains { $0.x > 3.5 }, "second subject dropped")
        XCTAssertFalse(trimmed.vertices.contains { $0.x > 8 }, "speck kept")
    }

    // MARK: - Degenerate input

    func testSingleComponentIsUntouched() {
        let mesh = patch(cells: 6, origin: .zero)
        XCTAssertEqual(mesh.removingSmallComponents().triangleCount, mesh.triangleCount)
    }

    func testEmptyMeshSurvives() {
        XCTAssertEqual(MeshData().removingSmallComponents().triangleCount, 0)
    }
}
