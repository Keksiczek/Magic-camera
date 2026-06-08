//
//  PointCloud.swift
//  Magic Camera
//
//  Plain value type holding the accumulated scan points (position + colour +
//  confidence), plus a voxel grid used to bound density and to support a cheap
//  neighbour-occupancy outlier filter. ARKit-free, so it is unit-testable.
//

import simd

struct PointCloud {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var colors: [SIMD3<Float>] = []       // linear-ish RGB 0...1
    private(set) var confidences: [Float] = []         // 0, 0.5, 1.0

    var count: Int { positions.count }
    var isEmpty: Bool { positions.isEmpty }

    mutating func append(position: SIMD3<Float>, color: SIMD3<Float>, confidence: Float) {
        positions.append(position)
        colors.append(color)
        confidences.append(confidence)
    }

    mutating func removeAll() {
        positions.removeAll(keepingCapacity: true)
        colors.removeAll(keepingCapacity: true)
        confidences.removeAll(keepingCapacity: true)
    }

    func boundingBox() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = positions.first else { return nil }
        var lo = first, hi = first
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    func centroid() -> SIMD3<Float> {
        guard !positions.isEmpty else { return .zero }
        var sum = SIMD3<Float>.zero
        for p in positions { sum += p }
        return sum / Float(positions.count)
    }
}

/// Tracks which voxels are occupied so we keep at most one point per voxel — a
/// cheap spatial downsample that bounds memory and enables outlier filtering.
struct VoxelGrid {
    let voxelSize: Float
    private var occupied: Set<SIMD3<Int32>> = []

    init(voxelSize: Float) {
        self.voxelSize = max(voxelSize, 0.0001)
    }

    private func key(for position: SIMD3<Float>) -> SIMD3<Int32> {
        let scaled = position / voxelSize
        return SIMD3<Int32>(Int32(scaled.x.rounded(.down)),
                            Int32(scaled.y.rounded(.down)),
                            Int32(scaled.z.rounded(.down)))
    }

    mutating func insert(_ position: SIMD3<Float>) -> Bool {
        occupied.insert(key(for: position)).inserted
    }

    /// Number of occupied voxels in the 3x3x3 block around `position`
    /// (includes the point's own cell, so an isolated point returns 1).
    func occupiedNeighborCount(of position: SIMD3<Float>) -> Int {
        let k = key(for: position)
        var count = 0
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let neighbor = SIMD3<Int32>(k.x + Int32(dx), k.y + Int32(dy), k.z + Int32(dz))
                    if occupied.contains(neighbor) { count += 1 }
                }
            }
        }
        return count
    }

    var occupiedCount: Int { occupied.count }

    mutating func reset() { occupied.removeAll(keepingCapacity: true) }
}
