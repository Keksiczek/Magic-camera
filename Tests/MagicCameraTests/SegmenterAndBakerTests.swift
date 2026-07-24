//
//  SegmenterAndBakerTests.swift
//  MagicCameraTests
//
//  Covers object isolation (RANSAC plane + clustering), texture/UV baking,
//  the web-viewer HTML export and autosave crash recovery.
//

import XCTest
import simd
@testable import MagicCamera

final class SegmenterAndBakerTests: XCTestCase {

    // MARK: - Fixtures

    /// Floor plane + a dense "subject" ball at the centre + a small far blob.
    private func tabletopScene() -> (cloud: PointCloud, subjectCount: Int) {
        var cloud = PointCloud()
        var rng = LCG(seed: 7)

        // Floor: 40×40 grid at y = 0.
        for x in 0..<40 {
            for z in 0..<40 {
                cloud.append(position: SIMD3<Float>(Float(x) * 0.02 - 0.4, 0, Float(z) * 0.02 - 0.4),
                             color: SIMD3<Float>(0.4, 0.3, 0.2), confidence: 1)
            }
        }
        // Subject: 600-point ball at (0, 0.15, 0), radius 0.08.
        let subjectCount = 600
        for _ in 0..<subjectCount {
            let p = SIMD3<Float>(rng.unit() * 0.08, 0.15 + rng.unit() * 0.08, rng.unit() * 0.08)
            cloud.append(position: p, color: SIMD3<Float>(0.9, 0.1, 0.1), confidence: 1)
        }
        // Distraction blob: 80 points far away at (1.2, 0.3, 1.2).
        for _ in 0..<80 {
            let p = SIMD3<Float>(1.2 + rng.unit() * 0.04, 0.3 + rng.unit() * 0.04, 1.2 + rng.unit() * 0.04)
            cloud.append(position: p, color: SIMD3<Float>(0.1, 0.9, 0.1), confidence: 1)
        }
        return (cloud, subjectCount)
    }

    // MARK: - Plane detection

    func testDetectsFloorPlane() throws {
        let (cloud, _) = tabletopScene()
        let plane = try XCTUnwrap(PointCloudSegmenter.detectDominantPlane(cloud))
        XCTAssertGreaterThan(abs(plane.normal.y), 0.95, "dominant plane should be the horizontal floor")
        XCTAssertEqual(abs(plane.d), 0, accuracy: 0.03)
    }

    // MARK: - Clustering & isolation

    func testClustersSeparateObjects() {
        let (cloud, _) = tabletopScene()
        let plane = PointCloudSegmenter.detectDominantPlane(cloud)!
        let remaining = PointCloudSegmenter.removingPlane(cloud, plane: plane)
        let clusters = PointCloudSegmenter.clusters(remaining)
        XCTAssertGreaterThanOrEqual(clusters.count, 2, "subject and far blob should separate")
        XCTAssertGreaterThan(clusters[0].count, clusters[1].count)
    }

    func testIsolateMainSubjectKeepsCentralBall() throws {
        let (cloud, subjectCount) = tabletopScene()
        let result = try XCTUnwrap(PointCloudSegmenter.isolateMainSubject(cloud))

        // Kept roughly the subject (allow a few floor stragglers near its base).
        XCTAssertEqual(Float(result.keptPoints), Float(subjectCount), accuracy: Float(subjectCount) / 4)
        XCTAssertGreaterThan(result.removedPlanePoints, 1000)

        // Everything kept sits near the subject's centre, not the far blob.
        let centroid = result.cloud.centroid()
        XCTAssertEqual(simd_distance(centroid, SIMD3<Float>(0, 0.15, 0)), 0, accuracy: 0.1)
    }

    // MARK: - Texture baking

    func testBakeProducesAtlasAndUVs() throws {
        // Simple two-triangle mesh + a colourful cloud around it.
        let vertices = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                        SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 1, 0)]
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 4)
        let mesh = MeshData(vertices: vertices, normals: normals,
                            indices: [0, 1, 2, 2, 1, 3])
        var cloud = PointCloud()
        for y in 0..<12 {
            for x in 0..<12 {
                cloud.append(position: SIMD3<Float>(Float(x) / 11, Float(y) / 11, 0),
                             color: SIMD3<Float>(Float(x) / 11, Float(y) / 11, 0.5),
                             confidence: 1)
            }
        }

        let baked = try XCTUnwrap(MeshTextureBaker.bake(mesh: mesh, cloud: cloud,
                                                        textureSize: 256))
        XCTAssertEqual(baked.mesh.vertices.count, 6, "vertices duplicated per corner")
        XCTAssertEqual(baked.uvs.count, baked.mesh.vertices.count)
        for uv in baked.uvs {
            XCTAssertTrue((0...1).contains(uv.x) && (0...1).contains(uv.y), "UVs inside atlas")
        }
        // PNG magic bytes.
        XCTAssertEqual([UInt8](baked.texturePNG.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(baked.textureSize, 256)

        // Triangles keep their world geometry.
        XCTAssertEqual(baked.mesh.triangleCount, mesh.triangleCount)

        // Textured GLB serialises and carries the PNG payload.
        let glb = try TexturedMeshExporter.glbData(
            from: baked)
        XCTAssertGreaterThan(glb.count, baked.texturePNG.count)
        XCTAssertEqual([UInt8](glb.prefix(4)), [0x67, 0x6C, 0x54, 0x46]) // "glTF"
    }

    // MARK: - Web viewer

    func testWebViewerCloudExport() throws {
        var cloud = PointCloud()
        for i in 0..<100 {
            cloud.append(position: SIMD3<Float>(Float(i) * 0.01, 0, 0),
                         color: SIMD3<Float>(1, 0, 0), confidence: 1)
        }
        let url = try WebViewerExporter.write(cloud: cloud, filename: "test-viewer-cloud")
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("OrbitControls"))
        XCTAssertTrue(html.contains("PointsMaterial"))
        XCTAssertTrue(html.contains("100 points"))
        try? FileManager.default.removeItem(at: url)
    }

    func testWebViewerMeshExport() throws {
        let mesh = MeshData(vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                            normals: [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 3),
                            indices: [0, 1, 2])
        let url = try WebViewerExporter.write(mesh: mesh, filename: "test-viewer-mesh")
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("GLTFLoader"))
        XCTAssertTrue(html.contains("HemisphereLight"))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Autosave / crash recovery

    func testAutosaveRoundtripAndClear() throws {
        var cloud = PointCloud()
        for i in 0..<500 {
            cloud.append(position: SIMD3<Float>(Float(i), Float(i) * 2, Float(i) * 3),
                         color: SIMD3<Float>(0.1, 0.2, 0.3), confidence: 0.5)
        }
        ScanAutoSave.saveCloud(cloud)
        try waitForAutosave { ScanAutoSave.pending() != nil }

        guard case .cloud = try XCTUnwrap(ScanAutoSave.pending()) else {
            return XCTFail("expected a pending cloud snapshot")
        }
        let restored = try XCTUnwrap(ScanAutoSave.restoreCloud()).cloud
        XCTAssertEqual(restored.count, cloud.count)
        XCTAssertEqual(restored.positions[42], cloud.positions[42])
        XCTAssertEqual(restored.confidences[7], 0.5)

        ScanAutoSave.clear()
        try waitForAutosave { ScanAutoSave.pending() == nil }
    }

    func testAutosaveMeshReplacesCloudSnapshot() throws {
        var cloud = PointCloud()
        for i in 0..<100 {
            cloud.append(position: SIMD3<Float>(Float(i), 0, 0), color: .one, confidence: 1)
        }
        ScanAutoSave.saveCloud(cloud)
        try waitForAutosave { ScanAutoSave.pending() != nil }

        let mesh = MeshData(vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                            normals: [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 3),
                            indices: [0, 1, 2])
        ScanAutoSave.saveMesh(mesh)
        try waitForAutosave {
            if case .mesh = ScanAutoSave.pending() { return true }
            return false
        }
        let restored = try XCTUnwrap(ScanAutoSave.restoreMesh())
        XCTAssertEqual(restored.triangleCount, 1)

        ScanAutoSave.clear()
        try waitForAutosave { ScanAutoSave.pending() == nil }
    }

    /// Autosave writes are queued — poll briefly until the condition holds.
    private func waitForAutosave(_ condition: () -> Bool) throws {
        for _ in 0..<100 {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("autosave condition not reached in time")
    }

    // MARK: - Stray-cluster removal

    func testRemoveStrayClustersDropsDetachedSpecks() {
        var cloud = PointCloud()
        // Dominant surface: 40×40 grid (1600 pts) at 1 cm spacing.
        for x in 0..<40 {
            for z in 0..<40 {
                cloud.append(position: SIMD3<Float>(Float(x) * 0.01, 0, Float(z) * 0.01),
                             color: SIMD3<Float>(repeating: 1), confidence: 1)
            }
        }
        var rng = LCG(seed: 11)
        // Three detached 30-point specks, parked far from the surface and apart.
        for s in 0..<3 {
            let centre = SIMD3<Float>(0.8 + Float(s) * 0.5, 0.4, 0.6)
            for _ in 0..<30 {
                cloud.append(position: centre + SIMD3<Float>(rng.unit(), rng.unit(), rng.unit()) * 0.02,
                             color: SIMD3<Float>(repeating: 1), confidence: 1)
            }
        }
        let cleaned = PointCloudSegmenter.removeStrayClusters(cloud)
        XCTAssertEqual(cleaned.count, 1600, "the three 30-point specks should be dropped, the surface kept")
    }

    func testRemoveStrayClustersKeepsMultiObjectScene() {
        // Two equal 800-point bodies far apart — neither is a stray.
        var cloud = PointCloud()
        for k in 0..<2 {
            for x in 0..<40 {
                for z in 0..<20 {
                    cloud.append(position: SIMD3<Float>(Float(x) * 0.01 + Float(k) * 2, 0, Float(z) * 0.01),
                                 color: SIMD3<Float>(repeating: 1), confidence: 1)
                }
            }
        }
        XCTAssertEqual(PointCloudSegmenter.removeStrayClusters(cloud).count, cloud.count,
                       "two equal bodies must both survive")
    }

    func testRemoveStrayClustersNoOpOnSingleBody() {
        var cloud = PointCloud()
        for x in 0..<40 {
            for z in 0..<40 {
                cloud.append(position: SIMD3<Float>(Float(x) * 0.01, 0, Float(z) * 0.01),
                             color: SIMD3<Float>(repeating: 1), confidence: 1)
            }
        }
        XCTAssertEqual(PointCloudSegmenter.removeStrayClusters(cloud).count, cloud.count)
    }

    /// Deterministic ±0.5 noise.
    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func unit() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 33) / Float(UInt32.max) - 0.5
        }
    }
}
