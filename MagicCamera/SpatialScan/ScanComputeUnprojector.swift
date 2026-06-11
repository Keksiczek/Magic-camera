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

    // Optional second pass: intra-frame voxel dedup (open-addressing hash) so
    // the CPU receives one candidate per voxel instead of every depth pixel.
    private let hashCapacity = 131_072
    private let dedupPipeline: MTLComputePipelineState?
    private let dedupPointBuffer: MTLBuffer?
    private let dedupCounterBuffer: MTLBuffer?
    private let hashBuffer: MTLBuffer?

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

        // Dedup pass is best-effort — when anything is missing the unprojector
        // simply returns the raw candidates as before.
        if let dedupFunction = context.library.makeFunction(name: "voxelDedupKernel"),
           let dedupPipeline = try? context.device.makeComputePipelineState(function: dedupFunction) {
            self.dedupPipeline = dedupPipeline
            self.dedupPointBuffer = context.device.makeBuffer(
                length: 65_536 * MemoryLayout<ScanPoint>.stride, options: .storageModeShared)
            self.dedupCounterBuffer = context.device.makeBuffer(
                length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            self.hashBuffer = context.device.makeBuffer(
                length: hashCapacity * MemoryLayout<UInt32>.stride, options: .storageModePrivate)
        } else {
            self.dedupPipeline = nil
            self.dedupPointBuffer = nil
            self.dedupCounterBuffer = nil
            self.hashBuffer = nil
        }
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

        // Optional pass 2 in the same command buffer: collapse this frame's
        // candidates to one per recorder voxel before the CPU sees them.
        var usedDedup = false
        if let dedupPipeline, let dedupPointBuffer, let dedupCounterBuffer, let hashBuffer,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            // 0xFF fill = the kernel's "empty slot" sentinel (0xFFFFFFFF).
            blit.fill(buffer: hashBuffer, range: 0..<hashBuffer.length, value: 0xFF)
            blit.endEncoding()

            dedupCounterBuffer.contents().storeBytes(of: 0, as: UInt32.self)
            // Lattice aligned to the recorder's absolute voxel grid, centred so
            // 11-bit cell coordinates stay positive across the frame's range.
            let cam = frame.camera.transform.columns.3
            let voxel = max(config.voxelSize, 1e-4)
            let halfSpan = voxel * 1024
            let origin = SIMD3<Float>(
                (((cam.x - halfSpan) / voxel).rounded(.down)) * voxel,
                (((cam.y - halfSpan) / voxel).rounded(.down)) * voxel,
                (((cam.z - halfSpan) / voxel).rounded(.down)) * voxel)
            var dedupUniforms = DedupUniforms(
                gridOrigin: origin, voxelSize: voxel,
                capacity: UInt32(capacity), hashCapacity: UInt32(hashCapacity))

            if let dedupEncoder = commandBuffer.makeComputeCommandEncoder() {
                dedupEncoder.setComputePipelineState(dedupPipeline)
                dedupEncoder.setBuffer(pointBuffer, offset: 0, index: 0)
                dedupEncoder.setBuffer(counterBuffer, offset: 0, index: 1)
                dedupEncoder.setBuffer(dedupPointBuffer, offset: 0, index: 2)
                dedupEncoder.setBuffer(dedupCounterBuffer, offset: 0, index: 3)
                dedupEncoder.setBuffer(hashBuffer, offset: 0, index: 4)
                dedupEncoder.setBytes(&dedupUniforms,
                                      length: MemoryLayout<DedupUniforms>.stride, index: 5)
                let width = min(dedupPipeline.maxTotalThreadsPerThreadgroup, 256)
                dedupEncoder.dispatchThreads(
                    MTLSize(width: capacity, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                dedupEncoder.endEncoding()
                usedDedup = true
            }
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let resultCounter = usedDedup ? dedupCounterBuffer! : counterBuffer
        let resultPoints = usedDedup ? dedupPointBuffer! : pointBuffer
        let count = min(Int(resultCounter.contents().load(as: UInt32.self)), capacity)
        guard count > 0 else { return Candidates(positions: [], colors: [], confidences: []) }

        let points = resultPoints.contents().bindMemory(to: ScanPoint.self, capacity: capacity)
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
