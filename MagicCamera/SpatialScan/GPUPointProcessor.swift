//
//  GPUPointProcessor.swift
//  Magic Camera
//
//  Metal-compute point-cloud processing (extends the GPU pipeline started by
//  ScanComputeUnprojector). Currently: radius-neighbour counting → radius
//  outlier removal, the heavy O(n·k) part of clean-up, on the GPU.
//
//  The CPU builds a sorted uniform grid (cell = search radius); the kernel
//  binary-searches the 27 surrounding cells per point. Returns nil whenever
//  Metal is unavailable so callers can fall back to the CPU denoiser.
//

import Metal
import simd

final class GPUPointProcessor {
    private let context: MetalContext
    private let pipeline: MTLComputePipelineState
    /// Optional — the signed-field path falls back to the CPU when it's missing.
    private let fieldPipeline: MTLComputePipelineState?

    init?() {
        guard let context = MetalContext(),
              let function = context.library.makeFunction(name: "neighborCountKernel"),
              let pipeline = try? context.device.makeComputePipelineState(function: function) else {
            return nil
        }
        self.context = context
        self.pipeline = pipeline
        if let fieldFunction = context.library.makeFunction(name: "signedFieldKernel") {
            self.fieldPipeline = try? context.device.makeComputePipelineState(function: fieldFunction)
        } else {
            self.fieldPipeline = nil
        }
    }

    /// Removes points with fewer than `minNeighbors` other points within
    /// `radius` (defaults: 2.5× mean spacing). Returns nil when the GPU path is
    /// unavailable or fails — caller falls back to `PointCloudDenoiser`.
    static func removeRadiusOutliers(_ cloud: PointCloud,
                                     radius: Float? = nil,
                                     minNeighbors: Int = 6) -> PointCloud? {
        guard cloud.count > minNeighbors + 1 else { return nil }
        guard let processor = GPUPointProcessor() else { return nil }
        let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
        let r = radius ?? max(spacing * 2.5, 1e-3)
        guard let counts = processor.neighborCounts(positions: cloud.positions, radius: r) else {
            return nil
        }
        var out = PointCloud()
        out.reserveCapacity(cloud.count)
        let threshold = UInt32(minNeighbors + 1)   // kernel counts the point itself
        for i in 0..<cloud.count where counts[i] >= threshold {
            out.append(position: cloud.positions[i], color: cloud.colors[i],
                       confidence: cloud.confidences[i])
        }
        // Degenerate filtering (everything dropped) → report failure, keep CPU result.
        return out.isEmpty ? nil : out
    }

    /// Per-point neighbour count within `radius` (self included), in the same
    /// order as `positions`. Returns nil on any Metal failure.
    func neighborCounts(positions: [SIMD3<Float>], radius: Float) -> [UInt32]? {
        let n = positions.count
        guard n > 0, radius > 0 else { return nil }

        var lo = positions[0]
        for p in positions { lo = simd_min(lo, p) }
        let origin = lo - SIMD3<Float>(repeating: radius)

        // Sort point indices by packed cell key, then build the unique-cell table.
        var keyed = [(key: UInt64, index: Int)]()
        keyed.reserveCapacity(n)
        for (i, p) in positions.enumerated() {
            keyed.append((Self.cellKey(p, origin: origin, cell: radius), i))
        }
        keyed.sort { $0.key < $1.key }

        var sorted = [SIMD3<Float>](); sorted.reserveCapacity(n)
        var uniqueKeys: [UInt64] = []
        var starts: [UInt32] = []
        var counts: [UInt32] = []
        for (slot, entry) in keyed.enumerated() {
            sorted.append(positions[entry.index])
            if uniqueKeys.last != entry.key {
                uniqueKeys.append(entry.key)
                starts.append(UInt32(slot))
                counts.append(1)
            } else {
                counts[counts.count - 1] += 1
            }
        }

        var uniforms = NeighborUniforms(
            gridOrigin: origin, cellSize: radius, radiusSquared: radius * radius,
            pointCount: UInt32(n), cellCount: UInt32(uniqueKeys.count))

        let device = context.device
        guard let positionBuffer = device.makeBuffer(
                bytes: sorted, length: n * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared),
              let keyBuffer = device.makeBuffer(
                bytes: uniqueKeys, length: uniqueKeys.count * MemoryLayout<UInt64>.stride,
                options: .storageModeShared),
              let startBuffer = device.makeBuffer(
                bytes: starts, length: starts.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared),
              let countBuffer = device.makeBuffer(
                bytes: counts, length: counts.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared),
              let outBuffer = device.makeBuffer(
                length: n * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(positionBuffer, offset: 0, index: 0)
        encoder.setBuffer(keyBuffer, offset: 0, index: 1)
        encoder.setBuffer(startBuffer, offset: 0, index: 2)
        encoder.setBuffer(countBuffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<NeighborUniforms>.stride, index: 4)
        encoder.setBuffer(outBuffer, offset: 0, index: 5)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        // Counts are in sorted order — map back to the caller's point order.
        let sortedCounts = outBuffer.contents().bindMemory(to: UInt32.self, capacity: n)
        var result = [UInt32](repeating: 0, count: n)
        for (slot, entry) in keyed.enumerated() {
            result[entry.index] = sortedCounts[slot]
        }
        return result
    }

    // MARK: - Signed field (GPU surface reconstruction)

    /// Evaluates the Hoppe-style signed distance field at each world `corner`
    /// over `points`/`normals` within `support`, on the GPU — the O(corners ×
    /// neighbours) hot loop of the smooth/Fusion reconstructor. Returns the field
    /// per corner in input order (NaN = no points in range), or nil when the GPU
    /// path is unavailable so the caller can fall back to the CPU evaluator.
    static func signedField(corners: [SIMD3<Float>], points: [SIMD3<Float>],
                            normals: [SIMD3<Float>], support: Float) -> [Float]? {
        guard let processor = GPUPointProcessor() else { return nil }
        return processor.computeField(corners: corners, points: points,
                                      normals: normals, support: support)
    }

    private func computeField(corners: [SIMD3<Float>], points: [SIMD3<Float>],
                              normals: [SIMD3<Float>], support: Float) -> [Float]? {
        guard let fieldPipeline, points.count == normals.count,
              !points.isEmpty, !corners.isEmpty, support > 0 else { return nil }
        let n = points.count

        var lo = points[0]
        for p in points { lo = simd_min(lo, p) }
        let origin = lo - SIMD3<Float>(repeating: support)

        // Sort points (and their normals together) by packed cell key, then build
        // the unique-cell table the kernel binary-searches.
        var keyed = [(key: UInt64, index: Int)]()
        keyed.reserveCapacity(n)
        for (i, p) in points.enumerated() {
            keyed.append((Self.cellKey(p, origin: origin, cell: support), i))
        }
        keyed.sort { $0.key < $1.key }

        var sortedPositions = [SIMD3<Float>](); sortedPositions.reserveCapacity(n)
        var sortedNormals = [SIMD3<Float>](); sortedNormals.reserveCapacity(n)
        var uniqueKeys: [UInt64] = []
        var starts: [UInt32] = []
        var counts: [UInt32] = []
        for (slot, entry) in keyed.enumerated() {
            sortedPositions.append(points[entry.index])
            sortedNormals.append(normals[entry.index])
            if uniqueKeys.last != entry.key {
                uniqueKeys.append(entry.key)
                starts.append(UInt32(slot))
                counts.append(1)
            } else {
                counts[counts.count - 1] += 1
            }
        }

        var uniforms = FieldUniforms(
            gridOrigin: origin, cellSize: support,
            supportSquared: support * support,
            inv2s2: 1 / (2 * support * support),
            cornerCount: UInt32(corners.count), cellCount: UInt32(uniqueKeys.count))

        let device = context.device
        let stride3 = MemoryLayout<SIMD3<Float>>.stride
        guard let cornerBuffer = device.makeBuffer(bytes: corners, length: corners.count * stride3, options: .storageModeShared),
              let positionBuffer = device.makeBuffer(bytes: sortedPositions, length: n * stride3, options: .storageModeShared),
              let normalBuffer = device.makeBuffer(bytes: sortedNormals, length: n * stride3, options: .storageModeShared),
              let keyBuffer = device.makeBuffer(bytes: uniqueKeys, length: uniqueKeys.count * MemoryLayout<UInt64>.stride, options: .storageModeShared),
              let startBuffer = device.makeBuffer(bytes: starts, length: starts.count * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let countBuffer = device.makeBuffer(bytes: counts, length: counts.count * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let outBuffer = device.makeBuffer(length: corners.count * MemoryLayout<Float>.stride, options: .storageModeShared),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(fieldPipeline)
        encoder.setBuffer(cornerBuffer, offset: 0, index: 0)
        encoder.setBuffer(positionBuffer, offset: 0, index: 1)
        encoder.setBuffer(normalBuffer, offset: 0, index: 2)
        encoder.setBuffer(keyBuffer, offset: 0, index: 3)
        encoder.setBuffer(startBuffer, offset: 0, index: 4)
        encoder.setBuffer(countBuffer, offset: 0, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<FieldUniforms>.stride, index: 6)
        encoder.setBuffer(outBuffer, offset: 0, index: 7)
        let width = min(fieldPipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: corners.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let out = outBuffer.contents().bindMemory(to: Float.self, capacity: corners.count)
        return Array(UnsafeBufferPointer(start: out, count: corners.count))
    }

    /// Packed 21-bit-per-axis cell key — must match `packedCellKey` in
    /// ScanCompute.metal.
    static func cellKey(_ p: SIMD3<Float>, origin: SIMD3<Float>, cell: Float) -> UInt64 {
        let s = (p - origin) / cell
        let bias: Int64 = 1 << 20
        let x = UInt64(Int64(s.x.rounded(.down)) + bias)
        let y = UInt64(Int64(s.y.rounded(.down)) + bias)
        let z = UInt64(Int64(s.z.rounded(.down)) + bias)
        return (x << 42) | (y << 21) | z
    }
}
