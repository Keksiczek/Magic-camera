import XCTest
import simd
@testable import MagicCamera

final class ScanStoreTests: XCTestCase {
    func testSaveLoadRoundTrip() throws {
        var cloud = PointCloud()
        cloud.append(position: SIMD3<Float>(1, 2, 3), color: SIMD3<Float>(1, 0, 0), confidence: 1)
        cloud.append(position: SIMD3<Float>(-4, 5, -6), color: SIMD3<Float>(0, 0.5, 1), confidence: 0.5)

        let name = "UnitTest-\(UUID().uuidString)"
        let url = try ScanStore.save(cloud, name: name)
        defer { ScanStore.delete(url) }

        let loaded = try ScanStore.load(url)
        XCTAssertEqual(loaded.count, cloud.count)
        XCTAssertEqual(loaded.positions[1], SIMD3<Float>(-4, 5, -6))
        XCTAssertEqual(loaded.colors[0], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(loaded.confidences[1], 0.5, accuracy: 1e-6)
    }

    func testListIncludesSavedScan() throws {
        var cloud = PointCloud()
        cloud.append(position: .zero, color: .zero, confidence: 1)
        let name = "UnitTestList-\(UUID().uuidString)"
        let url = try ScanStore.save(cloud, name: name)
        defer { ScanStore.delete(url) }

        let listed = ScanStore.list()
        XCTAssertTrue(listed.contains { $0.url == url && $0.pointCount == 1 })
    }

    /// A saved scan keeps its per-point view rays (v2 format), so reloading it
    /// from the gallery rebuilds with fusion-rays instead of est-normals.
    func testSaveLoadRoundTripWithDirections() throws {
        var cloud = PointCloud()
        cloud.append(position: SIMD3<Float>(1, 2, 3), color: SIMD3<Float>(1, 0, 0), confidence: 1)
        cloud.append(position: SIMD3<Float>(-4, 5, -6), color: SIMD3<Float>(0, 0.5, 1), confidence: 0.5)
        let directions = [simd_normalize(SIMD3<Float>(0, 0, -1)),
                          simd_normalize(SIMD3<Float>(1, -1, -2))]

        let name = "UnitTestDirs-\(UUID().uuidString)"
        let url = try ScanStore.save(cloud, name: name, directions: directions)
        defer { ScanStore.delete(url) }

        let loaded = try ScanStore.loadWithDirections(url)
        XCTAssertEqual(loaded.cloud.count, 2)
        XCTAssertEqual(loaded.directions?.count, 2)
        XCTAssertEqual(loaded.directions?[0], directions[0])
        XCTAssertEqual(loaded.directions?[1], directions[1])
    }

    /// A v1 file (no directions) still loads, returning nil directions — the
    /// caller falls back to estimated normals exactly as before.
    func testEncodeWithoutDirectionsIsV1() throws {
        var cloud = PointCloud()
        cloud.append(position: SIMD3<Float>(7, 8, 9), color: SIMD3<Float>(0.2, 0.4, 0.6), confidence: 1)
        let decoded = try ScanStore.decodeWithDirections(ScanStore.encode(cloud))
        XCTAssertEqual(decoded.cloud.count, 1)
        XCTAssertNil(decoded.directions)
    }

    /// Directions that don't line up 1:1 with the cloud are dropped (a v1 file),
    /// never written misaligned.
    func testMismatchedDirectionsDropped() throws {
        var cloud = PointCloud()
        cloud.append(position: .zero, color: .zero, confidence: 1)
        cloud.append(position: SIMD3<Float>(1, 1, 1), color: .zero, confidence: 1)
        let decoded = try ScanStore.decodeWithDirections(
            ScanStore.encode(cloud, directions: [SIMD3<Float>(0, 0, -1)]))  // only 1 for 2 points
        XCTAssertEqual(decoded.cloud.count, 2)
        XCTAssertNil(decoded.directions)
    }
}

final class ScanQualityTests: XCTestCase {
    func testQualityOrderingMakesSense() {
        let fast = ScanQuality.fast.config
        let balanced = ScanQuality.balanced.config
        let detailed = ScanQuality.detailed.config
        XCTAssertGreaterThan(detailed.maxPoints, balanced.maxPoints)
        XCTAssertGreaterThan(balanced.maxPoints, fast.maxPoints)
        XCTAssertLessThan(detailed.voxelSize, balanced.voxelSize)
        XCTAssertLessThan(balanced.voxelSize, fast.voxelSize)
    }
}

final class MeshExporterTests: XCTestCase {
    func testEmptyMeshThrows() {
        XCTAssertThrowsError(try MeshExporter.write(MeshData(), format: .obj))
    }

    func testMeshDataBoundingBox() {
        var mesh = MeshData()
        mesh.vertices = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 4, 6)]
        mesh.normals = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)]
        mesh.indices = [0, 1, 0]
        let box = mesh.boundingBox()
        XCTAssertEqual(box?.min, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(box?.max, SIMD3<Float>(2, 4, 6))
        XCTAssertEqual(mesh.triangleCount, 1)
    }
}

final class MeshStoreTests: XCTestCase {
    func testSaveLoadRoundTripWithClassification() throws {
        let mesh = MeshData(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 2, 3), SIMD3<Float>(-4, 5, -6)],
            normals: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)],
            indices: [0, 1, 2],
            classifications: [MeshClassification.floor.rawValue,
                              MeshClassification.wall.rawValue,
                              MeshClassification.table.rawValue])

        let name = "UnitTestMesh-\(UUID().uuidString)"
        let url = try MeshStore.save(mesh, name: name)
        defer { MeshStore.delete(url) }

        let loaded = try MeshStore.load(url)
        XCTAssertEqual(loaded.vertices, mesh.vertices)
        XCTAssertEqual(loaded.normals, mesh.normals)
        XCTAssertEqual(loaded.indices, mesh.indices)
        XCTAssertEqual(loaded.classifications, mesh.classifications)
        XCTAssertTrue(loaded.hasClassification)
        XCTAssertEqual(loaded.triangleCount, 1)
    }

    func testSaveLoadRoundTripWithoutClassification() throws {
        let mesh = MeshData(
            vertices: [SIMD3<Float>(0.5, -0.5, 1.5), SIMD3<Float>(2, 2, 2), SIMD3<Float>(3, 1, 4)],
            normals: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)],
            indices: [0, 1, 2])

        let name = "UnitTestMeshPlain-\(UUID().uuidString)"
        let url = try MeshStore.save(mesh, name: name)
        defer { MeshStore.delete(url) }

        let loaded = try MeshStore.load(url)
        XCTAssertEqual(loaded.vertices, mesh.vertices)
        XCTAssertEqual(loaded.indices, mesh.indices)
        XCTAssertFalse(loaded.hasClassification)
    }

    func testLibraryListsSavedMesh() throws {
        let mesh = MeshData(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1), SIMD3<Float>(2, 0, 1)],
            normals: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)],
            indices: [0, 1, 2])
        let name = "UnitTestLib-\(UUID().uuidString)"
        let url = try MeshStore.save(mesh, name: name)
        defer { MeshStore.delete(url) }

        let items = ScanLibrary.allItems()
        XCTAssertTrue(items.contains { $0.url == url && $0.kind == .mesh && $0.count == 1 })
    }
}

final class CaptureDensityTests: XCTestCase {
    private func noise(_ seed: UInt64, _ amp: Float) -> Float {
        var z = seed &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return (Float((z ^ (z >> 31)) % 2000) / 1000 - 1) * amp
    }

    /// A flat wall, even with ±2 cm LiDAR-ish noise, stays well below the capture
    /// detail threshold — the depth-noise eigenvalue is tiny next to the in-plane
    /// spread — so it gets coarsened, not kept fine.
    func testFlatNoisyPlaneReadsFlat() {
        var pts: [SIMD3<Float>] = []
        var s: UInt64 = 1
        for ix in 0..<12 { for iy in 0..<12 {
            s &+= 1
            pts.append(SIMD3(Float(ix) * 0.02, Float(iy) * 0.02, noise(s, 0.02)))
        } }
        XCTAssertLessThan(CaptureDensity.variation(pts), 0.04)
    }

    /// Real curvature (a sphere cap) lifts σ above the threshold, so it's kept fine.
    func testCurvedSurfaceReadsDetailed() {
        var pts: [SIMD3<Float>] = []
        let r: Float = 0.1
        for ix in -6...6 { for iy in -6...6 {
            let x = Float(ix) * 0.012, y = Float(iy) * 0.012
            let r2 = x * x + y * y
            if r2 < r * r { pts.append(SIMD3(x, y, r - (r * r - r2).squareRoot())) }
        } }
        XCTAssertGreaterThan(CaptureDensity.variation(pts), 0.04)
    }

    /// Per-point output is index-aligned and a flat grid scores low everywhere.
    func testSurfaceVariationAligned() {
        var pts: [SIMD3<Float>] = []
        for ix in 0..<10 { for iy in 0..<10 { pts.append(SIMD3(Float(ix) * 0.02, Float(iy) * 0.02, 0)) } }
        let sigma = CaptureDensity.surfaceVariation(pts, cellSize: 0.06)
        XCTAssertEqual(sigma.count, pts.count)
        XCTAssertLessThan(sigma.max() ?? 1, 0.04)
    }
}

final class AdaptiveOctreeTests: XCTestCase {
    private func plane(_ nx: Int) -> PointCloud {
        var c = PointCloud()
        for ix in 0..<nx { for iy in 0..<nx {
            c.append(position: SIMD3(Float(ix) * 0.01, Float(iy) * 0.01, 0), color: .zero, confidence: 1)
        } }
        return c
    }

    private func hemisphere(_ n: Int) -> PointCloud {
        var c = PointCloud()
        for i in 0..<n {
            let t = Float(i) * 2.399963, y = 1 - Float(i) / (Float(n) / 2 - 0.5)
            let r = (max(0, 1 - y * y)).squareRoot()
            c.append(position: SIMD3(cos(t) * r, y, sin(t) * r) * 0.4, color: .zero, confidence: 1)
        }
        return c
    }

    /// A perfectly flat plane settles into one uniform coarse level (no needless
    /// subdivision).
    func testFlatPlaneStaysCoarse() {
        let r = AdaptiveOctree.partition(plane(80), minCell: 0.02, maxCell: 0.16)
        XCTAssertFalse(r.leaves.isEmpty)
        XCTAssertEqual(r.minLeafSize, r.maxLeafSize, accuracy: 1e-5)
        XCTAssertGreaterThanOrEqual(r.minLeafSize, 0.06)
    }

    /// Curved geometry subdivides finer than a flat plane — the whole point.
    func testCurvedSubdividesFinerThanFlat() {
        let flat = AdaptiveOctree.partition(plane(80), minCell: 0.02, maxCell: 0.16)
        let curved = AdaptiveOctree.partition(hemisphere(4000), minCell: 0.02, maxCell: 0.16)
        func meanSize(_ r: AdaptiveOctree.Result) -> Float {
            r.leaves.map(\.size).reduce(0, +) / Float(r.leaves.count)
        }
        XCTAssertLessThan(meanSize(curved), meanSize(flat))
    }

    /// The partition covers every point exactly once.
    func testCoversEveryPointOnce() {
        let cloud = plane(50)
        let r = AdaptiveOctree.partition(cloud, minCell: 0.02, maxCell: 0.16)
        XCTAssertEqual(r.leaves.reduce(0) { $0 + $1.pointIndices.count }, cloud.count)
    }
}
