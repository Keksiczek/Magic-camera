//
//  ScanComputeUnprojector.swift
//  Magic Camera
//
//  Runs the GPU unprojection kernel for a frame and returns candidate world
//  points (already depth/confidence/stride filtered). Voxel dedup + capping
//  stay on the CPU. Returns nil if Metal is unavailable so the caller can fall
//  back to the CPU path.
//

import ARKit
import Metal
import simd

final class ScanComputeUnprojector {
    struct Candidates {
        var positions: [SIMD3<Float>]
        var colors: [SIMD3<Float>]
        var confidences: [Float]
    }

    private let context: MetalContext
    private let pipeline: MTLComputePipelineState
    private let capacity = 65_536
    private let pointBuffer: MTLBuffer
    private let counterBuffer: MTLBuffer

    init?() {
        guard let context = MetalContext(),
              let function = context.library.makeFunction(name: "unprojectKernel"),
              let pipeline = try? context.device.makeComputePipelineState(function: function),
              let pointBuffer = context.device.makeBuffer(
                length: 65_536 * MemoryLayout<ScanPoint>.stride, options: .storageModeShared),
              let counterBuffer = context.device.makeBuffer(
                length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            return nil
        }
        self.context = context
        self.pipeline = pipeline
        self.pointBuffer = pointBuffer
        self.counterBuffer = counterBuffer
    }

    func unproject(frame: ARFrame, config: ScanConfig) -> Candidates? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidenceMap = sceneDepth.confidenceMap else { return nil }
        let depthMap = sceneDepth.depthMap
        let factory = context.textureFactory

        guard let depthTex = factory.texture(from: depthMap, pixelFormat: .r32Float),
              let confTex = factory.texture(from: confidenceMap, pixelFormat: .r8Uint),
              let yTex = factory.texture(from: frame.capturedImage, pixelFormat: .r8Unorm, planeIndex: 0),
              let cbcrTex = factory.texture(from: frame.capturedImage, pixelFormat: .rg8Unorm, planeIndex: 1)
        else { return nil }

        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        let imageRes = frame.camera.imageResolution
        let k = DepthMath.scaledIntrinsics(frame.camera.intrinsics,
                                           imageWidth: Float(imageRes.width), depthWidth: Float(dw))
        var uniforms = ScanUniforms(
            cameraTransform: frame.camera.transform,
            fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
            depthWidth: Float(dw), depthHeight: Float(dh),
            maxDepth: config.maxDepth,
            stride: UInt32(max(config.pixelStride, 1)),
            minConfidence: UInt32(config.minConfidence),
            capacity: UInt32(capacity))

        counterBuffer.contents().storeBytes(of: 0, as: UInt32.self)

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(depthTex, index: 0)
        encoder.setTexture(confTex, index: 1)
        encoder.setTexture(yTex, index: 2)
        encoder.setTexture(cbcrTex, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<ScanUniforms>.stride, index: 0)
        encoder.setBuffer(pointBuffer, offset: 0, index: 1)
        encoder.setBuffer(counterBuffer, offset: 0, index: 2)

        let tgWidth = pipeline.threadExecutionWidth
        let tgHeight = max(pipeline.maxTotalThreadsPerThreadgroup / tgWidth, 1)
        encoder.dispatchThreads(MTLSize(width: dw, height: dh, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let count = min(Int(counterBuffer.contents().load(as: UInt32.self)), capacity)
        guard count > 0 else { return Candidates(positions: [], colors: [], confidences: []) }

        let points = pointBuffer.contents().bindMemory(to: ScanPoint.self, capacity: capacity)
        var positions = [SIMD3<Float>](); positions.reserveCapacity(count)
        var colors = [SIMD3<Float>](); colors.reserveCapacity(count)
        var confidences = [Float](); confidences.reserveCapacity(count)
        for i in 0..<count {
            let p = points[i]
            positions.append(p.position)
            colors.append(p.color)
            confidences.append(p.confidence)
        }
        return Candidates(positions: positions, colors: colors, confidences: confidences)
    }
}
