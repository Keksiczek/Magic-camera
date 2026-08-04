//
//  MeshComponents.swift
//  Magic Camera
//
//  Connectivity as object identity. A scan holding two objects reconstructs as
//  two disjoint connected components; this is what turns those components back
//  into separate things the app can name, move, colour and export.
//
//  Why connectivity rather than a per-point label carried down from selection:
//  a label cannot survive marching cubes, which invents its vertices from a
//  scalar field and has no source point to inherit from. Carrying one would
//  mean threading a channel through every producer of a new `MeshData` — there
//  are dozens — where each miss drops identity silently and nothing fails
//  loudly. Connectivity is DERIVED, so it cannot go stale: every transform in
//  the pipeline is either per-vertex (preserves components) or a triangle
//  subset (splits them, never welds two).
//
//  What it cannot do is separate two objects that physically touch — which is
//  also the one case no selection gesture can separate, since they are one
//  cluster in the cloud too. Studio's "Separate parts" covers the rest.
//

import Foundation
import simd

extension MeshData {

    /// One connected component, plus the maps back to the mesh it came from so
    /// index-aligned side channels (UVs, per-triangle atlas pages) can follow
    /// the same split.
    struct ComponentSlice {
        var mesh: MeshData
        /// New vertex → source vertex.
        var sourceVertices: [UInt32]
        /// New triangle → source triangle.
        var sourceTriangles: [Int32]
    }

    /// Per-triangle component label, and the triangle count of each label.
    /// Labels are dense (`0..<sizes.count`) and ordered LARGEST FIRST, so label
    /// 0 is always the main body.
    ///
    /// Connectivity is computed on WELDED positions (bit-identical vertices are
    /// one vertex) but reported per ORIGINAL triangle. A baked or exported mesh
    /// is duplicated-corner soup, which reads as thousands of isolated
    /// triangles unless welded first (see [[soup-mesh-weld-rule]]); reporting
    /// per original triangle means the caller gets real connectivity without
    /// having to weld and lose its per-corner UVs.
    func triangleComponents() -> (labelOfTri: [Int32], sizes: [Int]) {
        let triCount = indices.count / 3
        guard triCount > 0, !vertices.isEmpty else { return ([], []) }

        var canonical = [SIMD3<Float>: Int32](minimumCapacity: vertices.count)
        var welded = [Int32](repeating: 0, count: vertices.count)
        var weldedCount: Int32 = 0
        for i in 0..<vertices.count {
            let p = vertices[i]
            if let existing = canonical[p] {
                welded[i] = existing
            } else {
                canonical[p] = weldedCount
                welded[i] = weldedCount
                weldedCount += 1
            }
        }

        var parent = Array(0..<Int(weldedCount))
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var t = 0
        while t + 2 < indices.count {
            let a = Int(welded[Int(indices[t])])
            let b = Int(welded[Int(indices[t + 1])])
            let c = Int(welded[Int(indices[t + 2])])
            union(a, b); union(b, c)
            t += 3
        }

        var rootOfTri = [Int](repeating: 0, count: triCount)
        var countByRoot = [Int: Int]()
        t = 0
        var ti = 0
        while t + 2 < indices.count {
            let root = find(Int(welded[Int(indices[t])]))
            rootOfTri[ti] = root
            countByRoot[root, default: 0] += 1
            t += 3; ti += 1
        }
        // Dictionary order is not stable, so break size ties on the root index —
        // otherwise the same mesh could label its components differently between
        // runs and a "second object" would change identity for no reason.
        let ordered = countByRoot.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }
        var labelOfRoot = [Int: Int32](minimumCapacity: ordered.count)
        for (i, entry) in ordered.enumerated() { labelOfRoot[entry.key] = Int32(i) }
        return (rootOfTri.map { labelOfRoot[$0] ?? 0 }, ordered.map { $0.value })
    }

    /// Splits into separate objects along connectivity, largest first.
    ///
    /// A component earns its own object when it carries at least `minTriangles`
    /// AND at least `minFractionOfLargest` of the main body — a scan of two
    /// objects becomes two, a room with thirty reconstruction specks stays one.
    /// Everything under the bar (and everything past `maxCount`) folds into the
    /// main body rather than being dropped: a speck is not worth its own object,
    /// but silently deleting geometry the caller handed over is not this
    /// function's decision either — `removingSmallComponents` is the tool that
    /// removes, and it has its own guard.
    ///
    /// Returns a single slice (the whole mesh) when nothing qualifies, so
    /// callers can always use the result unconditionally.
    func componentSlices(minTriangles: Int = 24,
                         minFractionOfLargest: Float = 0.004,
                         maxCount: Int = 16) -> [ComponentSlice] {
        guard !isEmpty else { return [] }
        let (labelOfTri, sizes) = triangleComponents()
        guard sizes.count > 1, let largest = sizes.first else { return [wholeSlice()] }

        let floorTris = max(minTriangles, Int(Float(largest) * minFractionOfLargest))
        // Labels are size-ordered, so the qualifying set is a prefix.
        var keepCount = 0
        for size in sizes {
            guard size >= floorTris, keepCount < maxCount else { break }
            keepCount += 1
        }
        guard keepCount > 1 else { return [wholeSlice()] }

        var groups = [[Int32]](repeating: [], count: keepCount)
        var ti = 0
        while ti < labelOfTri.count {
            let label = Int(labelOfTri[ti])
            groups[label < keepCount ? label : 0].append(Int32(ti))
            ti += 1
        }
        return groups.map { slice(triangles: $0) }
    }

    /// The component meshes alone — the common case, when no side channel has to
    /// follow the split.
    func separatedComponents(minTriangles: Int = 24,
                             minFractionOfLargest: Float = 0.004,
                             maxCount: Int = 16) -> [MeshData] {
        componentSlices(minTriangles: minTriangles,
                        minFractionOfLargest: minFractionOfLargest,
                        maxCount: maxCount).map(\.mesh)
    }

    /// How many components would become their own object under the same rule —
    /// for callers that want to offer a split rather than perform one.
    func separableComponentCount(minTriangles: Int = 24,
                                 minFractionOfLargest: Float = 0.004,
                                 maxCount: Int = 16) -> Int {
        let (_, sizes) = triangleComponents()
        guard let largest = sizes.first else { return 0 }
        let floorTris = max(minTriangles, Int(Float(largest) * minFractionOfLargest))
        var count = 0
        for size in sizes {
            guard size >= floorTris, count < maxCount else { break }
            count += 1
        }
        return count
    }

    /// A slice holding `triangles` (source triangle indices), with the vertices
    /// they reference compacted and every per-vertex channel carried across.
    private func slice(triangles: [Int32]) -> ComponentSlice {
        let hasNormals = normals.count == vertices.count
        let hasClass = hasClassification
        var remap = [UInt32: UInt32](minimumCapacity: triangles.count * 2)
        var sourceVertices: [UInt32] = []
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newClasses: [UInt8] = []
        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(triangles.count * 3)

        func mapped(_ old: UInt32) -> UInt32 {
            if let m = remap[old] { return m }
            let m = UInt32(newVertices.count)
            remap[old] = m
            sourceVertices.append(old)
            newVertices.append(vertices[Int(old)])
            if hasNormals { newNormals.append(normals[Int(old)]) }
            if hasClass { newClasses.append(classifications[Int(old)]) }
            return m
        }

        for t in triangles {
            let base = Int(t) * 3
            newIndices.append(mapped(indices[base]))
            newIndices.append(mapped(indices[base + 1]))
            newIndices.append(mapped(indices[base + 2]))
        }
        let mesh = MeshData(vertices: newVertices, normals: newNormals,
                            indices: newIndices, classifications: hasClass ? newClasses : [])
        return ComponentSlice(mesh: mesh, sourceVertices: sourceVertices,
                              sourceTriangles: triangles)
    }

    /// The identity slice — `self`, with identity maps.
    private func wholeSlice() -> ComponentSlice {
        ComponentSlice(mesh: self,
                       sourceVertices: Array(0..<UInt32(vertices.count)),
                       sourceTriangles: Array(0..<Int32(indices.count / 3)))
    }
}

extension TexturedMesh {

    /// Splits a baked mesh into separate textured objects along connectivity.
    ///
    /// The atlas is NOT re-baked or re-packed: each part keeps the same sheets
    /// and the same UVs, and simply stops referencing the regions belonging to
    /// the others. That costs memory (every part carries every page) but it is
    /// exact — re-packing would resample the texture and lose density, which is
    /// the one thing the multi-page atlas work went to some trouble to buy.
    func separatedComponents(minTriangles: Int = 24,
                             minFractionOfLargest: Float = 0.004,
                             maxCount: Int = 16) -> [TexturedMesh] {
        let slices = mesh.componentSlices(minTriangles: minTriangles,
                                          minFractionOfLargest: minFractionOfLargest,
                                          maxCount: maxCount)
        guard slices.count > 1 else { return [self] }
        let hasUVs = uvs.count == mesh.vertices.count
        return slices.map { slice in
            let newUVs = hasUVs ? slice.sourceVertices.map { uvs[Int($0)] } : []
            let newPages = pageOfTri.isEmpty
                ? []
                : slice.sourceTriangles.map { pageOfTri[Int($0)] }
            return TexturedMesh(mesh: slice.mesh, uvs: newUVs, textures: textures,
                                textureSize: textureSize, pageOfTri: newPages)
        }
    }
}
