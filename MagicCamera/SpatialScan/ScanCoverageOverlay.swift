//
//  ScanCoverageOverlay.swift
//  Magic Camera
//
//  Live "photograph this" hint for the sweep. The recorder knows which coarse
//  cells hold captured surface and which of those a texture keyframe has actually
//  seen; the difference is what the bake will later report as `unseen` — the
//  triangles that fall back to soft cloud colour instead of a real photo.
//
//  This renders that difference as small amber blocks sitting on the surface, so
//  the user paints them away with the camera instead of discovering the gap after
//  Finish. Nothing is drawn where coverage is complete, so a well-swept room ends
//  visually clean — the overlay's job is to disappear.
//

import SceneKit
import simd

enum ScanCoverageOverlay {
    /// Amber blocks at `centers`, each a cube of `cellSize`. Returns nil for an
    /// empty set so the caller can clear the node instead of building an empty
    /// geometry. Pure value math — safe to build off the main thread.
    static func geometry(centers: [SIMD3<Float>], cellSize: Float) -> SCNGeometry? {
        guard !centers.isEmpty else { return nil }
        // Small marks (a third of the cell) so they read as a light stipple that
        // guides the eye, not an opaque wall of blocks slapped over the camera feed.
        let h = cellSize * 0.22
        let corners: [SIMD3<Float>] = [
            SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h),
            SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(-h, h, h)
        ]
        // 12 triangles, outward winding.
        let cube: [Int32] = [
            0, 2, 1, 0, 3, 2,   // −Z
            4, 5, 6, 4, 6, 7,   // +Z
            0, 1, 5, 0, 5, 4,   // −Y
            3, 7, 6, 3, 6, 2,   // +Y
            0, 4, 7, 0, 7, 3,   // −X
            1, 2, 6, 1, 6, 5    // +X
        ]

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(centers.count * 8)
        var indices: [Int32] = []
        indices.reserveCapacity(centers.count * 36)
        for (i, center) in centers.enumerated() {
            let base = Int32(i * 8)
            for corner in corners { vertices.append(center + corner) }
            for index in cube { indices.append(base + index) }
        }

        let source = SCNGeometrySource(vertices: vertices.map {
            SCNVector3($0.x, $0.y, $0.z)
        })
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .constant          // unlit — a hint, not scene geometry
        material.diffuse.contents = UIColor(red: 1.0, green: 0.62, blue: 0.12, alpha: 1)
        material.emission.contents = UIColor(red: 1.0, green: 0.52, blue: 0.06, alpha: 1)
        material.transparency = 0.38
        material.isDoubleSided = true
        material.writesToDepthBuffer = false        // never occlude the camera feed
        material.readsFromDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }
}
