//
//  GPUSurfaceField.swift
//  Magic Camera
//
//  Metal-compute evaluation of the Hoppe-style signed-distance field used by the
//  smooth / Fusion surface reconstruction — the heavy inner loop that dominated
//  the reconstruction's CPU time. One GPU thread per lattice corner sums the
//  Gaussian-weighted signed distance to nearby points over a CPU-prebuilt sorted
//  uniform grid (the same structure `GPUPointProcessor` uses for neighbour
//  counting). Returns nil whenever Metal is unavailable or fails, so the
//  reconstructor falls back to the multicore CPU path.
//

import Metal
import simd

enum GPUSurfaceField {
    /// Evaluates the signed field at each `query` (lattice-corner world point)
    /// from the oriented points `(positions, normals)`. `support` is the
    /// Gaussian kernel radius (grid cell). Returns one value per query, with
    /// `.infinity` marking corners with no points in range. Nil on any failure.
    static func evaluate(queries: [SIMD3<Float>],
                         positions: [SIMD3<Float>],
                         normals: [SIMD3<Float>],
                         support: Float) -> [Float]? {
        let n = positions.count
        guard n > 0, n == normals.count, !queries.isEmpty, support > 0 else { return nil }
        guard let context = MetalContext(),
              let function = context.library.makeFunction(name: "sdfFieldKernel"),
              let pipeline = try? context.device.makeComputePipelineState(function: function) else {
            return nil
        }

        // Sorted uniform grid (cell = support) over the (point, normal) pairs.
        var lo = positions[0]
        for p in positions { lo = simd_min(lo, p) }
        let origin = lo - SIMD3<Float>(repeating: support)

        var keyed = [(key: UInt64, index: Int)]()
        keyed.reserveCapacity(n)
        for (i, p) in positions.enumerated() {
            keyed.append((GPUPointProcessor.cellKey(p, origin: origin, cell: support), i))
        }
        keyed.sort { $0.key < $1.key }

        var sortedPositions = [SIMD3<Float>](); sortedPositions.reserveCapacity(n)
        var sortedNormals = [SIMD3<Float>](); sortedNormals.reserveCapacity(n)
        var uniqueKeys: [UInt64] = []
        var starts: [UInt32] = []
        var counts: [UInt32] = []
        for (slot, entry) in keyed.enumerated() {
            sortedPositions.append(positions[entry.index])
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
            supportSquared: support * support, inv2s2: 1 / (2 * support * support),
            queryCount: UInt32(queries.count), cellCount: UInt32(uniqueKeys.count))

        let device = context.device
        let posStride = MemoryLayout<SIMD3<Float>>.stride
        guard let positionBuffer = device.makeBuffer(
                bytes: sortedPositions, length: n * posStride, options: .storageModeShared),
              let normalBuffer = device.makeBuffer(
                bytes: sortedNormals, length: n * posStride, options: .storageModeShared),
              let keyBuffer = device.makeBuffer(
                bytes: uniqueKeys, length: uniqueKeys.count * MemoryLayout<UInt64>.stride,
                options: .storageModeShared),
              let startBuffer = device.makeBuffer(
                bytes: starts, length: starts.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared),
              let countBuffer = device.makeBuffer(
                bytes: counts, length: counts.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared),
              let queryBuffer = device.makeBuffer(
                bytes: queries, length: queries.count * posStride, options: .storageModeShared),
              let outBuffer = device.makeBuffer(
                length: queries.count * MemoryLayout<Float>.stride, options: .storageModeShared),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(positionBuffer, offset: 0, index: 0)
        encoder.setBuffer(normalBuffer, offset: 0, index: 1)
        encoder.setBuffer(keyBuffer, offset: 0, index: 2)
        encoder.setBuffer(startBuffer, offset: 0, index: 3)
        encoder.setBuffer(countBuffer, offset: 0, index: 4)
        encoder.setBuffer(queryBuffer, offset: 0, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<FieldUniforms>.stride, index: 6)
        encoder.setBuffer(outBuffer, offset: 0, index: 7)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: queries.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let out = outBuffer.contents().bindMemory(to: Float.self, capacity: queries.count)
        return Array(UnsafeBufferPointer(start: out, count: queries.count))
    }
}
