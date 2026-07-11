//
//  MeshCloudSnap.swift
//  Magic Camera
//
//  Anchors a reconstructed mesh back onto the captured point cloud. The fused
//  cloud is the cleanest shape the pipeline ever has ("cloudy si drží hezčí
//  tvary") — the field + marching lattice then add per-face crinkle the cloud
//  never had: a device room measured 22% of its mesh edges over 41° dihedral
//  while the cloud read visibly smooth, and blind Taubin smoothing plateaued
//  at ~14% (the creases are structured, not jitter — e.g. the lattice zig-
//  zagging between double-fused layers).
//
//  Each interior vertex moves ALONG ITS NORMAL to the Gaussian-weighted mean
//  of the nearby cloud points — an MLS-style projection: crinkle (normal-
//  direction error) is pulled flat onto the data while tangential positions,
//  and therefore triangle shapes, stay put. Vertices with no cloud support
//  (hole-fill patches, gap closures) and open-rim vertices don't move.
//
//  Pure value math, off-main. Runs after the fills (final topology), before
//  texturing — the bake then projects photos onto the data-true surface.
//

import simd

enum MeshCloudSnap {
    struct Stats {
        var moved = 0
        var total = 0
        var meanShiftMM: Float = 0
    }

    /// Max distance a vertex may be pulled — beyond this the local cloud is
    /// probably a different surface (or the vertex belongs to a fill patch).
    private static let maxShift: Float = 0.03

    /// Snaps `mesh` onto `cloud`. `spacing` is the cloud's mean point spacing
    /// (measured by the caller, which usually has it already); the gather
    /// radius scales from it so dense close-up clouds snap tightly and sparse
    /// room clouds still find support.
    static func snap(_ mesh: MeshData, to cloud: PointCloud,
                     spacing: Float) -> (mesh: MeshData, stats: Stats) {
        var stats = Stats()
        let vertexCount = mesh.vertices.count
        guard vertexCount > 0, cloud.count > 1_000, spacing > 0 else {
            return (mesh, stats)
        }
        let radius = min(max(spacing * 2.5, 0.015), 0.05)
        let invCell = 1 / radius
        let sigma2 = (radius * 0.6) * (radius * 0.6)

        // Cloud grid hash, one cell per gather radius.
        var grid = [SIMD3<Int32>: [Int32]](minimumCapacity: cloud.count / 4)
        for i in 0..<cloud.count {
            let p = cloud.positions[i]
            let key = SIMD3<Int32>(Int32((p.x * invCell).rounded(.down)),
                                   Int32((p.y * invCell).rounded(.down)),
                                   Int32((p.z * invCell).rounded(.down)))
            grid[key, default: []].append(Int32(i))
        }

        // Area-weighted vertex normals + open-rim detection.
        var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var edgeCount = [UInt64: Int](minimumCapacity: mesh.indices.count)
        let triCount = mesh.indices.count / 3
        for t in 0..<triCount {
            let i0 = mesh.indices[t * 3], i1 = mesh.indices[t * 3 + 1], i2 = mesh.indices[t * 3 + 2]
            let cross = simd_cross(mesh.vertices[Int(i1)] - mesh.vertices[Int(i0)],
                                   mesh.vertices[Int(i2)] - mesh.vertices[Int(i0)])
            normals[Int(i0)] += cross; normals[Int(i1)] += cross; normals[Int(i2)] += cross
            for (u, v) in [(i0, i1), (i1, i2), (i2, i0)] {
                let key = (UInt64(max(u, v)) << 32) | UInt64(min(u, v))
                edgeCount[key, default: 0] += 1
            }
        }
        var boundary = [Bool](repeating: false, count: vertexCount)
        for (key, count) in edgeCount where count == 1 {
            boundary[Int(key >> 32)] = true
            boundary[Int(key & 0xFFFF_FFFF)] = true
        }

        var vertices = mesh.vertices
        var shiftSum: Float = 0
        for v in 0..<vertexCount where !boundary[v] {
            let nLen = simd_length(normals[v])
            guard nLen > 1e-12 else { continue }
            let n = normals[v] / nLen
            let p = vertices[v]
            let center = SIMD3<Int32>(Int32((p.x * invCell).rounded(.down)),
                                      Int32((p.y * invCell).rounded(.down)),
                                      Int32((p.z * invCell).rounded(.down)))
            var weightSum: Float = 0
            var offsetSum: Float = 0
            var supporters = 0
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                guard let bucket = grid[center &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))]
                else { continue }
                for i in bucket {
                    let q = cloud.positions[Int(i)]
                    let d = q - p
                    let dist2 = simd_length_squared(d)
                    guard dist2 < radius * radius else { continue }
                    let w = expf(-dist2 / sigma2)
                    weightSum += w
                    offsetSum += w * simd_dot(d, n)   // normal-direction error only
                    supporters += 1
                }
            } } }
            stats.total += 1
            guard supporters >= 4, weightSum > 1e-6 else { continue }
            let shift = simd_clamp(offsetSum / weightSum, -Self.maxShift, Self.maxShift)
            guard abs(shift) > 1e-5 else { continue }
            vertices[v] = p + n * shift
            stats.moved += 1
            shiftSum += abs(shift)
        }
        if stats.moved > 0 { stats.meanShiftMM = shiftSum / Float(stats.moved) * 1000 }

        var out = mesh
        out.vertices = vertices
        // Refresh shading normals to the snapped shape (same welded topology).
        if out.normals.count == vertexCount {
            var refreshed = [SIMD3<Float>](repeating: .zero, count: vertexCount)
            for t in 0..<triCount {
                let i0 = Int(mesh.indices[t * 3]), i1 = Int(mesh.indices[t * 3 + 1])
                let i2 = Int(mesh.indices[t * 3 + 2])
                let cross = simd_cross(vertices[i1] - vertices[i0], vertices[i2] - vertices[i0])
                refreshed[i0] += cross; refreshed[i1] += cross; refreshed[i2] += cross
            }
            out.normals = refreshed.map { simd_length($0) > 1e-12 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        }
        return (out, stats)
    }
}
