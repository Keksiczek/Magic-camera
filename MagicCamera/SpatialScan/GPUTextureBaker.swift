//
//  GPUTextureBaker.swift
//  Magic Camera
//
//  Metal-compute Pass 2 of the photo texture bake: one GPU thread per triangle
//  rasterises its atlas chart and projects/samples its chosen keyframe (see
//  `bakeTextureKernel`). PhotoTextureBaker keeps Pass 1 (best keyframe per
//  triangle) and the exposure gain on the CPU and hands the results here; on any
//  Metal failure this returns nil and the caller falls back to the CPU bake.
//
//  Returns the RGBA8 atlas with keyframe-assigned triangles painted; triangles
//  with no keyframe (view < 0) are left transparent for the CPU fallback to fill.
//

import CoreGraphics
import ImageIO
import Metal
import simd

enum GPUTextureBaker {
    /// Size each keyframe is resized to in the sampling texture array, scaled by
    /// keyframe count so the array (N slices × size² × 4 bytes) stays under a
    /// memory budget. Sampling is normalised, so the square resize doesn't change
    /// WHERE content is looked up — but it caps the baked texture's SHARPNESS: at
    /// 1024² the r22 hi-res keyframes (≈4032 px) were squashed 4× before sampling,
    /// so a room's texture stayed soft no matter how big the 8192² atlas was. On a
    /// high-memory device (≈8 GB, e.g. A18 Pro — the same gate the 8192² atlas
    /// ships behind) raise it toward 3072² for the sharpest source detail, backing
    /// off when there are many keyframes so the transient array can't OOM alongside
    /// the 8192² output + PNG readback. Low-memory devices keep 1024².
    ///
    /// The 3072 cap (was 2048) sharpens the common low-keyframe room: a scan with
    /// ~11 keyframes fits 3072² comfortably (≈415 MB < the 512 MB budget) so its
    /// photos are sampled near full detail, while a 32-keyframe scan still backs off
    /// to ~1792². The cap only binds below ~13 keyframes.
    static func sliceSize(forKeyframeCount n: Int) -> Int {
        guard n > 0, ProcessInfo.processInfo.physicalMemory > 7_000_000_000 else { return 1024 }
        // 768 MB (was 512): the denser keyframe capture (cap 72) squeezed a
        // 52-keyframe device room down to 1536² slices — the photo-sampling
        // softness ceiling — right when photo coverage finally got good. 768 MB
        // keeps that room at 1792²; still a transient one-shot on the 8 GB
        // devices this gate selects (watch OOM alongside the 8192² atlas).
        let budgetBytes = 768_000_000            // photo-array ceiling on high-mem devices
        let fit = Int((Double(budgetBytes) / Double(n * 4)).squareRoot())
        return max(1024, min(3072, (fit / 256) * 256))
    }

    /// Bakes the keyframe-assigned triangles on the GPU. `geometry` is the
    /// duplicated-corner atlas geometry, `bestView[t]` the chosen keyframe per
    /// triangle (−1 = none), `gains[k]` the per-keyframe exposure gain. `slicePixels`
    /// is the per-keyframe sampling resolution (see `sliceSize`).
    static func bake(geometry: TextureAtlas.Geometry,
                     bestView: [Int],
                     keyframes: [ScanKeyframe],
                     gains: [SIMD3<Float>],
                     texSize: Int,
                     slicePixels: Int) -> [UInt8]? {
        let triCount = bestView.count
        guard triCount > 0, !keyframes.isEmpty, texSize > 0,
              geometry.mesh.vertices.count == triCount * 3,
              geometry.uvs.count == triCount * 3,
              gains.count == keyframes.count else { return nil }
        guard let context = MetalContext(),
              let function = context.library.makeFunction(name: "bakeTextureKernel"),
              let pipeline = try? context.device.makeComputePipelineState(function: function) else {
            return nil
        }
        let device = context.device

        // Per-keyframe projection params.
        var params = [BakeKeyframe]()
        params.reserveCapacity(keyframes.count)
        for (i, k) in keyframes.enumerated() {
            let intr = k.intrinsics
            params.append(BakeKeyframe(
                worldToCamera: k.cameraTransform.inverse,
                gain: gains[i],
                fx: intr[0][0], fy: intr[1][1], cx: intr[2][0], cy: intr[2][1],
                depthWidth: Float(k.depthWidth), depthHeight: Float(k.depthHeight)))
        }

        // Keyframe photos → a 2D texture array (one resized slice each).
        let size = slicePixels
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = keyframes.count
        descriptor.usage = .shaderRead
        guard let photoArray = device.makeTexture(descriptor: descriptor) else { return nil }
        let region = MTLRegionMake2D(0, 0, size, size)
        let grey = [UInt8](repeating: 128, count: size * size * 4)
        for (i, k) in keyframes.enumerated() {
            let slice = decodeFixed(k.jpeg, size: size) ?? grey
            slice.withUnsafeBytes { raw in
                photoArray.replace(region: region, mipmapLevel: 0, slice: i,
                                   withBytes: raw.baseAddress!,
                                   bytesPerRow: size * 4, bytesPerImage: size * size * 4)
            }
        }

        // Per-triangle attribute buffers.
        var triWorld = geometry.mesh.vertices              // 3 per triangle, contiguous
        let inv = Float(texSize)
        var triUV = geometry.uvs.map { $0 * inv }          // normalised → pixel space
        var triView = bestView.map { Int32($0) }
        var uniforms = BakeUniforms(triangleCount: UInt32(triCount), texSize: UInt32(texSize))
        let outBytes = texSize * texSize * 4

        let posStride = MemoryLayout<SIMD3<Float>>.stride
        guard let worldBuffer = device.makeBuffer(bytes: &triWorld,
                length: triWorld.count * posStride, options: .storageModeShared),
              let uvBuffer = device.makeBuffer(bytes: &triUV,
                length: triUV.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
              let viewBuffer = device.makeBuffer(bytes: &triView,
                length: triView.count * MemoryLayout<Int32>.stride, options: .storageModeShared),
              let paramBuffer = device.makeBuffer(bytes: &params,
                length: params.count * MemoryLayout<BakeKeyframe>.stride, options: .storageModeShared),
              let outBuffer = device.makeBuffer(length: outBytes, options: .storageModeShared),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        // Zero the output so triangles with no keyframe stay transparent for the
        // CPU fallback to fill (the kernel writes only assigned triangles).
        // memset on the shared buffer avoids a second `outBytes`-sized Swift array
        // — it matters at the raised surface ceiling (144 MB at 6144²).
        memset(outBuffer.contents(), 0, outBytes)

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(worldBuffer, offset: 0, index: 0)
        encoder.setBuffer(uvBuffer, offset: 0, index: 1)
        encoder.setBuffer(viewBuffer, offset: 0, index: 2)
        encoder.setBuffer(paramBuffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<BakeUniforms>.stride, index: 4)
        encoder.setBuffer(outBuffer, offset: 0, index: 5)
        encoder.setTexture(photoArray, index: 0)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: triCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let pointer = outBuffer.contents().bindMemory(to: UInt8.self, capacity: outBytes)
        return Array(UnsafeBufferPointer(start: pointer, count: outBytes))
    }

    /// Even-lighting multi-view bake on the GPU. Each texel blends up to
    /// `maxViews` facing-weighted candidate keyframes (`candidates[t]`), each
    /// exposure-normalised to the fused cloud by `gains`, with an occlusion test
    /// against each keyframe's own depth map — so the baked colour is anchored to
    /// the scene's albedo, not one photo's brightness, and occluded views never
    /// bleed in. This is the object path's even lighting brought to room/surface
    /// scans at full atlas + GPU speed. Texels no candidate sees are left
    /// transparent for the CPU cloud fallback. Dispatched in triangle chunks to
    /// bound each command buffer's GPU time. Returns nil on any Metal failure or
    /// when the keyframe depth maps aren't a common size (caller falls back).
    static func bakeMultiView(geometry: TextureAtlas.Geometry,
                              candidates: [[(view: Int, weight: Float)]],
                              keyframes: [ScanKeyframe],
                              gains: [SIMD3<Float>],
                              texSize: Int,
                              slicePixels: Int,
                              maxViews: Int) -> [UInt8]? {
        let triCount = candidates.count
        guard triCount > 0, !keyframes.isEmpty, texSize > 0, maxViews > 0,
              geometry.mesh.vertices.count == triCount * 3,
              geometry.uvs.count == triCount * 3,
              gains.count == keyframes.count else { return nil }
        // Occlusion needs every keyframe's depth map in one array — require a
        // common size (true in practice: all are the sceneDepth resolution).
        let dw = keyframes[0].depthWidth, dh = keyframes[0].depthHeight
        guard dw > 0, dh > 0,
              keyframes.allSatisfy({ $0.depthWidth == dw && $0.depthHeight == dh
                                     && $0.depth.count == dw * dh }) else {
            // Why the multi-view path fell back to single-view (a device diag showed
            // a 26-keyframe room silently on the single-view path).
            Diagnostics.shared.log("multi-view skip", "depth dims vary")
            return nil
        }
        guard let context = MetalContext(),
              let function = context.library.makeFunction(name: "bakeTextureMultiViewKernel"),
              let pipeline = try? context.device.makeComputePipelineState(function: function) else {
            Diagnostics.shared.log("multi-view skip", "metal pipeline unavailable")
            return nil
        }
        let device = context.device

        // Per-keyframe projection params (same as the single-view path).
        var params = keyframes.enumerated().map { i, k -> BakeKeyframe in
            let intr = k.intrinsics
            return BakeKeyframe(
                worldToCamera: k.cameraTransform.inverse, gain: gains[i],
                fx: intr[0][0], fy: intr[1][1], cx: intr[2][0], cy: intr[2][1],
                depthWidth: Float(k.depthWidth), depthHeight: Float(k.depthHeight))
        }

        // Keyframe photos → a 2D texture array (one resized square slice each).
        let size = slicePixels
        let photoDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        photoDesc.textureType = .type2DArray
        photoDesc.arrayLength = keyframes.count
        photoDesc.usage = .shaderRead
        guard let photoArray = device.makeTexture(descriptor: photoDesc) else {
            // The photo array is N × slice² × 4 bytes — the one allocation that can
            // fail on a high-keyframe room. `sliceSize` should keep it in budget;
            // log if it still failed so the budget can be tightened.
            Diagnostics.shared.log("multi-view skip",
                                   "photo array alloc \(keyframes.count)×\(size)²")
            return nil
        }
        let photoRegion = MTLRegionMake2D(0, 0, size, size)
        let grey = [UInt8](repeating: 128, count: size * size * 4)
        for (i, k) in keyframes.enumerated() {
            let slice = decodeFixed(k.jpeg, size: size) ?? grey
            slice.withUnsafeBytes { raw in
                photoArray.replace(region: photoRegion, mipmapLevel: 0, slice: i,
                                   withBytes: raw.baseAddress!,
                                   bytesPerRow: size * 4, bytesPerImage: size * size * 4)
            }
        }

        // Keyframe depth maps → an r32Float texture array for the occlusion test.
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: dw, height: dh, mipmapped: false)
        depthDesc.textureType = .type2DArray
        depthDesc.arrayLength = keyframes.count
        depthDesc.usage = .shaderRead
        guard let depthArray = device.makeTexture(descriptor: depthDesc) else { return nil }
        let depthRegion = MTLRegionMake2D(0, 0, dw, dh)
        for (i, k) in keyframes.enumerated() {
            k.depth.withUnsafeBytes { raw in
                depthArray.replace(region: depthRegion, mipmapLevel: 0, slice: i,
                                   withBytes: raw.baseAddress!,
                                   bytesPerRow: dw * 4, bytesPerImage: dw * dh * 4)
            }
        }

        // Per-triangle attribute + candidate buffers.
        var triWorld = geometry.mesh.vertices
        let inv = Float(texSize)
        var triUV = geometry.uvs.map { $0 * inv }
        var triViews = [Int32](repeating: -1, count: triCount * maxViews)
        var triWeights = [Float](repeating: 0, count: triCount * maxViews)
        for t in 0..<triCount {
            for (j, cand) in candidates[t].prefix(maxViews).enumerated() {
                triViews[t * maxViews + j] = Int32(cand.view)
                triWeights[t * maxViews + j] = cand.weight
            }
        }
        let outBytes = texSize * texSize * 4

        let posStride = MemoryLayout<SIMD3<Float>>.stride
        guard let worldBuffer = device.makeBuffer(bytes: &triWorld,
                length: triWorld.count * posStride, options: .storageModeShared),
              let uvBuffer = device.makeBuffer(bytes: &triUV,
                length: triUV.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
              let viewsBuffer = device.makeBuffer(bytes: &triViews,
                length: triViews.count * MemoryLayout<Int32>.stride, options: .storageModeShared),
              let weightsBuffer = device.makeBuffer(bytes: &triWeights,
                length: triWeights.count * MemoryLayout<Float>.stride, options: .storageModeShared),
              let paramBuffer = device.makeBuffer(bytes: &params,
                length: params.count * MemoryLayout<BakeKeyframe>.stride, options: .storageModeShared),
              let outBuffer = device.makeBuffer(length: outBytes, options: .storageModeShared) else {
            return nil
        }
        // Zero the output so unseen texels stay transparent for the cloud fallback.
        memset(outBuffer.contents(), 0, outBytes)

        // Dispatch in triangle chunks: 4× the per-texel work of the single-view
        // bake over a full 8192² atlas would otherwise be one very long command
        // buffer that risks the GPU timeout. Each chunk is its own buffer.
        let chunk = 30_000
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        var offset = 0
        while offset < triCount {
            let count = min(chunk, triCount - offset)
            var uniforms = BakeMultiUniforms(triangleCount: UInt32(triCount),
                                             texSize: UInt32(texSize),
                                             maxViews: UInt32(maxViews),
                                             triangleOffset: UInt32(offset))
            guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(worldBuffer, offset: 0, index: 0)
            encoder.setBuffer(uvBuffer, offset: 0, index: 1)
            encoder.setBuffer(viewsBuffer, offset: 0, index: 2)
            encoder.setBuffer(weightsBuffer, offset: 0, index: 3)
            encoder.setBuffer(paramBuffer, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<BakeMultiUniforms>.stride, index: 5)
            encoder.setBuffer(outBuffer, offset: 0, index: 6)
            encoder.setTexture(photoArray, index: 0)
            encoder.setTexture(depthArray, index: 1)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else { return nil }
            offset += count
        }

        let pointer = outBuffer.contents().bindMemory(to: UInt8.self, capacity: outBytes)
        return Array(UnsafeBufferPointer(start: pointer, count: outBytes))
    }

    /// Decodes a keyframe JPEG to a fixed `size × size` RGBA8 buffer (squashed —
    /// fine for normalised sampling). Nil on decode failure.
    private static func decodeFixed(_ jpeg: Data, size: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceCreateThumbnailWithTransform: false
              ] as CFDictionary) else { return nil }
        var buffer = [UInt8](repeating: 0, count: size * size * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return ok ? buffer : nil
    }
}
