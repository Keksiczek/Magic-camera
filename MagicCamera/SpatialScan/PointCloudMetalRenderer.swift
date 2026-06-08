//
//  PointCloudMetalRenderer.swift
//  Magic Camera
//
//  Renders a coloured point cloud with Metal: points are drawn to an offscreen
//  colour + eye-space-depth target, then an EDL post-pass adds depth-edge
//  shading. Scales to far more points than SceneKit's point geometry.
//

import Metal
import MetalKit
import simd

final class PointCloudMetalRenderer {
    private let context: MetalContext
    private let pointPipeline: MTLRenderPipelineState
    private let edlPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private var positionBuffer: MTLBuffer?
    private var colorBuffer: MTLBuffer?
    private var pointCount = 0

    private var colorTexture: MTLTexture?
    private var eyeDepthTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private var textureSize = CGSize.zero

    init?(context: MetalContext, colorPixelFormat: MTLPixelFormat) {
        self.context = context
        let library = context.library
        guard let pv = library.makeFunction(name: "pointVertex"),
              let pf = library.makeFunction(name: "pointFragment"),
              let ev = library.makeFunction(name: "edlVertex"),
              let ef = library.makeFunction(name: "edlFragment") else { return nil }

        let pointDesc = MTLRenderPipelineDescriptor()
        pointDesc.vertexFunction = pv
        pointDesc.fragmentFunction = pf
        pointDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pointDesc.colorAttachments[1].pixelFormat = .r32Float
        pointDesc.depthAttachmentPixelFormat = .depth32Float

        let edlDesc = MTLRenderPipelineDescriptor()
        edlDesc.vertexFunction = ev
        edlDesc.fragmentFunction = ef
        edlDesc.colorAttachments[0].pixelFormat = colorPixelFormat

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true

        guard let pointPipeline = try? context.device.makeRenderPipelineState(descriptor: pointDesc),
              let edlPipeline = try? context.device.makeRenderPipelineState(descriptor: edlDesc),
              let depthState = context.device.makeDepthStencilState(descriptor: depthDesc) else {
            return nil
        }
        self.pointPipeline = pointPipeline
        self.edlPipeline = edlPipeline
        self.depthState = depthState
    }

    // MARK: - Data

    func setCloud(_ cloud: PointCloud, colorMode: PointColorMode) {
        pointCount = cloud.count
        guard pointCount > 0 else { positionBuffer = nil; colorBuffer = nil; return }
        let positions = cloud.positions
        positionBuffer = positions.withUnsafeBytes {
            context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
        setColorMode(colorMode, cloud: cloud)
    }

    func setColorMode(_ colorMode: PointColorMode, cloud: PointCloud) {
        guard pointCount > 0 else { return }
        let colors = PointCloudSceneBuilder.colorArray(for: cloud, mode: colorMode)
        colorBuffer = colors.withUnsafeBytes {
            context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])
        }
    }

    // MARK: - Draw

    @MainActor
    func draw(in view: MTKView, camera: ArcballCamera, pointSize: Float, edlEnabled: Bool) {
        guard pointCount > 0,
              let positionBuffer, let colorBuffer,
              let drawable = view.currentDrawable,
              let finalPass = view.currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }

        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        ensureTextures(size: size)
        guard let colorTexture, let eyeDepthTexture, let depthTexture else { return }

        let aspect = Float(size.width / size.height)
        var vertexUniforms = PointVertexUniforms(
            projection: camera.projectionMatrix(aspect: aspect),
            modelView: camera.viewMatrix(),
            pointSize: pointSize)

        // Pass 1 — points to offscreen colour + eye depth.
        let pass1 = MTLRenderPassDescriptor()
        pass1.colorAttachments[0].texture = colorTexture
        pass1.colorAttachments[0].loadAction = .clear
        pass1.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass1.colorAttachments[0].storeAction = .store
        pass1.colorAttachments[1].texture = eyeDepthTexture
        pass1.colorAttachments[1].loadAction = .clear
        pass1.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass1.colorAttachments[1].storeAction = .store
        pass1.depthAttachment.texture = depthTexture
        pass1.depthAttachment.loadAction = .clear
        pass1.depthAttachment.clearDepth = 1.0
        pass1.depthAttachment.storeAction = .dontCare

        guard let enc1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1) else { return }
        enc1.setRenderPipelineState(pointPipeline)
        enc1.setDepthStencilState(depthState)
        enc1.setVertexBuffer(positionBuffer, offset: 0, index: 0)
        enc1.setVertexBuffer(colorBuffer, offset: 0, index: 1)
        enc1.setVertexBytes(&vertexUniforms, length: MemoryLayout<PointVertexUniforms>.stride, index: 2)
        enc1.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
        enc1.endEncoding()

        // Pass 2 — EDL composite to the drawable.
        var edlUniforms = EDLUniforms(
            inverseResolution: SIMD2<Float>(1 / Float(size.width), 1 / Float(size.height)),
            edlStrength: edlEnabled ? 1.0 : 0.0,
            edlRadius: 2.0)
        guard let enc2 = commandBuffer.makeRenderCommandEncoder(descriptor: finalPass) else { return }
        enc2.setRenderPipelineState(edlPipeline)
        enc2.setFragmentBytes(&edlUniforms, length: MemoryLayout<EDLUniforms>.stride, index: 0)
        enc2.setFragmentTexture(colorTexture, index: 0)
        enc2.setFragmentTexture(eyeDepthTexture, index: 1)
        enc2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc2.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func ensureTextures(size: CGSize) {
        guard size != textureSize else { return }
        textureSize = size
        let width = Int(size.width), height = Int(size.height)

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        colorTexture = context.device.makeTexture(descriptor: colorDesc)

        let depthColorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        depthColorDesc.usage = [.renderTarget, .shaderRead]
        depthColorDesc.storageMode = .private
        eyeDepthTexture = context.device.makeTexture(descriptor: depthColorDesc)

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        depthTexture = context.device.makeTexture(descriptor: depthDesc)
    }
}
