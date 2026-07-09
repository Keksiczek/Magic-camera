//
//  PhotoTextureBaker.swift
//  Magic Camera
//
//  Photo texturing: bakes the camera keyframes captured during the scan onto a
//  reconstructed mesh. Far sharper than point-cloud colours — texels sample
//  the actual photos.
//
//    Pass 1: each triangle picks its best keyframe (facing angle × distance
//            from the image border, with a depth-map occlusion test).
//    Pass 2: triangles are baked grouped by keyframe, so only one decoded
//            photo is in memory at a time; texels project into the photo and
//            sample bilinearly. Unseen triangles fall back to cloud colours.
//
//  Chart layout / UVs / PNG come from TextureAtlas (shared with the cloud baker).
//

import CoreGraphics
import Foundation
import ImageIO
import simd

enum PhotoTextureBaker {
    /// Atlas ceiling for the single-best-view (GPU) path that surface/room scans
    /// take. A big room's texture is spread across the whole atlas, so a fixed 6144²
    /// (144 MB GPU buffer + a matching readback) leaves a large room soft ("mazle").
    /// On a high-memory device (≈8 GB, e.g. iPhone 15 Pro+) raise it to 8192² (256 MB)
    /// for ~1.8× the texels-per-metre; lower-memory devices keep 6144² so the transient
    /// bake buffers can't OOM. Still a bounded one-shot review-time bake. The
    /// memory-bound multi-view object path keeps its own much lower cap.
    private static let surfaceAtlasCap: Int =
        ProcessInfo.processInfo.physicalMemory > 7_000_000_000 ? 8192 : 6144

    /// Bakes keyframe photos onto `mesh`. `fallbackCloud` colours triangles no
    /// keyframe can see. Heavy — run off the main thread.
    static func bake(mesh: MeshData, keyframes: [ScanKeyframe],
                     fallbackCloud: PointCloud?,
                     textureSize requested: Int? = nil,
                     smoothLighting: Bool = false,
                     delight: Bool = false,
                     areaProportional: Bool = false) -> TexturedMesh? {
        let triCount = mesh.indices.count / 3
        guard triCount > 0, !keyframes.isEmpty else { return nil }

        // Even-lighting path: blend every view that sees each triangle so no
        // single view's specular highlight or shadow is baked in. Used by the
        // object one-tap; falls through to the fast single-best-view bake if it
        // produces nothing.
        if smoothLighting,
           let blended = bakeMultiView(mesh: mesh, keyframes: keyframes,
                                       fallbackCloud: fallbackCloud, requested: requested) {
            return blended
        }

        // Surface/room bakes earn a larger atlas (adaptive, by physical area) so
        // big triangles aren't washed out; small objects stay at the px/cell
        // baseline and never reach the raised ceiling. The variable-resolution
        // path instead sizes each triangle's chart by √area (area-proportional),
        // so a coarse wall triangle gets proportionally more texels and stays sharp.
        let layout: any AtlasLayout = areaProportional
            ? AreaProportionalAtlas.build(mesh: mesh, maxTexSize: surfaceAtlasCap)
            : TextureAtlas.Layout(triangleCount: triCount, requested: requested,
                                  surfaceArea: mesh.surfaceArea(),
                                  maxTexSize: surfaceAtlasCap)
        let atlasKind = areaProportional ? " · area-prop" : ""
        let geometry = TextureAtlas.buildGeometry(mesh: mesh, layout: layout)
        let views = makeViews(keyframes)

        // Pass 1 — best keyframe per triangle. Each triangle is independent and
        // writes only its own slot, so this runs in parallel across cores — it is
        // the bulk of the CPU bake cost on a big surface (triCount × keyframes
        // scorings, each with a depth occlusion sample). `View.score` only reads
        // immutable keyframe data, so concurrent scoring is safe. Cancellation is
        // checked at the pass boundaries (GCD workers aren't in the Task context).
        if Task.isCancelled { return nil }
        var bestView = [Int](repeating: -1, count: triCount)
        let vertices = geometry.mesh.vertices          // [SIMD3<Float>] is Sendable
        let viewsBox = UncheckedSendableBox(views)     // View Sendability unknown → box
        bestView.withUnsafeMutableBufferPointer { buf in
            let out = UncheckedSendableBox(buf.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: triCount) { t in
                let w0 = vertices[t * 3], w1 = vertices[t * 3 + 1], w2 = vertices[t * 3 + 2]
                let normalRaw = simd_cross(w1 - w0, w2 - w0)
                let nLen = simd_length(normalRaw)
                guard nLen > 1e-12 else { return }
                let normal = normalRaw / nLen
                let center = (w0 + w1 + w2) / 3
                let vs = viewsBox.value
                var bestScore: Float = 0.05
                var best = -1
                for k in 0..<vs.count {
                    guard let score = vs[k].score(center: center, normal: normal),
                          score > bestScore else { continue }
                    bestScore = score
                    best = k
                }
                out.value[t] = best
            }
        }
        if Task.isCancelled { return nil }
        // Pass 1.5 — view-consistency smoothing. Independent per-triangle picks
        // produce a patchwork: adjacent wall triangles baked from different
        // keyframes carry each photo's exposure/shading, so every view border is
        // a visible luminance seam ("the sides don't fit together"). Growing
        // single-view islands removes most borders outright; the seam leveler
        // then only has the few real ones left to blend.
        smoothViewAssignment(&bestView, mesh: mesh, atlasVertices: vertices, views: views)
        if Task.isCancelled { return nil }

        // GPU Pass 2 (one thread per triangle) when enabled and available.
        // Pass 1 + the per-keyframe exposure gain stay on the CPU; the heavy
        // per-texel projection/sampling runs on the GPU. Falls back below.
        if GPUSettings.textureBakeEnabled {
            if Task.isCancelled { return nil }
            // Slice size scales with keyframe count so the hi-res keyframes aren't
            // squashed to 1024² (the softness ceiling) while the array stays under
            // its memory budget.
            let slice = GPUTextureBaker.sliceSize(forKeyframeCount: keyframes.count)
            // Even-lighting multi-view first (only surface/room bakes reach here —
            // the object path already took the CPU multi-view above). Blends the
            // top facing-weighted views per texel, each normalised to the fused
            // cloud albedo, so the colour is anchored to the SCENE rather than one
            // photo's exposure — this is what removes the view-border seams ("švy")
            // and the soft cloud-repaint patches, not just the single-view bake.
            if let textured = bakeSurfaceMultiViewGPU(
                geometry: geometry, keyframes: keyframes, views: views,
                fallbackCloud: fallbackCloud, layout: layout,
                slicePixels: slice, atlasKind: atlasKind) {
                return textured
            }
            // Fallback: single-best-view GPU bake.
            let used = Set(bestView.filter { $0 >= 0 })
            let gains: [SIMD3<Float>] = views.enumerated().map { i, view in
                guard used.contains(i), let cloud = fallbackCloud,
                      let photo = DecodedPhoto(jpeg: keyframes[i].jpeg) else {
                    return SIMD3<Float>(repeating: 1)
                }
                return exposureGain(view: view, photo: photo, cloud: cloud)
            }
            if var gpuPixels = GPUTextureBaker.bake(geometry: geometry, bestView: bestView,
                                                    keyframes: keyframes, gains: gains,
                                                    texSize: layout.texSize, slicePixels: slice) {
                paintFallbackTriangles(into: &gpuPixels, geometry: geometry, bestView: bestView,
                                       layout: layout, fallbackCloud: fallbackCloud)
                let repaired = repairUnwrittenTexels(into: &gpuPixels, geometry: geometry,
                                                     bestView: bestView, layout: layout,
                                                     fallbackCloud: fallbackCloud)
                TextureSeamLeveler.level(pixels: &gpuPixels, size: layout.texSize,
                                         geometry: geometry, layout: layout)
                if delight {
                    TextureDelighter.delight(pixels: &gpuPixels, size: layout.texSize,
                                             geometry: geometry, layout: layout)
                }
                TextureAtlas.fillGutters(pixels: &gpuPixels, size: layout.texSize)
                if let png = TextureAtlas.encodePNG(pixels: gpuPixels, size: layout.texSize) {
                    Diagnostics.shared.gpu("texture-bake", used: true,
                                           "\(triCount) tris · atlas \(layout.texSize)²\(atlasKind)"
                                           + " · slice \(slice)² · repaired \(repaired)")
                    return TexturedMesh(mesh: geometry.mesh, uvs: geometry.uvs,
                                        texturePNG: png, textureSize: layout.texSize)
                }
            }
        }
        Diagnostics.shared.gpu("texture-bake", used: false,
                               "\(triCount) tris · atlas \(layout.texSize)²\(atlasKind)")

        // Pass 2 — bake grouped by keyframe (one decoded photo at a time).
        var pixels = [UInt8](repeating: 0, count: layout.texSize * layout.texSize * 4)
        let fallback: MeshTextureBaker.ColorSampler? = fallbackCloud.map { cloud in
            let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
            return MeshTextureBaker.ColorSampler(cloud: cloud, cell: max(spacing * 1.5, 0.004))
        }
        let fallbackColor = SIMD3<Float>(repeating: 0.6)

        var byView: [Int: [Int]] = [:]
        for (t, k) in bestView.enumerated() { byView[k, default: []].append(t) }

        for (k, triangles) in byView {
            if Task.isCancelled { return nil }
            let photo: DecodedPhoto? = k >= 0 ? DecodedPhoto(jpeg: keyframes[k].jpeg) : nil
            let view: View? = k >= 0 ? views[k] : nil
            // Exposure harmonisation: keyframes were shot at (potentially)
            // different exposures; the fused cloud colour is the cross-frame
            // average and acts as the neutral reference each photo is matched to.
            var gain = SIMD3<Float>(repeating: 1)
            if let photo, let view, let cloud = fallbackCloud {
                gain = Self.exposureGain(view: view, photo: photo, cloud: cloud)
            }
            for t in triangles {
                let w0 = geometry.mesh.vertices[t * 3]
                let w1 = geometry.mesh.vertices[t * 3 + 1]
                let w2 = geometry.mesh.vertices[t * 3 + 2]
                TextureAtlas.forEachTexel(corners: layout.corners(of: t),
                                          texSize: layout.texSize) { px, py, l0, l1, l2 in
                    let world = w0 * l0 + w1 * l1 + w2 * l2
                    var color: SIMD3<Float>?
                    if let view, let photo, let uv = view.projectNormalized(world) {
                        color = simd_clamp(photo.sample(u: uv.x, v: uv.y) * gain,
                                           SIMD3<Float>.zero, SIMD3<Float>.one)
                    }
                    let final = color ?? fallback?.color(at: world) ?? fallbackColor
                    TextureAtlas.write(final, x: px, y: py,
                                       texSize: layout.texSize, into: &pixels)
                }
            }
        }

        TextureSeamLeveler.level(pixels: &pixels, size: layout.texSize,
                                 geometry: geometry, layout: layout)
        if delight {
            TextureDelighter.delight(pixels: &pixels, size: layout.texSize,
                                     geometry: geometry, layout: layout)
        }
        TextureAtlas.fillGutters(pixels: &pixels, size: layout.texSize)
        guard let png = TextureAtlas.encodePNG(pixels: pixels, size: layout.texSize) else {
            return nil
        }
        return TexturedMesh(mesh: geometry.mesh, uvs: geometry.uvs,
                            texturePNG: png, textureSize: layout.texSize)
    }

    /// Even-lighting bake: every keyframe that sees a triangle contributes to its
    /// texels, facing-weighted, instead of one "best" view winning. Averaging
    /// Grows single-view islands out of the per-triangle best-view picks: a
    /// triangle whose neighbours agree on a different view adopts it when that
    /// view still sees it nearly as well (≥ 0.7× its own best score). Runs on the
    /// welded source indices — on a duplicated-corner (soup) mesh every edge is
    /// unique, no neighbours are found, and this is a clean no-op.
    private static func smoothViewAssignment(_ bestView: inout [Int], mesh: MeshData,
                                             atlasVertices: [SIMD3<Float>], views: [View]) {
        let triCount = bestView.count
        guard triCount > 8, views.count > 1, mesh.indices.count >= triCount * 3 else { return }
        // Shared-edge adjacency: up to 3 neighbours per triangle.
        var neighbors = [Int32](repeating: -1, count: triCount * 3)
        var owner: [UInt64: (tri: Int32, slot: Int32)] = [:]
        owner.reserveCapacity(triCount * 3)
        @inline(__always) func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
            a < b ? ((UInt64(a) << 32) | UInt64(b)) : ((UInt64(b) << 32) | UInt64(a))
        }
        for t in 0..<triCount {
            let a = mesh.indices[t * 3], b = mesh.indices[t * 3 + 1], c = mesh.indices[t * 3 + 2]
            let keys = (edgeKey(a, b), edgeKey(b, c), edgeKey(c, a))
            for (slot, k) in [keys.0, keys.1, keys.2].enumerated() {
                if let o = owner[k] {
                    neighbors[t * 3 + slot] = o.tri
                    neighbors[Int(o.tri) * 3 + Int(o.slot)] = Int32(t)
                } else {
                    owner[k] = (Int32(t), Int32(slot))
                }
            }
        }
        for _ in 0..<2 {
            var changed = 0
            for t in 0..<triCount {
                let current = bestView[t]
                guard current >= 0 else { continue }
                // A candidate view must be shared by ≥2 of the (≤3) neighbours.
                var v0 = -1, v1 = -1, v2 = -1
                if neighbors[t * 3] >= 0 { v0 = bestView[Int(neighbors[t * 3])] }
                if neighbors[t * 3 + 1] >= 0 { v1 = bestView[Int(neighbors[t * 3 + 1])] }
                if neighbors[t * 3 + 2] >= 0 { v2 = bestView[Int(neighbors[t * 3 + 2])] }
                var candidate = -1
                if v0 >= 0 && (v0 == v1 || v0 == v2) { candidate = v0 }
                else if v1 >= 0 && v1 == v2 { candidate = v1 }
                guard candidate >= 0, candidate != current else { continue }
                let w0 = atlasVertices[t * 3]
                let w1 = atlasVertices[t * 3 + 1]
                let w2 = atlasVertices[t * 3 + 2]
                let normalRaw = simd_cross(w1 - w0, w2 - w0)
                let nLen = simd_length(normalRaw)
                guard nLen > 1e-12 else { continue }
                let normal = normalRaw / nLen
                let center = (w0 + w1 + w2) / 3
                guard let candScore = views[candidate].score(center: center, normal: normal)
                else { continue }
                let myScore = views[current].score(center: center, normal: normal) ?? 0.05
                if candScore >= myScore * 0.7 {
                    bestView[t] = candidate
                    changed += 1
                }
            }
            if changed == 0 { break }
        }
    }

    /// across views cancels view-dependent lighting — a specular glint or one
    /// view's shadow fades out — for a flatter, seam-free, more albedo-like
    /// texture than single-best-view photogrammetry. Pure CPU: one decoded photo
    /// in memory at a time plus one accumulator buffer (the atlas is capped so
    /// that stays bounded). Returns nil if nothing usable was produced.
    private static func bakeMultiView(mesh: MeshData, keyframes: [ScanKeyframe],
                                      fallbackCloud: PointCloud?,
                                      requested: Int?) -> TexturedMesh? {
        let triCount = mesh.indices.count / 3
        guard triCount > 0, !keyframes.isEmpty else { return nil }
        // Cap the atlas so the per-texel SIMD4 accumulator stays bounded: 2048²
        // is ~64 MB; high-memory devices (≥7 GB, e.g. A18 Pro — the same gate the
        // 8192² surface bake ships behind without OOM) afford 4096² ≈ 256 MB for
        // 4× the texels on close-range object scans. Within the ceiling the
        // layout is still area-adaptive.
        let cap = ProcessInfo.processInfo.physicalMemory > 7_000_000_000 ? 4096 : 2048
        var layout = TextureAtlas.Layout(triangleCount: triCount, requested: requested,
                                         surfaceArea: mesh.surfaceArea(), maxTexSize: cap)
        if layout.texSize > cap {
            layout = TextureAtlas.Layout(triangleCount: triCount, requested: cap)
        } else if requested == nil, layout.texSize < 2048 {
            // Close-range object scans size the atlas from their tiny mean-triangle
            // area and land well under 2 K (a 0.3 m subject read 1552² — soft up
            // close). Objects are the whole point of this path, so give them the
            // full 2 K floor; the accumulator is ≤ 64 MB there regardless.
            layout = TextureAtlas.Layout(triangleCount: triCount, requested: min(2048, cap))
        }
        let geometry = TextureAtlas.buildGeometry(mesh: mesh, layout: layout)
        let views = makeViews(keyframes)

        // Pass 1 — top facing-weighted views per triangle (shared with the GPU
        // surface bake: near-as-good views only, squared weights so the best view
        // keeps detail while the runners-up cancel its specular/shadow).
        let maxViews = 4
        if Task.isCancelled { return nil }
        let candidates = computeViewCandidates(vertices: geometry.mesh.vertices,
                                               triCount: triCount, views: views, maxViews: maxViews)
        if Task.isCancelled { return nil }
        var byView: [Int: [Int]] = [:]
        for t in 0..<triCount {
            for c in candidates[t] { byView[c.view, default: []].append(t) }
        }

        // Pass 2 — accumulate facing-weighted colour per texel, one photo at a time.
        var accum = [SIMD4<Float>](repeating: SIMD4<Float>(repeating: 0),
                                   count: layout.texSize * layout.texSize)
        for (k, triangles) in byView {
            if Task.isCancelled { return nil }
            guard let photo = DecodedPhoto(jpeg: keyframes[k].jpeg) else { continue }
            let view = views[k]
            let gain = fallbackCloud.map { exposureGain(view: view, photo: photo, cloud: $0) }
                ?? SIMD3<Float>(repeating: 1)
            for t in triangles {
                let w0 = geometry.mesh.vertices[t * 3]
                let w1 = geometry.mesh.vertices[t * 3 + 1]
                let w2 = geometry.mesh.vertices[t * 3 + 2]
                let weight = candidates[t].first { $0.view == k }?.weight ?? 0.1
                TextureAtlas.forEachTexel(corners: layout.corners(of: t),
                                          texSize: layout.texSize) { px, py, l0, l1, l2 in
                    let world = w0 * l0 + w1 * l1 + w2 * l2
                    guard let uv = view.projectNormalized(world) else { return }
                    let c = simd_clamp(photo.sample(u: uv.x, v: uv.y) * gain,
                                       SIMD3<Float>.zero, SIMD3<Float>.one)
                    accum[py * layout.texSize + px] += SIMD4<Float>(c.x * weight, c.y * weight,
                                                                    c.z * weight, weight)
                }
            }
        }

        // Resolve — divide the accumulator; texels no view reached fall back to
        // the fused cloud colour (same fallback as the single-view bake).
        var pixels = [UInt8](repeating: 0, count: layout.texSize * layout.texSize * 4)
        let fallback: MeshTextureBaker.ColorSampler? = fallbackCloud.map { cloud in
            let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
            return MeshTextureBaker.ColorSampler(cloud: cloud, cell: max(spacing * 1.5, 0.004))
        }
        let fallbackColor = SIMD3<Float>(repeating: 0.6)
        for t in 0..<triCount {
            if t % 8192 == 0, Task.isCancelled { return nil }
            let w0 = geometry.mesh.vertices[t * 3]
            let w1 = geometry.mesh.vertices[t * 3 + 1]
            let w2 = geometry.mesh.vertices[t * 3 + 2]
            TextureAtlas.forEachTexel(corners: layout.corners(of: t),
                                      texSize: layout.texSize) { px, py, l0, l1, l2 in
                let a = accum[py * layout.texSize + px]
                let color: SIMD3<Float>
                if a.w > 1e-5 {
                    color = SIMD3<Float>(a.x, a.y, a.z) / a.w
                } else {
                    let world = w0 * l0 + w1 * l1 + w2 * l2
                    color = fallback?.color(at: world) ?? fallbackColor
                }
                TextureAtlas.write(color, x: px, y: py, texSize: layout.texSize, into: &pixels)
            }
        }

        TextureSeamLeveler.level(pixels: &pixels, size: layout.texSize,
                                 geometry: geometry, layout: layout)
        TextureAtlas.fillGutters(pixels: &pixels, size: layout.texSize)
        guard let png = TextureAtlas.encodePNG(pixels: pixels, size: layout.texSize) else {
            return nil
        }
        Diagnostics.shared.log("texture-bake",
                               "multi-view · \(triCount) tris · \(views.count) views · atlas \(layout.texSize)²")
        return TexturedMesh(mesh: geometry.mesh, uvs: geometry.uvs,
                            texturePNG: png, textureSize: layout.texSize)
    }

    /// Top facing-weighted candidate views per triangle, shared by the CPU
    /// even-lighting bake and the GPU surface multi-view bake so the two stay
    /// identical. A view qualifies if it sees the triangle well (score ≥ 0.75× the
    /// best — near-as-good views only, so blending doesn't smear detail), capped at
    /// `maxViews`; the weight is the score squared so the best view dominates while
    /// the runners-up mostly cancel its view-dependent lighting. Parallel: each
    /// triangle writes only its own slot.
    private static func computeViewCandidates(vertices: [SIMD3<Float>], triCount: Int,
                                              views: [View], maxViews: Int)
        -> [[(view: Int, weight: Float)]] {
        var candidates = [[(view: Int, weight: Float)]](repeating: [], count: triCount)
        guard triCount > 0, !views.isEmpty else { return candidates }
        let viewsBox = UncheckedSendableBox(views)
        candidates.withUnsafeMutableBufferPointer { buf in
            let out = UncheckedSendableBox(buf.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: triCount) { t in
                let w0 = vertices[t * 3], w1 = vertices[t * 3 + 1], w2 = vertices[t * 3 + 2]
                let normalRaw = simd_cross(w1 - w0, w2 - w0)
                let nLen = simd_length(normalRaw)
                guard nLen > 1e-12 else { return }
                let normal = normalRaw / nLen
                let center = (w0 + w1 + w2) / 3
                let vs = viewsBox.value
                var scored: [(view: Int, weight: Float)] = []
                for k in 0..<vs.count {
                    if let s = vs[k].score(center: center, normal: normal), s > 0.05 {
                        scored.append((view: k, weight: s))
                    }
                }
                guard let best = scored.map(\.weight).max() else { return }
                out.value[t] = scored.filter { $0.weight >= best * 0.75 }
                                     .sorted { $0.weight > $1.weight }
                                     .prefix(maxViews)
                                     .map { (view: $0.view, weight: $0.weight * $0.weight) }
            }
        }
        return candidates
    }

    /// Even-lighting bake for a surface/room on the GPU: blends the top
    /// facing-weighted views per texel (each exposure-normalised to the fused
    /// cloud) with occlusion, so the colour is anchored to the scene's albedo, not
    /// one photo's exposure — no view-border seams, no soft cloud patches where a
    /// single best-view didn't reach. Triangles no view sees and the few unseen
    /// texels still fall back to cloud colours. Returns nil (caller falls through
    /// to the single-view bake) on any GPU failure.
    private static func bakeSurfaceMultiViewGPU(geometry: TextureAtlas.Geometry,
                                                keyframes: [ScanKeyframe], views: [View],
                                                fallbackCloud: PointCloud?,
                                                layout: some AtlasLayout,
                                                slicePixels: Int, atlasKind: String) -> TexturedMesh? {
        let triCount = geometry.uvs.count / 3
        guard triCount > 0, views.count == keyframes.count else { return nil }
        let maxViews = 4
        if Task.isCancelled { return nil }
        let candidates = computeViewCandidates(vertices: geometry.mesh.vertices,
                                               triCount: triCount, views: views, maxViews: maxViews)
        if Task.isCancelled { return nil }
        // Exposure gain for EVERY view (each candidate is normalised to the cloud
        // albedo, so blending views can't introduce an exposure step).
        let gains: [SIMD3<Float>] = views.enumerated().map { i, view in
            guard let cloud = fallbackCloud, let photo = DecodedPhoto(jpeg: keyframes[i].jpeg) else {
                return SIMD3<Float>(repeating: 1)
            }
            return exposureGain(view: view, photo: photo, cloud: cloud)
        }
        if Task.isCancelled { return nil }
        guard var pixels = GPUTextureBaker.bakeMultiView(
            geometry: geometry, candidates: candidates, keyframes: keyframes,
            gains: gains, texSize: layout.texSize, slicePixels: slicePixels, maxViews: maxViews)
        else { return nil }
        // A triangle with ≥1 candidate is "assigned"; the rest (and any unseen
        // texel the GPU left transparent) get the cloud fallback, same as the
        // single-view path.
        let assignedView = candidates.map { $0.first?.view ?? -1 }
        // Photo coverage telemetry: triangles no keyframe saw at all get the whole
        // face cloud-painted (`unseen`); `repaired` is the residual texels inside
        // *seen* triangles the GPU left transparent. Together they say how much of
        // the surface is real photo vs cloud speckle — the "not-great texture"
        // signal, and the lever to watch when tuning keyframe density / occlusion.
        let unseen = assignedView.reduce(0) { $0 + ($1 < 0 ? 1 : 0) }
        paintFallbackTriangles(into: &pixels, geometry: geometry, bestView: assignedView,
                               layout: layout, fallbackCloud: fallbackCloud)
        let repaired = repairUnwrittenTexels(into: &pixels, geometry: geometry,
                                             bestView: assignedView, layout: layout,
                                             fallbackCloud: fallbackCloud)
        TextureSeamLeveler.level(pixels: &pixels, size: layout.texSize,
                                 geometry: geometry, layout: layout)
        TextureAtlas.fillGutters(pixels: &pixels, size: layout.texSize)
        guard let png = TextureAtlas.encodePNG(pixels: pixels, size: layout.texSize) else { return nil }
        Diagnostics.shared.gpu("texture-bake", used: true,
                               "multi-view · \(triCount) tris · atlas \(layout.texSize)²\(atlasKind)"
                               + " · slice \(slicePixels)² · unseen \(unseen)/\(triCount) · repaired \(repaired)")
        return TexturedMesh(mesh: geometry.mesh, uvs: geometry.uvs,
                            texturePNG: png, textureSize: layout.texSize)
    }

    /// Paints the triangles no keyframe could see (GPU left them transparent)
    /// with cloud colours — the same fallback the CPU Pass 2 applies.
    /// The GPU bake kernel skips a texel whose projection falls outside its
    /// keyframe's frame or behind the camera — legal for a triangle whose CENTRE
    /// scored fine — and the atlas buffer starts zeroed, so those texels stay
    /// RGBA(0,0,0,0): the scattered black triangles on otherwise healthy walls
    /// ("holes despite green density"). Alpha 0 marks exactly "never written";
    /// repaint those from the cloud like the unseen-triangle fallback. The CPU
    /// bake path doesn't need this — its per-texel sampler already falls back.
    /// Returns how many texels were repainted — surfaced on the bake breadcrumb
    /// so a device diagnostic can distinguish "the repair never engaged" from
    /// "the black comes from somewhere else entirely".
    @discardableResult
    private static func repairUnwrittenTexels(into pixels: inout [UInt8],
                                              geometry: TextureAtlas.Geometry,
                                              bestView: [Int],
                                              layout: some AtlasLayout,
                                              fallbackCloud: PointCloud?) -> Int {
        let fallback: MeshTextureBaker.ColorSampler? = fallbackCloud.map { cloud in
            let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
            return MeshTextureBaker.ColorSampler(cloud: cloud, cell: max(spacing * 1.5, 0.004))
        }
        let fallbackColor = SIMD3<Float>(repeating: 0.6)
        let indices = (0..<bestView.count).filter { bestView[$0] >= 0 }
        guard !indices.isEmpty else { return 0 }
        let vertices = geometry.mesh.vertices
        let texSize = layout.texSize
        let idxBox = UncheckedSendableBox(indices)
        let sampBox = UncheckedSendableBox(fallback)
        var chunkCounts = [Int](repeating: 0, count: idxBox.value.count)
        pixels.withUnsafeMutableBufferPointer { buf in
            chunkCounts.withUnsafeMutableBufferPointer { counts in
                let out = UncheckedSendableBox(buf.baseAddress!)
                let countsOut = UncheckedSendableBox(counts.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: idxBox.value.count) { i in
                    let t = idxBox.value[i]
                    let w0 = vertices[t * 3], w1 = vertices[t * 3 + 1], w2 = vertices[t * 3 + 2]
                    let sampler = sampBox.value
                    let base = out.value
                    var repaired = 0
                    TextureAtlas.forEachTexel(corners: layout.corners(of: t), texSize: texSize) { px, py, l0, l1, l2 in
                        guard base[(py * texSize + px) * 4 + 3] == 0 else { return }
                        let world = w0 * l0 + w1 * l1 + w2 * l2
                        let color = sampler?.color(at: world) ?? fallbackColor
                        TextureAtlas.write(color, x: px, y: py, texSize: texSize, into: base)
                        repaired += 1
                    }
                    countsOut.value[i] = repaired
                }
            }
        }
        return chunkCounts.reduce(0, +)
    }

    private static func paintFallbackTriangles(into pixels: inout [UInt8],
                                               geometry: TextureAtlas.Geometry,
                                               bestView: [Int],
                                               layout: some AtlasLayout,
                                               fallbackCloud: PointCloud?) {
        let fallback: MeshTextureBaker.ColorSampler? = fallbackCloud.map { cloud in
            let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
            return MeshTextureBaker.ColorSampler(cloud: cloud, cell: max(spacing * 1.5, 0.004))
        }
        let fallbackColor = SIMD3<Float>(repeating: 0.6)
        // Parallel across the unseen triangles — each owns a disjoint atlas chart,
        // so concurrent texel writes never collide; the sampler is read-only.
        let indices = (0..<bestView.count).filter { bestView[$0] < 0 }
        guard !indices.isEmpty else { return }
        let vertices = geometry.mesh.vertices
        let texSize = layout.texSize
        let idxBox = UncheckedSendableBox(indices)
        let sampBox = UncheckedSendableBox(fallback)
        pixels.withUnsafeMutableBufferPointer { buf in
            let out = UncheckedSendableBox(buf.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: idxBox.value.count) { i in
                let t = idxBox.value[i]
                let w0 = vertices[t * 3], w1 = vertices[t * 3 + 1], w2 = vertices[t * 3 + 2]
                let sampler = sampBox.value
                TextureAtlas.forEachTexel(corners: layout.corners(of: t), texSize: texSize) { px, py, l0, l1, l2 in
                    let world = w0 * l0 + w1 * l1 + w2 * l2
                    let color = sampler?.color(at: world) ?? fallbackColor
                    TextureAtlas.write(color, x: px, y: py, texSize: texSize, into: out.value)
                }
            }
        }
    }

    /// Per-channel gain matching a keyframe photo to the fused cloud colours:
    /// sampled over cloud points the keyframe can see, ratio of mean colours.
    /// Internal so the GPU baker reuses the same exposure harmonisation.
    static func exposureGain(view: View, photo: DecodedPhoto,
                             cloud: PointCloud) -> SIMD3<Float> {
        var photoSum = SIMD3<Float>.zero
        var cloudSum = SIMD3<Float>.zero
        var count = 0
        let step = max(cloud.count / 400, 1)
        var i = 0
        while i < cloud.count {
            if let uv = view.projectNormalized(cloud.positions[i]) {
                photoSum += photo.sample(u: uv.x, v: uv.y)
                cloudSum += cloud.colors[i]
                count += 1
            }
            i += step
        }
        guard count >= 20 else { return SIMD3<Float>(repeating: 1) }
        let gain = (cloudSum / Float(count) + 0.02) / (photoSum / Float(count) + 0.02)
        return simd_clamp(gain, SIMD3<Float>(repeating: 0.6), SIMD3<Float>(repeating: 1.6))
    }

    // MARK: - Keyframe view (projection + scoring)

    /// Builds the views for a keyframe set with each one's sharpness folded into a
    /// relative blend weight, so the bake (best-view pick AND the multi-view blend)
    /// favours the crisp keyframes over the soft ones for the same triangle.
    static func makeViews(_ keyframes: [ScanKeyframe]) -> [View] {
        let sharps = keyframes.map(\.sharpness)
        let weights = KeyframeSharpness.weights(for: sharps)
        if let lo = sharps.min(), let hi = sharps.max() {
            Diagnostics.shared.log("keyframes",
                                   "\(keyframes.count) · sharp \(Int(lo))–\(Int(hi))")
        }
        return keyframes.enumerated().map { i, k in
            View(k, sharpnessWeight: weights.indices.contains(i) ? weights[i] : 1)
        }
    }

    /// Internal so the GPU baker reuses the exact projection + scoring.
    struct View {
        let keyframe: ScanKeyframe
        let worldToCamera: simd_float4x4
        let cameraPosition: SIMD3<Float>
        /// Relative sharpness weight (see `makeViews`); 1 = neutral.
        let sharpnessWeight: Float

        init(_ keyframe: ScanKeyframe, sharpnessWeight: Float = 1) {
            self.keyframe = keyframe
            self.worldToCamera = keyframe.cameraTransform.inverse
            let t = keyframe.cameraTransform.columns.3
            self.cameraPosition = SIMD3<Float>(t.x, t.y, t.z)
            self.sharpnessWeight = sharpnessWeight
        }

        /// Projects into depth-map pixels; nil when behind, outside or occluded.
        /// Inverse of the unprojection in ScanCompute: pc = (x, -y, -depth).
        func project(_ p: SIMD3<Float>) -> (u: Float, v: Float, depth: Float)? {
            let pc4 = worldToCamera * SIMD4<Float>(p, 1)
            let depth = -pc4.z
            guard depth > 0.05 else { return nil }
            let k = keyframe.intrinsics
            let u = pc4.x / depth * k[0][0] + k[2][0]
            let v = -pc4.y / depth * k[1][1] + k[2][1]
            guard u >= 1, v >= 1,
                  u < Float(keyframe.depthWidth - 1), v < Float(keyframe.depthHeight - 1)
            else { return nil }
            // Occlusion: the keyframe's own depth must roughly agree. The slack
            // scales with range — a fixed 12 cm was too tight for a room, where far
            // walls are seen at grazing angles and the 256×192 depth map has a steep
            // per-pixel gradient there, so genuine wall triangles were wrongly read
            // as occluded and fell back to noisy cloud colour (the room "repaired"
            // most texels). 12 cm near, growing to ≈16 cm at 4 m keeps real
            // foreground occlusion caught while letting deep walls keep their photo.
            let stored = keyframe.depth[Int(v) * keyframe.depthWidth + Int(u)]
            if stored > 0, depth > stored + max(0.12, depth * 0.04) { return nil }
            return (u, v, depth)
        }

        /// Projection normalised to [0,1]² across the photo.
        func projectNormalized(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            guard let (u, v, _) = project(p) else { return nil }
            return SIMD2<Float>(u / Float(keyframe.depthWidth),
                                v / Float(keyframe.depthHeight))
        }

        /// Visibility score for a triangle: facing angle × border margin.
        func score(center: SIMD3<Float>, normal: SIMD3<Float>) -> Float? {
            guard let (u, v, _) = project(center) else { return nil }
            let toCamera = simd_normalize(cameraPosition - center)
            // abs(): tolerate meshes whose normals ended up flipped locally.
            let facing = abs(simd_dot(normal, toCamera))
            guard facing > 0.15 else { return nil }
            let bx = min(u, Float(keyframe.depthWidth) - u) / Float(keyframe.depthWidth)
            let by = min(v, Float(keyframe.depthHeight) - v) / Float(keyframe.depthHeight)
            let border = min(min(bx, by) * 4, 1)   // fades within the outer quarter
            // Fold in the keyframe's sharpness so a soft photo loses to a crisp one
            // that sees the same triangle (and weighs less in the multi-view blend).
            return facing * (0.5 + 0.5 * border) * sharpnessWeight
        }
    }

    // MARK: - Decoded photo (bilinear sampling)

    /// Internal so the GPU baker reuses one decode for the texture upload.
    struct DecodedPhoto {
        let width: Int
        let height: Int
        let pixels: [UInt8]   // RGBA8

        // 1920 (was 1440): the CPU bake path and the exposure-gain estimate
        // sample from this decode, so a sharper decode means a crisper fallback
        // texture and tighter cross-keyframe exposure matching. Decoded one
        // keyframe at a time, so this is a bounded transient — not ×keyframes.
        init?(jpeg: Data, maxPixelSize: Int = 1920) {
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: false
                  ] as CFDictionary) else { return nil }
            let w = image.width
            let h = image.height
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            width = w
            height = h
            pixels = buffer
        }

        /// Bilinear sample at normalised coordinates. Drawing a CGImage into a
        /// bitmap context yields buffer row 0 = top scanline, matching the
        /// sensor's top-left (u, v) — no flip needed.
        func sample(u: Float, v: Float) -> SIMD3<Float> {
            let x = min(max(u, 0), 1) * Float(width - 1)
            let y = min(max(v, 0), 1) * Float(height - 1)
            let x0 = Int(x), y0 = Int(y)
            let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let fx = x - Float(x0), fy = y - Float(y0)

            func texel(_ px: Int, _ py: Int) -> SIMD3<Float> {
                let o = (py * width + px) * 4
                return SIMD3<Float>(Float(pixels[o]), Float(pixels[o + 1]),
                                    Float(pixels[o + 2])) / 255
            }
            let top = texel(x0, y0) * (1 - fx) + texel(x1, y0) * fx
            let bottom = texel(x0, y1) * (1 - fx) + texel(x1, y1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }
}
