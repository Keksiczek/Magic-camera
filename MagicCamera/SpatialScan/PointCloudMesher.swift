//
//  PointCloudMesher.swift
//  Magic Camera
//
//  Reconstructs an approximate watertight surface from a coloured point cloud
//  without any external reconstruction library:
//
//    1. Voxelise the cloud into an occupancy set.
//    2. Morphological closing (dilate → erode) to bridge small gaps.
//    3. Exposed-face meshing: emit a quad only between an occupied voxel and an
//       empty neighbour, sharing vertices on the integer lattice.
//    4. Laplacian smoothing to round the blocky cubes into an organic surface.
//    5. Smooth per-vertex normals from accumulated face normals.
//
//  Pure value-type math (ARKit-free) so it runs off the main thread and is
//  unit-testable. The result is an unclassified `MeshData`, shown shaded and
//  exportable/AR-viewable like any captured mesh.
//

import simd

enum PointCloudMesher {
    /// Reconstructs a surface mesh, or `nil` when the cloud is too sparse/large.
    /// `resolution` is the approximate number of voxels along the longest axis.
    static func reconstruct(_ cloud: PointCloud,
                            resolution: Int = 80,
                            smoothingIterations: Int = 4) -> MeshData? {
        guard cloud.count >= 50, let box = cloud.boundingBox() else { return nil }
        let extent = box.max - box.min
        let maxExtent = max(max(extent.x, extent.y), extent.z)
        guard maxExtent > 0 else { return nil }

        // Floor binds only for small subjects (extent < resolution × floor);
        // 2 mm lets an Object-mode capture keep its fine detail. Room-scale
        // scans use maxExtent/resolution, well above the floor.
        let voxel = max(maxExtent / Float(max(resolution, 8)), 0.002)
        let origin = box.min

        // 1. Occupancy.
        var occupied = Set<SIMD3<Int32>>()
        occupied.reserveCapacity(cloud.count)
        for p in cloud.positions {
            occupied.insert(voxelKey(p, origin: origin, voxel: voxel))
        }
        guard !occupied.isEmpty, occupied.count < 2_000_000 else { return nil }

        // 2. Closing — only when the set is small enough to keep it cheap.
        if occupied.count < 400_000 {
            occupied = closed(occupied)
        }

        // 3. Exposed-face meshing with shared lattice vertices.
        var vertexIndex = [SIMD3<Int32>: UInt32](minimumCapacity: occupied.count)
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        func vertex(_ lattice: SIMD3<Int32>) -> UInt32 {
            if let existing = vertexIndex[lattice] { return existing }
            let index = UInt32(vertices.count)
            vertexIndex[lattice] = index
            let offset = SIMD3<Float>(Float(lattice.x), Float(lattice.y), Float(lattice.z))
            vertices.append(origin + offset * voxel)
            return index
        }

        for key in occupied {
            for face in Face.all where !occupied.contains(key &+ face.direction) {
                let v0 = vertex(key &+ face.corners.0)
                let v1 = vertex(key &+ face.corners.1)
                let v2 = vertex(key &+ face.corners.2)
                let v3 = vertex(key &+ face.corners.3)
                indices.append(contentsOf: [v0, v1, v2, v0, v2, v3])
            }
        }
        guard vertices.count >= 3, indices.count >= 3 else { return nil }

        // 4. Smoothing.
        if smoothingIterations > 0 {
            vertices = smoothed(vertices: vertices, indices: indices,
                                iterations: smoothingIterations)
        }

        // 5. Normals.
        let normals = computeNormals(vertices: vertices, indices: indices)
        return MeshData(vertices: vertices, normals: normals, indices: indices)
    }

    // MARK: - Voxel helpers

    private static func voxelKey(_ p: SIMD3<Float>, origin: SIMD3<Float>,
                                 voxel: Float) -> SIMD3<Int32> {
        let s = (p - origin) / voxel
        return SIMD3<Int32>(Int32(s.x.rounded(.down)),
                            Int32(s.y.rounded(.down)),
                            Int32(s.z.rounded(.down)))
    }

    private static let neighbors6: [SIMD3<Int32>] = [
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0),
        SIMD3(0, 1, 0), SIMD3(0, -1, 0),
        SIMD3(0, 0, 1), SIMD3(0, 0, -1)
    ]

    /// Morphological closing (dilate then erode) over a 6-neighbourhood — fills
    /// pinholes between sparsely sampled points while roughly preserving size.
    private static func closed(_ set: Set<SIMD3<Int32>>) -> Set<SIMD3<Int32>> {
        var dilated = set
        dilated.reserveCapacity(set.count * 4)
        for key in set {
            for d in neighbors6 { dilated.insert(key &+ d) }
        }
        var eroded = Set<SIMD3<Int32>>()
        eroded.reserveCapacity(set.count)
        for key in dilated {
            var keep = true
            for d in neighbors6 where !dilated.contains(key &+ d) { keep = false; break }
            if keep { eroded.insert(key) }
        }
        return eroded.isEmpty ? set : eroded
    }

    // MARK: - Smoothing & normals

    private static func smoothed(vertices: [SIMD3<Float>], indices: [UInt32],
                                 iterations: Int) -> [SIMD3<Float>] {
        var adjacency = [Set<UInt32>](repeating: [], count: vertices.count)
        var i = 0
        while i + 2 < indices.count {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            adjacency[Int(a)].insert(b); adjacency[Int(a)].insert(c)
            adjacency[Int(b)].insert(a); adjacency[Int(b)].insert(c)
            adjacency[Int(c)].insert(a); adjacency[Int(c)].insert(b)
            i += 3
        }

        let lambda: Float = 0.5
        var current = vertices
        for _ in 0..<iterations {
            var next = current
            for v in 0..<current.count {
                let neighbours = adjacency[v]
                guard !neighbours.isEmpty else { continue }
                var sum = SIMD3<Float>.zero
                for n in neighbours { sum += current[Int(n)] }
                let average = sum / Float(neighbours.count)
                next[v] = current[v] + (average - current[v]) * lambda
            }
            current = next
        }
        return current
    }

    private static func computeNormals(vertices: [SIMD3<Float>],
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

    // MARK: - Cube faces (corner order is CCW as seen from outside)

    private struct Face {
        let direction: SIMD3<Int32>
        let corners: (SIMD3<Int32>, SIMD3<Int32>, SIMD3<Int32>, SIMD3<Int32>)

        static let all: [Face] = [
            Face(direction: SIMD3(1, 0, 0),
                 corners: (SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(1, 1, 1), SIMD3(1, 0, 1))),
            Face(direction: SIMD3(-1, 0, 0),
                 corners: (SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(0, 1, 0))),
            Face(direction: SIMD3(0, 1, 0),
                 corners: (SIMD3(0, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, 0))),
            Face(direction: SIMD3(0, -1, 0),
                 corners: (SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1))),
            Face(direction: SIMD3(0, 0, 1),
                 corners: (SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1))),
            Face(direction: SIMD3(0, 0, -1),
                 corners: (SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 0, 0)))
        ]
    }
}
