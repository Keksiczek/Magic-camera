//
//  MeshHoleFiller.swift
//  Magic Camera
//
//  Fills small boundary holes in a triangle mesh. Boundary loops (chains of
//  half-edges that have no opposite) are traced and each loop up to
//  `maxHoleEdges` edges is capped by fanning to a new centroid vertex, with
//  winding chosen so the patch stays manifold with the surrounding surface.
//  Larger boundaries — e.g. the open back of a one-sided scan — are left alone.
//
//  Best for small, roughly planar gaps (a centroid fan can fold on a highly
//  non-planar hole). Pure simd math, ARKit-free and off-main-thread friendly.
//

import simd

enum MeshHoleFiller {
    /// Caps the open bottom left after cutting the floor away (object
    /// isolation / structure removal). Boundary loops that sit low in the
    /// mesh and are roughly flat get a centroid fan regardless of size —
    /// unlike `fill`, which deliberately skips big openings.
    static func closeBase(_ mesh: MeshData) -> MeshData {
        guard let box = mesh.boundingBox() else { return mesh }
        let height = max(box.max.y - box.min.y, 1e-3)
        return fill(mesh, maxHoleEdges: 100_000) { loop, vertices in
            var minY = Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude
            var meanY: Float = 0
            for v in loop {
                let y = vertices[Int(v)].y
                minY = min(minY, y); maxY = max(maxY, y); meanY += y
            }
            meanY /= Float(loop.count)
            // Low in the mesh, and flat (a floor cut, not the open back of a
            // one-sided scan, which spans the full height).
            return meanY <= box.min.y + 0.3 * height
                && (maxY - minY) <= max(0.15 * height, 0.05)
        }
    }

    static func fill(_ mesh: MeshData, maxHoleEdges: Int = 80,
                     loopFilter: ([UInt32], [SIMD3<Float>]) -> Bool = { _, _ in true }) -> MeshData {
        // Weld duplicated vertices first: on a per-corner duplicated mesh
        // (textured saves, USDZ imports) every edge looks like a boundary,
        // and "hole filling" would double the whole surface.
        let mesh = mesh.weldingDuplicateVertices()
        guard mesh.indices.count >= 3, maxHoleEdges >= 3 else { return mesh }

        @inline(__always) func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            (UInt64(a) << 32) | UInt64(b)
        }

        // All directed edges present in the mesh.
        var directed = Set<UInt64>()
        directed.reserveCapacity(mesh.indices.count)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
            directed.insert(key(a, b)); directed.insert(key(b, c)); directed.insert(key(c, a))
            i += 3
        }

        // A boundary half-edge u→v has no opposite v→u. On a clean boundary each
        // vertex has exactly one outgoing boundary edge, so this maps the loop.
        var nextOnBoundary = [UInt32: UInt32](minimumCapacity: 64)
        for e in directed {
            let a = UInt32(e >> 32), b = UInt32(e & 0xFFFF_FFFF)
            if !directed.contains(key(b, a)) { nextOnBoundary[a] = b }
        }
        guard !nextOnBoundary.isEmpty else { return mesh }   // closed mesh

        var vertices = mesh.vertices
        let hasNormals = mesh.normals.count == mesh.vertices.count
        var normals = hasNormals ? mesh.normals : []
        let hasClass = mesh.hasClassification
        var classifications = hasClass ? mesh.classifications : []
        var indices = mesh.indices

        var visited = Set<UInt32>(minimumCapacity: nextOnBoundary.count)
        var filledAny = false

        for start in nextOnBoundary.keys where !visited.contains(start) {
            // Trace the boundary loop from `start`.
            var loop: [UInt32] = []
            var current = start
            var closed = false
            while !visited.contains(current) {
                visited.insert(current)
                loop.append(current)
                guard let nxt = nextOnBoundary[current] else { break }   // dangling chain
                current = nxt
                if current == start { closed = true; break }
                if loop.count > maxHoleEdges { break }                   // too large to fill
            }
            guard closed, loop.count >= 3, loop.count <= maxHoleEdges,
                  loopFilter(loop, vertices) else { continue }

            // New centroid vertex for the fan.
            var centroid = SIMD3<Float>.zero
            for v in loop { centroid += vertices[Int(v)] }
            centroid /= Float(loop.count)
            let center = UInt32(vertices.count)
            vertices.append(centroid)
            if hasNormals {
                var n = SIMD3<Float>.zero
                for v in loop { n += normals[Int(v)] }
                normals.append(simd_length(n) > 1e-6 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0))
            }
            if hasClass { classifications.append(classifications[Int(loop[0])]) }

            // Fan: each boundary edge u→v is capped by triangle (v, u, center), so
            // the edge u↔v becomes shared (manifold) with the original triangle.
            for k in 0..<loop.count {
                let u = loop[k]
                let v = loop[(k + 1) % loop.count]
                indices.append(contentsOf: [v, u, center])
            }
            filledAny = true
        }

        guard filledAny else { return mesh }
        return MeshData(vertices: vertices, normals: normals,
                        indices: indices, classifications: hasClass ? classifications : [])
    }
}
