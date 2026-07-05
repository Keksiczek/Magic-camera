//
//  MeshTextureBaker.swift
//  Magic Camera
//
//  Bakes point-cloud colour into a texture atlas for a reconstructed mesh:
//  every texel of a triangle's chart is mapped back to world space
//  barycentrically and coloured from the nearest scan points (inverse-distance
//  weighted). Chart layout, UV generation and PNG encoding live in
//  TextureAtlas (shared with PhotoTextureBaker).
//

import Foundation
import simd

/// A mesh with per-vertex UVs and a baked colour atlas (PNG).
struct TexturedMesh: Sendable {
    var mesh: MeshData
    var uvs: [SIMD2<Float>]
    var texturePNG: Data
    var textureSize: Int
}

enum MeshTextureBaker {
    /// Bakes `cloud`'s colours onto `mesh`. Returns nil for empty input or when
    /// PNG encoding fails. Heavy (CPU rasterisation) — run off the main thread.
    static func bake(mesh: MeshData, cloud: PointCloud,
                     textureSize requested: Int? = nil) -> TexturedMesh? {
        let triCount = mesh.indices.count / 3
        guard triCount > 0, !cloud.isEmpty else { return nil }

        // Area-adaptive atlas (default 4096 ceiling — cloud colour is coarse, so
        // the surface path's higher ceiling isn't worth the memory here).
        let layout = TextureAtlas.Layout(triangleCount: triCount, requested: requested,
                                         surfaceArea: mesh.surfaceArea())
        let geometry = TextureAtlas.buildGeometry(mesh: mesh, layout: layout)

        let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
        let sampler = ColorSampler(cloud: cloud, cell: max(spacing * 2.5, 0.004))

        var pixels = [UInt8](repeating: 0, count: layout.texSize * layout.texSize * 4)
        for t in 0..<triCount {
            let w0 = geometry.mesh.vertices[t * 3]
            let w1 = geometry.mesh.vertices[t * 3 + 1]
            let w2 = geometry.mesh.vertices[t * 3 + 2]
            TextureAtlas.forEachTexel(corners: layout.corners(of: t),
                                      texSize: layout.texSize) { px, py, l0, l1, l2 in
                let world = w0 * l0 + w1 * l1 + w2 * l2
                TextureAtlas.write(sampler.color(at: world), x: px, y: py,
                                   texSize: layout.texSize, into: &pixels)
            }
        }

        TextureAtlas.fillGutters(pixels: &pixels, size: layout.texSize)
        guard let png = TextureAtlas.encodePNG(pixels: pixels, size: layout.texSize) else {
            return nil
        }
        return TexturedMesh(mesh: geometry.mesh, uvs: geometry.uvs,
                            texturePNG: png, textureSize: layout.texSize)
    }

    // MARK: - Cloud colour sampling

    /// Inverse-distance-weighted colour of the nearest scan points (3×3×3 hash
    /// block); falls back to neutral grey far from any point. Also used by the
    /// photo baker for triangles no keyframe can see.
    struct ColorSampler {
        let cell: Float
        let positions: [SIMD3<Float>]
        let colors: [SIMD3<Float>]
        private var buckets: [SIMD3<Int32>: [Int]] = [:]

        init(cloud: PointCloud, cell: Float) {
            self.cell = max(cell, 1e-4)
            self.positions = cloud.positions
            self.colors = cloud.colors
            buckets.reserveCapacity(cloud.count)
            for (i, p) in positions.enumerated() { buckets[key(p), default: []].append(i) }
        }

        private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }

        func color(at p: SIMD3<Float>) -> SIMD3<Float> {
            let base = key(p)
            var weightSum: Float = 0
            var colorSum = SIMD3<Float>.zero
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        guard let bucket = buckets[base &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                        for i in bucket {
                            let d2 = simd_distance_squared(positions[i], p)
                            let w = 1 / (d2 + 1e-6)
                            weightSum += w
                            colorSum += colors[i] * w
                        }
                    }
                }
            }
            guard weightSum > 0 else { return SIMD3<Float>(repeating: 0.6) }
            return colorSum / weightSum
        }
    }
}
