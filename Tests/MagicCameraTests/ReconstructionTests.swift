//
//  ReconstructionTests.swift
//  MagicCameraTests
//
//  Verifies the surface-reconstruction stack: marching cubes on an analytic
//  SDF, the Poisson-style smooth reconstructor, and ball-pivoting — all on
//  synthetic spheres/planes with known geometry.
//

import XCTest
import simd
@testable import MagicCamera

final class ReconstructionTests: XCTestCase {

    // MARK: - Marching cubes

    /// Polygonising the SDF of a unit sphere must produce a closed surface with
    /// outward orientation and a volume close to 4/3·π.
    func testMarchingCubesSphere() throws {
        let cellSize: Float = 0.1
        let origin = SIMD3<Float>(repeating: -1.5)
        let n = 30
        func sdf(_ corner: SIMD3<Int32>) -> Float {
            let p = origin + SIMD3<Float>(Float(corner.x), Float(corner.y), Float(corner.z)) * cellSize
            return simd_length(p) - 1
        }
        var cells: [MarchingCubes.Cell] = []
        for z in 0..<n {
            for y in 0..<n {
                for x in 0..<n {
                    let base = SIMD3<Int32>(Int32(x), Int32(y), Int32(z))
                    var v = [Float](repeating: 0, count: 8)
                    for (i, off) in MarchingCubes.cornerOffsets.enumerated() {
                        v[i] = sdf(base &+ off)
                    }
                    cells.append(MarchingCubes.Cell(
                        base: base, values: (v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7])))
                }
            }
        }
        let mesh = try XCTUnwrap(MarchingCubes.mesh(cells: cells, origin: origin, cellSize: cellSize))
        XCTAssertGreaterThan(mesh.triangleCount, 500)

        // All vertices on the sphere (within a cell of tolerance).
        for v in mesh.vertices {
            XCTAssertEqual(simd_length(v), 1, accuracy: cellSize)
        }

        // Closed: every edge shared by exactly two triangles.
        var edgeUse: [String: Int] = [:]
        var i = 0
        while i + 2 < mesh.indices.count {
            let t = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]]
            for k in 0..<3 {
                let a = min(t[k], t[(k + 1) % 3]), b = max(t[k], t[(k + 1) % 3])
                edgeUse["\(a)-\(b)", default: 0] += 1
            }
            i += 3
        }
        XCTAssertTrue(edgeUse.values.allSatisfy { $0 == 2 }, "surface should be watertight")

        // Outward winding → positive signed volume ≈ 4/3·π.
        let sphereVolume: Float = 4 * Float.pi / 3
        let signed = signedVolume(mesh)
        XCTAssertGreaterThan(signed, 0, "triangles should wind outward")
        XCTAssertEqual(signed, sphereVolume, accuracy: sphereVolume * 0.1)
    }

    // MARK: - Poisson-style smooth reconstruction

    func testSmoothReconstructorSphere() throws {
        let cloud = spherePointCloud(radius: 0.5, count: 4000)
        // Outward normals supplied directly (exact for a sphere).
        let normals = cloud.positions.map { simd_normalize($0) }
        let mesh = try XCTUnwrap(
            SmoothSurfaceReconstructor.reconstruct(cloud, resolution: 48, normals: normals))
        XCTAssertGreaterThan(mesh.triangleCount, 300)
        for v in mesh.vertices {
            XCTAssertEqual(simd_length(v), 0.5, accuracy: 0.08,
                           "vertices should sit on the scanned sphere")
        }
        let expectedVolume: Float = 4 * Float.pi / 3 * 0.125   // radius 0.5
        XCTAssertEqual(abs(signedVolume(mesh)), expectedVolume,
                       accuracy: expectedVolume * 0.35)
    }

    /// Degenerate input must not crash and must return nil.
    func testSmoothReconstructorRejectsSparseInput() {
        var cloud = PointCloud()
        for i in 0..<20 {
            cloud.append(position: SIMD3<Float>(Float(i) * 0.01, 0, 0),
                         color: .one, confidence: 1)
        }
        XCTAssertNil(SmoothSurfaceReconstructor.reconstruct(cloud))
    }

    // MARK: - Ball pivoting

    /// A flat grid of points must mesh into a connected sheet whose vertices
    /// are the input points themselves (BPA interpolates, never moves points).
    func testBallPivotingPlane() throws {
        var cloud = PointCloud()
        let n = 18
        let spacing: Float = 0.05
        for y in 0..<n {
            for x in 0..<n {
                cloud.append(position: SIMD3<Float>(Float(x) * spacing, Float(y) * spacing, 0),
                             color: .one, confidence: 1)
            }
        }
        let up = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: cloud.count)
        let mesh = try XCTUnwrap(BallPivotingMesher.reconstruct(cloud, normals: up))

        // Most of the grid should be triangulated: (n-1)² cells × 2 triangles.
        let full = (n - 1) * (n - 1) * 2
        XCTAssertGreaterThan(mesh.triangleCount, full / 2)

        let inputSet = Set(cloud.positions.map { "\($0.x),\($0.y),\($0.z)" })
        for v in mesh.vertices {
            XCTAssertTrue(inputSet.contains("\(v.x),\(v.y),\(v.z)"),
                          "BPA vertices must be input points")
        }

        // Consistent orientation: every face normal points along +z.
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])]
            let b = mesh.vertices[Int(mesh.indices[i + 1])]
            let c = mesh.vertices[Int(mesh.indices[i + 2])]
            XCTAssertGreaterThan(simd_cross(b - a, c - a).z, 0)
            i += 3
        }
    }

    func testMeanSpacingOnRegularGrid() throws {
        var points: [SIMD3<Float>] = []
        for z in 0..<8 {
            for y in 0..<8 {
                for x in 0..<8 {
                    points.append(SIMD3<Float>(Float(x), Float(y), Float(z)) * 0.1)
                }
            }
        }
        let spacing = try XCTUnwrap(BallPivotingMesher.meanSpacing(points))
        XCTAssertEqual(spacing, 0.1, accuracy: 0.02)
    }

    /// On a uniform grid every nn-distance is equal, so any percentile equals
    /// the mean — the percentile variant must not disturb the simple case.
    func testSpacingPercentileMatchesMeanOnUniformGrid() throws {
        var points: [SIMD3<Float>] = []
        for z in 0..<8 { for y in 0..<8 { for x in 0..<8 {
            points.append(SIMD3<Float>(Float(x), Float(y), Float(z)) * 0.1)
        } } }
        let p50 = try XCTUnwrap(BallPivotingMesher.spacingPercentile(points, percentile: 0.5))
        XCTAssertEqual(p50, 0.1, accuracy: 0.02)
    }

    /// The reason the reconstruction clamp moved off the mean: on a distance-
    /// coarsened room cloud (dense near wall, sparse far wall) the mean is
    /// dragged up by the far tail, so it over-coarsens the lattice. A low
    /// percentile must track the DENSE bulk instead — well below the mean.
    func testSpacingPercentileIsRobustToASparseFarTail() throws {
        var points: [SIMD3<Float>] = []
        // Dense near wall: 12 mm grid, 40×40 points on z=0.
        for y in 0..<40 { for x in 0..<40 {
            points.append(SIMD3<Float>(Float(x) * 0.012, Float(y) * 0.012, 0))
        } }
        // Sparse far wall: 48 mm grid, 20×20 points 3 m away on z=3.
        for y in 0..<20 { for x in 0..<20 {
            points.append(SIMD3<Float>(Float(x) * 0.048, Float(y) * 0.048, 3))
        } }
        let mean = try XCTUnwrap(BallPivotingMesher.meanSpacing(points))
        let p35 = try XCTUnwrap(BallPivotingMesher.spacingPercentile(points, percentile: 0.35))
        XCTAssertLessThan(p35, mean, "a low percentile must track the dense bulk, not the mean")
        XCTAssertEqual(p35, 0.012, accuracy: 0.006, "p35 sits on the dense near wall")
    }

    // MARK: - Helpers

    private func signedVolume(_ mesh: MeshData) -> Float {
        var sixV: Float = 0
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])]
            let b = mesh.vertices[Int(mesh.indices[i + 1])]
            let c = mesh.vertices[Int(mesh.indices[i + 2])]
            sixV += simd_dot(a, simd_cross(b, c))
            i += 3
        }
        return sixV / 6
    }

    /// Quasi-uniform sphere sampling (Fibonacci lattice).
    private func spherePointCloud(radius: Float, count: Int) -> PointCloud {
        var cloud = PointCloud()
        cloud.reserveCapacity(count)
        let golden = Float.pi * (3 - sqrtf(5))
        for i in 0..<count {
            let y = 1 - 2 * (Float(i) + 0.5) / Float(count)
            let r = sqrtf(max(1 - y * y, 0))
            let theta = golden * Float(i)
            let p = SIMD3<Float>(cosf(theta) * r, y, sinf(theta) * r) * radius
            cloud.append(position: p, color: SIMD3<Float>(0.5, 0.5, 0.5), confidence: 1)
        }
        return cloud
    }
}
