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
    /// Size each keyframe is resized to in the sampling texture array. Sampling
    /// is normalised, so squashing to a square doesn't change the looked-up
    /// content; it just bounds memory (N slices × this² × 4 bytes).
    private static let slicePixels = 1024

    /// Bakes the keyframe-assigned triangles on the GPU. `geometry` is the
    /// duplicated-corner atlas geometry, `bestView[t]` the chosen keyframe per
    /// triangle (−1 = none), `gains[k]` the per-keyframe exposure gain.
    static func bake(geometry: TextureAtlas.Geometry,
                     bestView: [Int],
                     keyframes: [ScanKeyframe],
                     gains: [SIMD3<Float>],
                     texSize: Int) -> [UInt8]? {
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
