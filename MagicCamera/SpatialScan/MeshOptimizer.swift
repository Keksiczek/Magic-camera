//
//  MeshOptimizer.swift
//  Magic Camera
//
//  Post-processes a captured mesh into a cleaner output: Taubin smoothing
//  (alternating λ / μ passes) softens the stair-stepping of LiDAR meshes without
//  the shrinkage of plain Laplacian smoothing, then normals are recomputed.
//  Topology (indices) and per-vertex classifications are preserved, so the
//  result stays compatible with the surface-type colouring and crop tools.
//
//  Pure value-type math, ARKit-free — runs off the main thread.
//

import simd

enum MeshOptimizer {
    /// Smooths a mesh in place over `iterations` Taubin pairs. Returns the input
    /// unchanged when it is too small to process.
    ///
    /// The input is index-welded first: textured saves and imported USDZ carry
    /// per-corner duplicated vertices, and index-based adjacency on such a
    /// "soup" leaves every vertex connected only to its own triangle — each
    /// triangle then contracts toward its centroid and the surface cracks open
    /// along every edge (visible as straight empty lines on lattice meshes).
    static func smooth(_ mesh: MeshData, iterations: Int = 6) -> MeshData {
        let mesh = mesh.weldingDuplicateVertices()
        guard mesh.count >= 4, mesh.indices.count >= 3 else { return mesh }

        let adjacency = buildAdjacency(vertexCount: mesh.count, indices: mesh.indices)
        // Open scan edges (edges on a single triangle) are the model's real
        // silhouette, not noise. Smoothing them like interior vertices curls and
        // shrinks the rim inward — a visible quality loss on the partial meshes a
        // hand-held scan produces. Pin those boundary vertices in place.
        let boundary = boundaryVertices(vertexCount: mesh.count, indices: mesh.indices)
        var vertices = mesh.vertices

        // Taubin: a positive shrink pass followed by a negative inflate pass keeps
        // the surface from collapsing toward its centroid.
        let lambda: Float = 0.50
        let mu: Float = -0.53
        for _ in 0..<max(iterations, 1) {
            vertices = relax(vertices, adjacency: adjacency, boundary: boundary, factor: lambda)
            vertices = relax(vertices, adjacency: adjacency, boundary: boundary, factor: mu)
        }

        let normals = recomputeNormals(vertices: vertices, indices: mesh.indices)
        return MeshData(vertices: vertices, normals: normals,
                        indices: mesh.indices, classifications: mesh.classifications)
    }

    // MARK: - Helpers

    private static func buildAdjacency(vertexCount: Int, indices: [UInt32]) -> [[UInt32]] {
        var sets = [Set<UInt32>](repeating: [], count: vertexCount)
        var i = 0
        while i + 2 < indices.count {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            sets[Int(a)].insert(b); sets[Int(a)].insert(c)
            sets[Int(b)].insert(a); sets[Int(b)].insert(c)
            sets[Int(c)].insert(a); sets[Int(c)].insert(b)
            i += 3
        }
        return sets.map { Array($0) }
    }

    private static func relax(_ vertices: [SIMD3<Float>],
                              adjacency: [[UInt32]], boundary: [Bool],
                              factor: Float) -> [SIMD3<Float>] {
        var output = vertices
        for v in 0..<vertices.count {
            if boundary[v] { continue }   // pinned: keep the open rim crisp
            let neighbours = adjacency[v]
            guard !neighbours.isEmpty else { continue }
            var sum = SIMD3<Float>.zero
            for n in neighbours { sum += vertices[Int(n)] }
            let average = sum / Float(neighbours.count)
            output[v] = vertices[v] + (average - vertices[v]) * factor
        }
        return output
    }

    /// Marks vertices touching a boundary edge — an edge used by exactly one
    /// triangle. The open border of a partial scan; pinned during smoothing.
    private static func boundaryVertices(vertexCount: Int, indices: [UInt32]) -> [Bool] {
        var edgeUses = [UInt64: Int](minimumCapacity: indices.count)
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
            return (lo << 32) | hi
        }
        var i = 0
        while i + 2 < indices.count {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            edgeUses[key(a, b), default: 0] += 1
            edgeUses[key(b, c), default: 0] += 1
            edgeUses[key(a, c), default: 0] += 1
            i += 3
        }
        var boundary = [Bool](repeating: false, count: vertexCount)
        for (edge, uses) in edgeUses where uses == 1 {
            boundary[Int(edge >> 32)] = true
            boundary[Int(edge & 0xFFFF_FFFF)] = true
        }
        return boundary
    }

    private static func recomputeNormals(vertices: [SIMD3<Float>],
                                         indices: [UInt32]) -> [SIMD3<Float>] {
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
