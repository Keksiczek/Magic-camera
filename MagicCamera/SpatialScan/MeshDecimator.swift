//
//  MeshDecimator.swift
//  Magic Camera
//
//  Reduces triangle count by vertex clustering: vertices falling in the same grid
//  cell collapse to their average, triangles are remapped, and degenerate ones are
//  dropped. Simple and robust (no quadric error metrics) — good for lighter,
//  more portable exports. Preserves per-vertex classification (majority per cell).
//

import simd

enum MeshDecimator {
    /// Clusters vertices onto a grid of roughly `gridResolution` cells along the
    /// longest axis. Lower resolution = fewer triangles.
    static func decimate(_ mesh: MeshData, gridResolution: Int = 96) -> MeshData {
        guard mesh.count >= 4, mesh.indices.count >= 3, let box = mesh.boundingBox() else { return mesh }
        let extent = box.max - box.min
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        guard maxExtent > 0 else { return mesh }
        let cell = max(maxExtent / Float(max(gridResolution, 4)), 0.002)
        let origin = box.min
        let hasClass = mesh.hasClassification

        var cluster = [SIMD3<Int32>: UInt32](minimumCapacity: mesh.count / 2)
        var sums: [SIMD3<Float>] = []
        var counts: [Float] = []
        var classVotes: [[UInt8: Int]] = []
        var remap = [UInt32](repeating: 0, count: mesh.count)

        for i in 0..<mesh.count {
            let key = cellKey(mesh.vertices[i], origin: origin, cell: cell)
            if let idx = cluster[key] {
                sums[Int(idx)] += mesh.vertices[i]
                counts[Int(idx)] += 1
                if hasClass { classVotes[Int(idx)][mesh.classifications[i], default: 0] += 1 }
                remap[i] = idx
            } else {
                let idx = UInt32(sums.count)
                cluster[key] = idx
                sums.append(mesh.vertices[i])
                counts.append(1)
                classVotes.append(hasClass ? [mesh.classifications[i]: 1] : [:])
                remap[i] = idx
            }
        }

        let newVertices = (0..<sums.count).map { sums[$0] / counts[$0] }

        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(mesh.indices.count)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = remap[Int(mesh.indices[t])]
            let b = remap[Int(mesh.indices[t + 1])]
            let c = remap[Int(mesh.indices[t + 2])]
            if a != b, b != c, a != c {
                newIndices.append(a); newIndices.append(b); newIndices.append(c)
            }
            t += 3
        }
        guard !newIndices.isEmpty else { return mesh }

        let classifications: [UInt8] = hasClass
            ? classVotes.map { votes in votes.max(by: { $0.value < $1.value })?.key ?? 0 }
            : []
        let normals = computeNormals(vertices: newVertices, indices: newIndices)
        return MeshData(vertices: newVertices, normals: normals,
                        indices: newIndices, classifications: classifications)
    }

    private static func cellKey(_ p: SIMD3<Float>, origin: SIMD3<Float>, cell: Float) -> SIMD3<Int32> {
        let s = (p - origin) / cell
        return SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
    }

    private static func computeNormals(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let faceNormal = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            normals[a] += faceNormal; normals[b] += faceNormal; normals[c] += faceNormal
            i += 3
        }
        for v in 0..<normals.count {
            let length = simd_length(normals[v])
            normals[v] = length > 1e-6 ? normals[v] / length : SIMD3<Float>(0, 1, 0)
        }
        return normals
    }
}
