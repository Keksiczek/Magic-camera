//
//  ScanDensityMap.swift
//  Magic Camera
//
//  Live "scan more here" signal: flags the points of the capture overlay that
//  sit in UNDER-SAMPLED surface regions, so sparse far walls light up red while
//  the user is still sweeping — before they hit Finish and find the model holed
//  or soft there. The coverage ring can't see this (it tracks camera angles, not
//  surface density; a holed wall still read "80 % covered").
//
//  The density judgment is physical, not statistical: the recorder fuses one
//  point per voxel, so a fully-scanned surface crossing a coarse cell face
//  carries ≈ (coarse/voxel)² points. The overlay is a uniform stride of the full
//  cloud, which preserves relative density — scaling the expectation by the
//  sample ratio makes the test valid on the subsample. Cells at the scan
//  frontier are ignored (everything is momentarily "sparse" at the growing edge;
//  painting it red would just chase the user's hand).
//
//  Pure value math, ARKit-free, runs on the AR coordinator's processing queue.
//

import simd

enum ScanDensityMap {
    /// Per-point flags (index-aligned to `positions`): true = this point lies in
    /// an interior surface region sampled well below the voxel-full density.
    /// Returns nil when the subsample is too thin to judge (expected points per
    /// cell < 3) — no hints beat wrong hints.
    ///
    /// - sampleRatio: overlay count / full cloud count (uniform stride assumed).
    /// - coarseCell: judgment granularity — 20 cm reads as "a patch of wall".
    /// - sparseFraction: flag below this fraction of the expected full density.
    static func sparseFlags(positions: [SIMD3<Float>], voxelSize: Float,
                            sampleRatio: Float,
                            coarseCell: Float = 0.2,
                            sparseFraction: Float = 0.35) -> [Bool]? {
        let n = positions.count
        guard n > 0, voxelSize > 0, sampleRatio > 0, coarseCell > voxelSize else { return nil }
        let expectedFull = (coarseCell / voxelSize) * (coarseCell / voxelSize)
        let expected = expectedFull * min(sampleRatio, 1)
        guard expected >= 3 else { return nil }
        let threshold = expected * sparseFraction

        let invCell = 1 / coarseCell
        @inline(__always) func key(_ p: SIMD3<Float>) -> Int64 {
            let x = Int64((p.x * invCell).rounded(.down)) &+ 0xFFFFF
            let y = Int64((p.y * invCell).rounded(.down)) &+ 0xFFFFF
            let z = Int64((p.z * invCell).rounded(.down)) &+ 0xFFFFF
            return (x << 42) | (y << 21) | z
        }

        var counts: [Int64: Int32] = [:]
        counts.reserveCapacity(n / 4)
        var keys = [Int64](repeating: 0, count: n)
        for i in 0..<n {
            let k = key(positions[i])
            keys[i] = k
            counts[k, default: 0] += 1
        }

        // A cell is judged only when it's interior to the scanned region — has
        // occupied neighbours on most sides. The frontier ring (and isolated
        // specks) stay unflagged.
        var sparseCells = Set<Int64>()
        for (cell, count) in counts where Float(count) < threshold {
            var occupied = 0
            var dx: Int64 = -1
            while dx <= 1 {
                var dy: Int64 = -1
                while dy <= 1 {
                    var dz: Int64 = -1
                    while dz <= 1 {
                        if dx != 0 || dy != 0 || dz != 0 {
                            let neighbor = cell &+ (dx << 42) &+ (dy << 21) &+ dz
                            if counts[neighbor] != nil { occupied += 1 }
                        }
                        dz += 1
                    }
                    dy += 1
                }
                dx += 1
            }
            if occupied >= 5 { sparseCells.insert(cell) }
        }
        guard !sparseCells.isEmpty else { return nil }

        var flags = [Bool](repeating: false, count: n)
        for i in 0..<n where sparseCells.contains(keys[i]) { flags[i] = true }
        return flags
    }
}
