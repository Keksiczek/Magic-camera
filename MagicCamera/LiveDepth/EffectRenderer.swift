//
//  EffectRenderer.swift
//  Magic Camera
//
//  Applies the selected DepthEffect over the camera image + depth map (+ person
//  matte) using a single fullscreen Metal pass. Three entry points share one
//  encode path: live draw, snapshot (CGImage), render into a CVPixelBuffer.
//

import ARKit
import Metal
import MetalKit
import simd

final class EffectRenderer {
    let device: MTLDevice
    let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureFactory: MetalTextureFactory
    private let zeroDepthTexture: MTLTexture
    private let zeroSegTexture: MTLTexture

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "effectVertex"),
              let ffn = library.makeFunction(name: "effectFragment"),
              let factory = MetalTextureFactory(device: device) else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }

        guard let zeroDepth = Self.makeScalarTexture(device: device, format: .r32Float, bytesPerPixel: 4),
              let zeroSeg = Self.makeScalarTexture(device: device, format: .r8Unorm, bytesPerPixel: 1) else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.textureFactory = factory
        self.zeroDepthTexture = zeroDepth
        self.zeroSegTexture = zeroSeg
    }

    private static func makeScalarTexture(device: MTLDevice, format: MTLPixelFormat,
                                          bytesPerPixel: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        var zero = [UInt8](repeating: 0, count: bytesPerPixel)
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &zero, bytesPerRow: bytesPerPixel)
        return texture
    }

    // MARK: - Public entry points

    func draw(frame: ARFrame, settings: EffectSettings, in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let textures = makeTextures(for: frame),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let context = uniformContext(for: frame, textures: textures, viewportSize: view.bounds.size)
        encode(textures: textures, context: context, settings: settings,
               descriptor: descriptor, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func snapshot(frame: ARFrame, settings: EffectSettings, size: CGSize) -> CGImage? {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        guard let textures = makeTextures(for: frame),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: texDesc) else { return nil }

        let pass = renderPass(for: target)
        let context = uniformContext(for: frame, textures: textures, viewportSize: size)
        encode(textures: textures, context: context, settings: settings,
               descriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Self.cgImage(from: target)
    }

    func render(frame: ARFrame, settings: EffectSettings, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard let target = textureFactory.texture(from: pixelBuffer, pixelFormat: pixelFormat),
              let textures = makeTextures(for: frame),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let size = CGSize(width: target.width, height: target.height)
        let pass = renderPass(for: target)
        let context = uniformContext(for: frame, textures: textures, viewportSize: size)
        encode(textures: textures, context: context, settings: settings,
               descriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    // MARK: - Shared encode

    private func encode(textures: FrameTextures, context: FrameUniformContext,
                        settings: EffectSettings, descriptor: MTLRenderPassDescriptor,
                        commandBuffer: MTLCommandBuffer) {
        var uniforms = settings.uniforms(context: context)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        encoder.setFragmentTexture(textures.luma, index: 0)
        encoder.setFragmentTexture(textures.chroma, index: 1)
        encoder.setFragmentTexture(textures.depth, index: 2)
        encoder.setFragmentTexture(textures.segmentation, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func renderPass(for target: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    // MARK: - Texture assembly

    private struct FrameTextures {
        let luma: MTLTexture
        let chroma: MTLTexture
        let depth: MTLTexture
        let segmentation: MTLTexture
        let depthTexel: simd_float2
        let depthSize: simd_float2
        let hasSegmentation: Bool
    }

    private func makeTextures(for frame: ARFrame) -> FrameTextures? {
        let pixelBuffer = frame.capturedImage
        guard let luma = textureFactory.texture(from: pixelBuffer, pixelFormat: .r8Unorm, planeIndex: 0),
              let chroma = textureFactory.texture(from: pixelBuffer, pixelFormat: .rg8Unorm, planeIndex: 1)
        else { return nil }

        let depthTexture: MTLTexture
        let depthTexel: simd_float2
        let depthSize: simd_float2
        if let depthBuffer = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap,
           let depth = textureFactory.texture(from: depthBuffer, pixelFormat: .r32Float) {
            let w = Float(CVPixelBufferGetWidth(depthBuffer))
            let h = Float(CVPixelBufferGetHeight(depthBuffer))
            depthTexture = depth
            depthTexel = simd_float2(1 / w, 1 / h)
            depthSize = simd_float2(w, h)
        } else {
            depthTexture = zeroDepthTexture
            depthTexel = simd_float2(1, 1)
            depthSize = simd_float2(1, 1)
        }

        var segTexture = zeroSegTexture
        var hasSegmentation = false
        if let segBuffer = frame.segmentationBuffer,
           let seg = textureFactory.texture(from: segBuffer, pixelFormat: .r8Unorm) {
            segTexture = seg
            hasSegmentation = true
        }

        return FrameTextures(luma: luma, chroma: chroma, depth: depthTexture,
                             segmentation: segTexture, depthTexel: depthTexel,
                             depthSize: depthSize, hasSegmentation: hasSegmentation)
    }

    private func uniformContext(for frame: ARFrame, textures: FrameTextures,
                                viewportSize: CGSize) -> FrameUniformContext {
        let imageRes = frame.camera.imageResolution
        let k = DepthMath.scaledIntrinsics(frame.camera.intrinsics,
                                           imageWidth: Float(imageRes.width),
                                           depthWidth: textures.depthSize.x)
        let intrinsics = simd_float4(k[0][0], k[1][1], k[2][0], k[2][1])
        return FrameUniformContext(
            viewToImage: viewToImage(for: frame, viewportSize: viewportSize),
            depthTexel: textures.depthTexel,
            depthIntrinsics: intrinsics,
            depthSize: textures.depthSize,
            hasSegmentation: textures.hasSegmentation)
    }

    private func viewToImage(for frame: ARFrame, viewportSize: CGSize) -> simd_float3x3 {
        let display = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        let inverse = display.inverted()
        return simd_float3x3(
            simd_float3(Float(inverse.a),  Float(inverse.b),  0),
            simd_float3(Float(inverse.c),  Float(inverse.d),  0),
            simd_float3(Float(inverse.tx), Float(inverse.ty), 1)
        )
    }

    // MARK: - Readback

    private static func cgImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * height)
        raw.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: &raw, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }
        return context.makeImage()
    }
}
