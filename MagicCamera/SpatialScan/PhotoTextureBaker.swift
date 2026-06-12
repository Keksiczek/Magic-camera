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
    /// Bakes keyframe photos onto `mesh`. `fallbackCloud` colours triangles no
    /// keyframe can see. Heavy — run off the main thread.
    static func bake(mesh: MeshData, keyframes: [ScanKeyframe],
                     fallbackCloud: PointCloud?,
                     textureSize requested: Int? = nil) -> TexturedMesh? {
        let triCount = mesh.indices.count / 3
        guard triCount > 0, !keyframes.isEmpty else { return nil }

        let layout = TextureAtlas.Layout(triangleCount: triCount, requested: requested)
        let geometry = TextureAtlas.buildGeometry(mesh: mesh, layout: layout)
        let views = keyframes.map(View.init)

        // Pass 1 — best keyframe per triangle.
        var bestView = [Int](repeating: -1, count: triCount)
        for t in 0..<triCount {
            let w0 = geometry.mesh.vertices[t * 3]
            let w1 = geometry.mesh.vertices[t * 3 + 1]
            let w2 = geometry.mesh.vertices[t * 3 + 2]
            let center = (w0 + w1 + w2) / 3
            let normalRaw = simd_cross(w1 - w0, w2 - w0)
            let nLen = simd_length(normalRaw)
            guard nLen > 1e-12 else { continue }
            let normal = normalRaw / nLen

            var bestScore: Float = 0.05
            for (k, view) in views.enumerated() {
                guard let score = view.score(center: center, normal: normal),
                      score > bestScore else { continue }
                bestScore = score
                bestView[t] = k
            }
        }

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

        TextureAtlas.fillGutters(pixels: &pixels, size: layout.texSize)
        guard let png = TextureAtlas.encodePNG(pixels: pixels, size: layout.texSize) else {
            return nil
        }
        return TexturedMesh(mesh: geometry.mesh, uvs: geometry.uvs,
                            texturePNG: png, textureSize: layout.texSize)
    }

    /// Per-channel gain matching a keyframe photo to the fused cloud colours:
    /// sampled over cloud points the keyframe can see, ratio of mean colours.
    private static func exposureGain(view: View, photo: DecodedPhoto,
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

    private struct View {
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

    private struct DecodedPhoto {
        let width: Int
        let height: Int
        let pixels: [UInt8]   // RGBA8

        init?(jpeg: Data, maxPixelSize: Int = 1440) {
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
