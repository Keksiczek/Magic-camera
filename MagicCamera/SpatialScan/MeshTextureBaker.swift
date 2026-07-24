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

/// A mesh with per-vertex UVs and a baked colour atlas.
///
/// The atlas may span several `textureSize`² PAGES. A single sheet is a pure
/// area accountant — its texel density is bounded by
/// `textureSize · √(packEfficiency / surfaceArea)` however well the charts pack —
/// so a large room is blurred by the texture no matter how good the unwrap.
/// N pages buy √N of that ceiling back (see `AtlasLayout.pageCount`).
///
/// UVs stay normalised within a triangle's OWN page, so geometry is identical
/// whatever the page count; `pageOfTri` says which image each triangle samples.
/// Most meshes are single-page and leave `pageOfTri` empty.
struct TexturedMesh: Sendable {
    var mesh: MeshData
    var uvs: [SIMD2<Float>]
    /// One encoded atlas image per page, in page order. Never empty.
    var textures: [Data]
    var textureSize: Int
    /// Page index per TRIANGLE (`mesh.indices.count / 3` entries). Empty means
    /// single-page — every triangle samples `textures[0]`.
    var pageOfTri: [UInt8]

    /// Single-page atlas — the common case, and the shape every non-scan
    /// producer (Studio, USDZ import) still uses.
    init(mesh: MeshData, uvs: [SIMD2<Float>], texturePNG: Data, textureSize: Int) {
        self.init(mesh: mesh, uvs: uvs, textures: [texturePNG],
                  textureSize: textureSize, pageOfTri: [])
    }

    init(mesh: MeshData, uvs: [SIMD2<Float>], textures: [Data],
         textureSize: Int, pageOfTri: [UInt8]) {
        self.mesh = mesh
        self.uvs = uvs
        self.textures = textures.isEmpty ? [Data()] : textures
        self.textureSize = textureSize
        // A page map is meaningless without pages to choose between, and every
        // consumer treats "empty" as the fast single-page path.
        self.pageOfTri = self.textures.count > 1 ? pageOfTri : []
    }

    var pageCount: Int { textures.count }

    /// The first page. Correct wherever a single image is genuinely all that is
    /// wanted (a thumbnail, a change stamp); consumers that RENDER or STORE the
    /// atlas must walk `textures` instead, or they silently drop pages 1…N.
    var texturePNG: Data { textures[0] }

    /// Which page triangle `t` samples.
    func page(of t: Int) -> Int {
        pageOfTri.isEmpty ? 0 : Int(pageOfTri[t])
    }

    /// Encoded size of the whole atlas across pages.
    var textureBytes: Int { textures.reduce(0) { $0 + $1.count } }

    /// Page per VERTEX, for consumers that walk UVs rather than triangles.
    /// Baked meshes are duplicated-corner soup, so each vertex belongs to
    /// exactly one triangle and the mapping is exact; on a welded mesh a vertex
    /// shared across pages takes the last triangle's page, which is the best any
    /// per-vertex UV can do (such a mesh cannot be paged coherently anyway).
    /// Empty for a single-page atlas.
    func pageOfVertex() -> [UInt8] {
        let triCount = mesh.indices.count / 3
        guard pageCount > 1, pageOfTri.count == triCount else { return [] }
        var pages = [UInt8](repeating: 0, count: mesh.vertices.count)
        for t in 0..<triCount {
            for k in 0..<3 {
                let v = Int(mesh.indices[t * 3 + k])
                if v < pages.count { pages[v] = pageOfTri[t] }
            }
        }
        return pages
    }

    /// Triangle indices grouped by page, in page order — the partition the
    /// exporters turn into one material (SceneKit element / glTF primitive) per
    /// page. Single-page meshes get one group holding every triangle.
    func trianglesByPage() -> [[UInt32]] {
        let triCount = mesh.indices.count / 3
        guard pageCount > 1, pageOfTri.count == triCount else {
            return [Array(0..<UInt32(max(triCount, 0)))]
        }
        var groups = [[UInt32]](repeating: [], count: pageCount)
        for t in 0..<triCount {
            let p = min(Int(pageOfTri[t]), pageCount - 1)
            groups[p].append(UInt32(t))
        }
        return groups
    }
}

enum MeshTextureBaker {
    /// Bakes `cloud`'s colours onto `mesh`. Returns nil for empty input or when
    /// PNG encoding fails. Heavy (CPU rasterisation) — run off the main thread.
    static func bake(mesh: MeshData, cloud: PointCloud,
                     textureSize requested: Int? = nil) -> TexturedMesh? {
        let triCount = mesh.indices.count / 3
        guard triCount > 0, !cloud.isEmpty else { return nil }

        // True UV unwrap when it packs (contiguous charts — continuous texture,
        // editable export); per-triangle area-adaptive grid as the fallback.
        // 4096 ceiling — cloud colour is coarse, so the surface path's higher
        // ceiling isn't worth the memory here.
        let layout: any AtlasLayout = ChartAtlas.build(mesh: mesh,
                                                       maxTexSize: requested ?? 4096)
            ?? TextureAtlas.Layout(triangleCount: triCount, requested: requested,
                                   surfaceArea: mesh.surfaceArea())
        let geometry = TextureAtlas.buildGeometry(mesh: mesh, layout: layout)

        let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
        let sampler = ColorSampler(cloud: cloud, cell: max(spacing * 1.5, 0.004))

        var pixels = [UInt8](repeating: 0, count: layout.texSize * layout.texSize * 4)
        let grey = SIMD3<Float>(repeating: 0.6)
        for t in 0..<triCount {
            let w0 = geometry.mesh.vertices[t * 3]
            let w1 = geometry.mesh.vertices[t * 3 + 1]
            let w2 = geometry.mesh.vertices[t * 3 + 2]
            // Colour for texels that miss the cloud (a fanned hole patch, or a far
            // wall coarser than the sampler cell): the widening search, else the
            // mean of the triangle's corners — anything but the flat grey that
            // otherwise flaked across the surface.
            var corner = SIMD3<Float>.zero
            var found: Float = 0
            for c in [w0, w1, w2] where sampler.colorIfAny(at: c) != nil {
                corner += sampler.colorIfAny(at: c)!; found += 1
            }
            let cornerColor = found > 0 ? corner / found : grey
            TextureAtlas.forEachTexel(corners: layout.corners(of: t),
                                      texSize: layout.texSize) { px, py, l0, l1, l2 in
                let world = w0 * l0 + w1 * l1 + w2 * l2
                let color = sampler.nearestColor(at: world) ?? cornerColor
                TextureAtlas.write(color, x: px, y: py,
                                   texSize: layout.texSize, into: &pixels)
            }
        }

        TextureAtlas.fillGutters(pixels: &pixels, size: layout.texSize)
        guard let atlas = TextureAtlas.encodeAtlas(pixels: pixels, size: layout.texSize) else {
            return nil
        }
        return TexturedMesh(mesh: geometry.mesh, uvs: geometry.uvs,
                            texturePNG: atlas, textureSize: layout.texSize)
    }

    // MARK: - Cloud colour sampling

    /// Colour of the nearest scan points (3×3×3 hash block), weighted by inverse
    /// FOURTH power of distance so the single closest point dominates — the fused
    /// cloud is already sharp (the user's point-cloud view is crisp), and a gentle
    /// inverse-square average smeared that detail across ~a cell when this bakes
    /// the fallback texels a keyframe couldn't reach (the "mesh softer than the
    /// cloud" gap). Falls back to neutral grey far from any point. Also used by the
    /// photo baker for triangles / texels no keyframe can see.
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
            colorIfAny(at: p) ?? SIMD3<Float>(repeating: 0.6)
        }

        /// Cloud colour at `p` searching `rings` cells around it, or nil when the
        /// cloud has no point in reach. Callers that can supply a better local
        /// colour (e.g. a triangle's own corners, which sit on real geometry even
        /// when its interior spans a filled gap) should prefer this over
        /// `color(at:)` — the flat 0.6 grey it otherwise returns is what painted
        /// the scattered grey specks across a clean wall.
        func colorIfAny(at p: SIMD3<Float>, rings: Int32 = 1) -> SIMD3<Float>? {
            let base = key(p)
            var weightSum: Float = 0
            var colorSum = SIMD3<Float>.zero
            for dz in -rings...rings {
                for dy in -rings...rings {
                    for dx in -rings...rings {
                        guard let bucket = buckets[base &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                        for i in bucket {
                            let d2 = simd_distance_squared(positions[i], p)
                            // Inverse 4th power → the nearest point dominates, so
                            // the texture keeps the cloud's crispness instead of
                            // averaging neighbours into a blur.
                            let w = 1 / (d2 * d2 + 1e-12)
                            weightSum += w
                            colorSum += colors[i] * w
                        }
                    }
                }
            }
            guard weightSum > 0 else { return nil }
            return colorSum / weightSum
        }

        /// Cloud colour at `p`, widening the search until points are found. The
        /// cell is sized from the cloud's MEAN spacing, but distance-adaptive voxel
        /// coarsening leaves far surfaces up to `adaptiveVoxelMaxMultiplier`× (4×)
        /// sparser than that — so on a far wall the one-ring lookup finds nothing
        /// and the caller fell back to a flat grey (2.6% of a device room's atlas
        /// baked as exactly 0.6 grey: the "mikroděry" specks). Escalating rings
        /// costs nothing on the dense majority and always returns a real colour on
        /// the sparse minority. nil only for a genuinely empty region.
        func nearestColor(at p: SIMD3<Float>) -> SIMD3<Float>? {
            var rings: Int32 = 1
            while rings <= 8 {
                if let color = colorIfAny(at: p, rings: rings) { return color }
                rings *= 2
            }
            return nil
        }
    }
}
