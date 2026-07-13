//
//  MeshPrimitiveSnapTests.swift
//  MagicCameraTests
//
//  Verifies the surface-of-revolution snapper rounds a noisy cylinder / cone /
//  vase / sphere back onto its ideal profile (the "recognise common shapes"
//  wish), rejects shapes that aren't turned (a box, a flat wall), and leaves the
//  parts it doesn't recognise (a mug's handle) untouched. Mirrors the scratchpad
//  harness.
//

import XCTest
import Foundation
import simd
@testable import MagicCamera

final class MeshPrimitiveSnapTests: XCTestCase {

    private let up = SIMD3<Float>(0, 1, 0)

    /// A seam-free surface of revolution about the y-axis: radius `r(h)` with the
    /// matching outward normal, jittered radially. Order is preserved (no welding).
    private func revolution(rows: Int, sectors: Int, height: Float, noise: Float,
                            seed: UInt64, radius: (Float) -> Float, slope: (Float) -> Float)
        -> (verts: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        var rng = SeededGenerator(seed: seed)
        var v: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
        for i in 0...rows { for j in 0..<sectors {
            let h = height * (Float(i) / Float(rows) - 0.5)
            let th = 2 * Float.pi * Float(j) / Float(sectors)
            let rHat = SIMD3<Float>(cos(th), 0, sin(th))
            let jit = (Float(rng.next(upTo: 2001)) / 1000 - 1) * noise
            v.append(rHat * (radius(h) + jit) + up * h)
            n.append(simd_normalize(rHat - up * slope(h)))
        }}
        var idx: [UInt32] = []
        for i in 0..<rows { for j in 0..<sectors {
            let jn = (j + 1) % sectors
            let a = UInt32(i * sectors + j), b = UInt32(i * sectors + jn)
            let c = UInt32((i + 1) * sectors + j), d = UInt32((i + 1) * sectors + jn)
            idx.append(contentsOf: [a, c, b, b, c, d])
        }}
        return (v, n, idx)
    }

    private func radialDev(_ verts: [SIMD3<Float>], _ want: (SIMD3<Float>) -> Float) -> Float {
        verts.map { abs(sqrt($0.x * $0.x + $0.z * $0.z) - want($0)) }.max() ?? 0
    }

    // MARK: - Snap behaviour

    func testCylinderSnapsRound() {
        let c = revolution(rows: 40, sectors: 64, height: 0.25, noise: 0.006, seed: 11,
                           radius: { _ in 0.08 }, slope: { _ in 0 })
        let mesh = MeshData(vertices: c.verts, normals: c.normals, indices: c.indices)
        XCTAssertGreaterThan(radialDev(mesh.vertices) { _ in 0.08 }, 0.004)
        let r = MeshPrimitiveSnap.snap(mesh)
        XCTAssertGreaterThanOrEqual(r.stats.revolutions, 1)
        XCTAssertGreaterThan(r.stats.snapped, mesh.vertices.count / 2)
        // Relief-preserving snap reduces the wobble substantially (it deliberately
        // keeps the coherent part, so not all the way to zero on pure noise).
        XCTAssertLessThan(radialDev(r.mesh.vertices) { _ in 0.08 }, 0.0025)
    }

    func testConeSnapsRound() {
        let H: Float = 0.2, rB: Float = 0.10, rT: Float = 0.04, slope = (rT - rB) / H
        let c = revolution(rows: 40, sectors: 64, height: H, noise: 0.006, seed: 3,
                           radius: { h in rB + (h + H / 2) / H * (rT - rB) }, slope: { _ in slope })
        let mesh = MeshData(vertices: c.verts, normals: c.normals, indices: c.indices)
        let r = MeshPrimitiveSnap.snap(mesh)
        XCTAssertGreaterThanOrEqual(r.stats.revolutions, 1)
        XCTAssertLessThan(radialDev(r.mesh.vertices) { p in rB + (p.y + H / 2) / H * (rT - rB) }, 0.0035)
    }

    func testVaseProfileSnaps() {
        let H: Float = 0.24
        func rr(_ h: Float) -> Float { 0.05 + 0.03 * sin(Float.pi * (h + H / 2) / H) }
        func ss(_ h: Float) -> Float { 0.03 * (Float.pi / H) * cos(Float.pi * (h + H / 2) / H) }
        let c = revolution(rows: 48, sectors: 64, height: H, noise: 0.006, seed: 9, radius: rr, slope: ss)
        let mesh = MeshData(vertices: c.verts, normals: c.normals, indices: c.indices)
        let r = MeshPrimitiveSnap.snap(mesh)
        XCTAssertGreaterThanOrEqual(r.stats.revolutions, 1)
        XCTAssertLessThan(radialDev(r.mesh.vertices) { rr($0.y) }, 0.003)
    }

    func testSphereSnapsRound() {
        var rng = SeededGenerator(seed: 23)
        let radius: Float = 0.12
        var v: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
        for i in 1...25 { for j in 0..<52 {
            let phi = Float.pi * Float(i) / 26, th = 2 * Float.pi * Float(j) / 52
            let dir = SIMD3<Float>(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
            let jit = (Float(rng.next(upTo: 2001)) / 1000 - 1) * 0.01
            v.append(dir * (radius + jit)); n.append(dir)
        }}
        let mesh = MeshData(vertices: v, normals: n, indices: gridIndices(nRows: 25, nCols: 52, closed: true))
        let r = MeshPrimitiveSnap.snap(mesh)
        XCTAssertGreaterThanOrEqual(r.stats.spheres, 1, "a ball registers as a sphere, not a profile")
        let dev = r.mesh.vertices.map { abs(simd_length($0) - radius) }.max() ?? 0
        XCTAssertLessThan(dev, 0.002)
    }

    func testBoxIsRejected() {
        var rng = SeededGenerator(seed: 5)
        var v: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)), (SIMD3(-1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)),
            (SIMD3(0,1,0), SIMD3(1,0,0), SIMD3(0,0,1)), (SIMD3(0,-1,0), SIMD3(1,0,0), SIMD3(0,0,1)),
            (SIMD3(0,0,1), SIMD3(1,0,0), SIMD3(0,1,0)), (SIMD3(0,0,-1), SIMD3(1,0,0), SIMD3(0,1,0))]
        var idx: [UInt32] = []
        for (nrm, u, w) in faces {
            let base = UInt32(v.count)
            for i in 0...16 { for j in 0...16 {
                let s = Float(i) / 16 - 0.5, t = Float(j) / 16 - 0.5
                let jit = (Float(rng.next(upTo: 2001)) / 1000 - 1) * 0.005
                v.append(nrm * 0.1 + u * (s * 0.2) + w * (t * 0.2) + nrm * jit); n.append(nrm)
            }}
            for i in 0..<16 { for j in 0..<16 {
                let a = base + UInt32(i * 17 + j)
                idx.append(contentsOf: [a, a + 17, a + 1, a + 1, a + 17, a + 18])
            }}
        }
        let mesh = MeshData(vertices: v, normals: n, indices: idx)
        let r = MeshPrimitiveSnap.snap(mesh)
        XCTAssertEqual(r.stats.snapped, 0, "a box has no turned surface — its face strips must not read as a cylinder")
        XCTAssertEqual(r.mesh.vertices, mesh.vertices)
    }

    func testFlatWallIsRejected() {
        var rng = SeededGenerator(seed: 5)
        var v: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
        for i in 0...40 { for j in 0...40 {
            let jit = (Float(rng.next(upTo: 2001)) / 1000 - 1) * 0.01
            v.append(SIMD3(Float(i) / 20, Float(j) / 20, jit)); n.append(SIMD3(0, 0, 1))
        }}
        let mesh = MeshData(vertices: v, normals: n, indices: gridIndices(nRows: 41, nCols: 41, closed: false))
        let r = MeshPrimitiveSnap.snap(mesh)
        XCTAssertEqual(r.stats.snapped, 0, "parallel normals name no axis of revolution")
    }

    func testMugHandleIsPreserved() {
        var c = revolution(rows: 36, sectors: 60, height: 0.10, noise: 0.006, seed: 31,
                           radius: { _ in 0.045 }, slope: { _ in 0 })
        let handleStart = c.verts.count
        for k in 0...40 {
            let a = Float.pi * (Float(k) / 40 - 0.5)
            c.verts.append(SIMD3(0.045 + 0.02 * cos(a), 0.03 * sin(a) * 2, 0))
            c.normals.append(SIMD3(0, 0, 1))   // azimuthal — not a turned surface
        }
        let mesh = MeshData(vertices: c.verts, normals: c.normals, indices: c.indices)
        let r = MeshPrimitiveSnap.snap(mesh)
        XCTAssertGreaterThanOrEqual(r.stats.revolutions, 1)
        for i in handleStart..<mesh.vertices.count {
            XCTAssertEqual(r.mesh.vertices[i], mesh.vertices[i], "handle vertex \(i) must be untouched")
        }
    }

    func testDecorationIsPreserved() {
        // A cylinder (r = 6 cm) with a raised vertical rib over a few sectors —
        // azimuthal decoration that isn't in the axisymmetric profile — plus noise.
        // The plain wall must round; the rib must stay raised (not flattened).
        var rng = SeededGenerator(seed: 17)
        let base: Float = 0.06, ribRise: Float = 0.006
        let rows = 48, sectors = 72
        let ribSectors = 34...39
        var v: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
        for i in 0...rows { for j in 0..<sectors {
            let h = 0.24 * (Float(i) / Float(rows) - 0.5)
            let th = 2 * Float.pi * Float(j) / Float(sectors)
            let rHat = SIMD3<Float>(cos(th), 0, sin(th))
            let rise = ribSectors.contains(j) ? ribRise : 0
            let jit = (Float(rng.next(upTo: 2001)) / 1000 - 1) * 0.002
            v.append(rHat * (base + rise + jit) + up * h); n.append(rHat)
        }}
        let mesh = MeshData(vertices: v, normals: n,
                            indices: gridIndices(nRows: rows + 1, nCols: sectors, closed: true))
        let r = MeshPrimitiveSnap.snap(mesh)
        XCTAssertGreaterThanOrEqual(r.stats.revolutions, 1)

        func radius(_ p: SIMD3<Float>) -> Float { sqrt(p.x * p.x + p.z * p.z) }
        var plainMax: Float = 0, ribMin = Float.greatestFiniteMagnitude
        for i in 0...rows { for j in 0..<sectors {
            let rad = radius(r.mesh.vertices[i * sectors + j])
            if (30...43).contains(j) { if (35...38).contains(j), i > 4, i < rows - 4 { ribMin = min(ribMin, rad) } }
            else { plainMax = max(plainMax, abs(rad - base)) }
        }}
        XCTAssertLessThan(plainMax, 0.003, "the plain wall rounds — crinkle and noise removed")
        XCTAssertGreaterThan(ribMin, base + 0.003, "the raised rib survives, not flattened onto the profile")
    }

    // MARK: - Sphere seed math

    func testSeedSphereRecoversCentreAndRadius() {
        let s = MeshPrimitiveSnap.seedSphere(SIMD3(0.2, 0, 0), SIMD3(1, 0, 0),
                                             SIMD3(0, 0.2, 0), SIMD3(0, 1, 0))
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.radius, 0.2, accuracy: 1e-4)
        XCTAssertLessThan(simd_length(s!.center), 1e-4)
    }

    // MARK: - Helpers

    /// Triangle indices for an `nRows × nCols` vertex grid (vertex index
    /// `i*nCols + j`). `closed` wraps the last column back to the first (a
    /// tube / sphere band); otherwise it is an open sheet. References every row.
    private func gridIndices(nRows: Int, nCols: Int, closed: Bool) -> [UInt32] {
        var idx: [UInt32] = []
        for i in 0..<(nRows - 1) { for j in 0..<(closed ? nCols : nCols - 1) {
            let jn = closed ? (j + 1) % nCols : j + 1
            let a = UInt32(i * nCols + j), b = UInt32(i * nCols + jn)
            let c = UInt32((i + 1) * nCols + j), d = UInt32((i + 1) * nCols + jn)
            idx.append(contentsOf: [a, c, b, b, c, d])
        }}
        return idx
    }
}
