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
    /// take. Higher than the 4096 default so a large surface's adaptive atlas can
    /// actually grow: 6144²·4 B = 144 MB for the GPU output buffer (matched by the
    /// readback array) — a bounded one-shot review-time bake. The memory-bound
    /// multi-view object path keeps its own much lower cap.
    private static let surfaceAtlasCap = 6144

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
        let views = keyframes.map(View.init)

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

        // GPU Pass 2 (one thread per triangle) when enabled and available.
        // Pass 1 + the per-keyframe exposure gain stay on the CPU; the heavy
        // per-texel projection/sampling runs on the GPU. Falls back below.
        if GPUSettings.textureBakeEnabled {
            if Task.isCancelled { return nil }
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
                                                    texSize: layout.texSize) {
                paintFallbackTriangles(into: &gpuPixels, geometry: geometry, bestView: bestView,
                                       layout: layout, fallbackCloud: fallbackCloud)
                TextureSeamLeveler.level(pixels: &gpuPixels, size: layout.texSize,
                                         geometry: geometry, layout: layout)
                if delight {
                    TextureDelighter.delight(pixels: &gpuPixels, size: layout.texSize,
                                             geometry: geometry, layout: layout)
                }
                TextureAtlas.fillGutters(pixels: &gpuPixels, size: layout.texSize)
                if let png = TextureAtlas.encodePNG(pixels: gpuPixels, size: layout.texSize) {
                    Diagnostics.shared.gpu("texture-bake", used: true,
                                           "\(triCount) tris · atlas \(layout.texSize)²\(atlasKind)")
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
            return MeshTextureBaker.ColorSampler(cloud: cloud, cell: max(spacing * 2.5, 0.004))
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
        // Cap the atlas so the per-texel SIMD4 accumulator stays ≤ ~64 MB. Within
        // that ceiling the layout is still area-adaptive; objects (small triangles)
        // sit near the baseline anyway, so this mostly just bounds the rare case.
        let cap = 2048
        var layout = TextureAtlas.Layout(triangleCount: triCount, requested: requested,
                                         surfaceArea: mesh.surfaceArea(), maxTexSize: cap)
        if layout.texSize > cap {
            layout = TextureAtlas.Layout(triangleCount: triCount, requested: cap)
        }
        let geometry = TextureAtlas.buildGeometry(mesh: mesh, layout: layout)
        let views = keyframes.map(View.init)

        // Pass 1 — every view that sees a triangle well (score ≥ half its best,
        // up to maxViews), with the per-view facing weight to blend it by.
        let maxViews = 4
        var candidates = [[(view: Int, weight: Float)]](repeating: [], count: triCount)
        var byView: [Int: [Int]] = [:]
        for t in 0..<triCount {
            if t % 8192 == 0, Task.isCancelled { return nil }
            let w0 = geometry.mesh.vertices[t * 3]
            let w1 = geometry.mesh.vertices[t * 3 + 1]
            let w2 = geometry.mesh.vertices[t * 3 + 2]
            let normalRaw = simd_cross(w1 - w0, w2 - w0)
            let nLen = simd_length(normalRaw)
            guard nLen > 1e-12 else { continue }
            let normal = normalRaw / nLen
            let center = (w0 + w1 + w2) / 3
            var scored: [(view: Int, weight: Float)] = []
            for (k, view) in views.enumerated() {
                if let s = view.score(center: center, normal: normal), s > 0.05 {
                    scored.append((view: k, weight: s))
                }
            }
            guard let best = scored.map(\.weight).max() else { continue }
            let chosen = scored.filter { $0.weight >= best * 0.5 }
                               .sorted { $0.weight > $1.weight }
                               .prefix(maxViews)
            candidates[t] = Array(chosen)
            for c in chosen { byView[c.view, default: []].append(t) }
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
            return MeshTextureBaker.ColorSampler(cloud: cloud, cell: max(spacing * 2.5, 0.004))
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
                               "multi-view · \(triCount) tris · \(views.count) views")
        return TexturedMesh(mesh: geometry.mesh, uvs: geometry.uvs,
                            texturePNG: png, textureSize: layout.texSize)
    }

    /// Paints the triangles no keyframe could see (GPU left them transparent)
    /// with cloud colours — the same fallback the CPU Pass 2 applies.
    private static func paintFallbackTriangles(into pixels: inout [UInt8],
                                               geometry: TextureAtlas.Geometry,
                                               bestView: [Int],
                                               layout: some AtlasLayout,
                                               fallbackCloud: PointCloud?) {
        let fallback: MeshTextureBaker.ColorSampler? = fallbackCloud.map { cloud in
            let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
            return MeshTextureBaker.ColorSampler(cloud: cloud, cell: max(spacing * 2.5, 0.004))
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

    /// Internal so the GPU baker reuses the exact projection + scoring.
    struct View {
        let keyframe: ScanKeyframe
        let worldToCamera: simd_float4x4
        let cameraPosition: SIMD3<Float>

        init(_ keyframe: ScanKeyframe) {
            self.keyframe = keyframe
            self.worldToCamera = keyframe.cameraTransform.inverse
            let t = keyframe.cameraTransform.columns.3
            self.cameraPosition = SIMD3<Float>(t.x, t.y, t.z)
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
            // Occlusion: the keyframe's own depth must roughly agree.
            let stored = keyframe.depth[Int(v) * keyframe.depthWidth + Int(u)]
            if stored > 0, depth > stored + 0.12 { return nil }
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
            return facing * (0.5 + 0.5 * border)
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
