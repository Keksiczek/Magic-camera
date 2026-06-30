//
//  TextureDelighter.swift
//  Magic Camera
//
//  Evens out the lighting baked into a surface atlas. The best-view bake a room/
//  façade takes assigns each triangle one keyframe, so the texture carries that
//  keyframe's real-world lighting — one wall's lit half and shadowed half, or two
//  walls shot at different exposures, read as a baked-in bright/dark gradient that
//  no amount of seam levelling (which only matches *adjacent* colours) removes.
//
//  This is an intrinsic-image-lite pass: measure each triangle's mean baked
//  luminance, low-pass it across the surface to recover the smooth *lighting*
//  field (the high-frequency albedo averages out), then scale every texel toward
//  the global mean by the inverse of that field — brightening shadow, taming
//  glare — so the surface reads evenly lit. Gentle and clamped: only the
//  low-frequency component is touched, so the actual texture detail survives.
//
//  Pure value math over the finished RGBA atlas (like TextureSeamLeveler) — no
//  bake-path or GPU dependency, off-main.
//

import simd

enum TextureDelighter {
    /// Flattens the low-frequency luminance of `pixels` in place. `strength` is the
    /// fraction of the correction applied (0 = none, 1 = full flatten); the default
    /// keeps it gentle so real shading isn't scrubbed away.
    static func delight(pixels: inout [UInt8], size: Int,
                        geometry: TextureAtlas.Geometry, layout: TextureAtlas.Layout,
                        strength: Float = 0.6) {
        let tris = geometry.uvs.count / 3
        guard tris > 1, size > 0, pixels.count == size * size * 4,
              let box = geometry.mesh.boundingBox() else { return }

        // 1) Per-triangle mean baked luminance (−1 = no covered texels) + centroid.
        var lum = [Float](repeating: -1, count: tris)
        var centroid = [SIMD3<Float>](repeating: .zero, count: tris)
        for t in 0..<tris {
            let v0 = geometry.mesh.vertices[t * 3]
            let v1 = geometry.mesh.vertices[t * 3 + 1]
            let v2 = geometry.mesh.vertices[t * 3 + 2]
            centroid[t] = (v0 + v1 + v2) / 3
            var sum: Float = 0
            var n = 0
            TextureAtlas.forEachTexel(corners: layout.corners(of: t), texSize: size) { px, py, _, _, _ in
                let o = (py * size + px) * 4
                sum += 0.2126 * Float(pixels[o]) + 0.7152 * Float(pixels[o + 1]) + 0.0722 * Float(pixels[o + 2])
                n += 1
            }
            if n > 0 { lum[t] = sum / Float(n) }
        }

        // 2) Global mean luminance over covered triangles.
        var globalSum: Float = 0
        var covered = 0
        for t in 0..<tris where lum[t] >= 0 { globalSum += lum[t]; covered += 1 }
        guard covered > 0 else { return }
        let globalMean = globalSum / Float(covered)
        guard globalMean > 1 else { return }   // an all-black atlas has no lighting to flatten

        // 3) Low-pass the luminance over a spatial cell grid sized to the lighting
        //    scale (a fraction of the model). Cell means (then a 3×3×3 block
        //    average) capture the smooth lighting field cheaply — O(tris), no
        //    per-triangle pair scan.
        let diag = simd_length(box.max - box.min)
        let cell = max(diag * 0.07, 0.08)
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            let s = (p - box.min) / cell
            return SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
        }
        var cellSum = [SIMD3<Int32>: Float]()
        var cellCount = [SIMD3<Int32>: Float]()
        for t in 0..<tris where lum[t] >= 0 {
            let k = key(centroid[t])
            cellSum[k, default: 0] += lum[t]
            cellCount[k, default: 0] += 1
        }
        func smoothedLuminance(at p: SIMD3<Float>) -> Float {
            let k = key(p)
            var s: Float = 0, c: Float = 0
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                let nk = k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))
                if let cs = cellSum[nk], let cc = cellCount[nk] { s += cs; c += cc }
            } } }
            return c > 0 ? s / c : globalMean
        }

        // 4) Scale each triangle's texels toward the global mean by the inverse of
        //    its smoothed lighting, blended by `strength` and clamped so a dark or
        //    blown-out patch is nudged, never inverted.
        for t in 0..<tris where lum[t] >= 0 {
            let field = max(smoothedLuminance(at: centroid[t]), 1)
            let target = globalMean / field
            let gain = min(1.45, max(0.7, 1 + (target - 1) * strength))
            if abs(gain - 1) < 0.02 { continue }
            TextureAtlas.forEachTexel(corners: layout.corners(of: t), texSize: size) { px, py, _, _, _ in
                let o = (py * size + px) * 4
                pixels[o] = UInt8(min(255, Float(pixels[o]) * gain))
                pixels[o + 1] = UInt8(min(255, Float(pixels[o + 1]) * gain))
                pixels[o + 2] = UInt8(min(255, Float(pixels[o + 2]) * gain))
            }
        }
    }
}
