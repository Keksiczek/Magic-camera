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

            // Prefer an in-plane ear-clip triangulation: it adds no centroid
            // vertex and follows the surrounding surface instead of folding the
            // hole into a cone, so elongated or gently curved gaps fill cleanly.
            // Bounded to `earClipMaxEdges` because the ear search is ~O(n²);
            // larger boundaries (e.g. a wide floor cut) fall back to the fan,
            // which is the historical behaviour and fine for a big flat cap.
            if loop.count <= earClipMaxEdges,
               let patch = earClipPatch(loop: loop, positions: vertices) {
                for tri in patch { indices.append(contentsOf: [tri.0, tri.1, tri.2]) }
                filledAny = true
                continue
            }

            // Fallback — centroid fan. New centroid vertex for the fan.
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

    /// Robust closer for the small NON-MANIFOLD gaps the loop-based `fill` can't
    /// touch. Plane snapping (surface cleanup) leaves T-junctions where a vertex
    /// carries several boundary edges, so no clean loop forms and the loop tracer
    /// skips the hole — the scattered empty triangles left on a well-scanned wall
    /// (a device room reported 527 sub-0.5 m holes still open, 1.7% non-manifold
    /// edges, after `fill`). This works on the boundary GRAPH instead of tracing
    /// loops: it groups the open edges into connected components and fans each
    /// spatially SMALL component shut from its centroid, whatever its topology.
    /// Real openings (the room's open front, windows — large components) are left
    /// alone. Winding is best-effort; the material is double-sided, so a fanned
    /// patch is opaque either way. Pure simd, off-main friendly.
    ///
    /// `maxDiameter` defaults to a fraction of the mesh's own diagonal rather than
    /// a fixed 0.4 m: on a room that lands at the same ~0.4 m, but on a small object
    /// a fixed gate is wider than the subject itself and would web over its real
    /// openings (a mug's rim, a handle's gap). Scale-relative keeps one rule honest
    /// for both, so the manual "Fill holes" is safe on any mesh.
    static func closeSmallGaps(_ mesh: MeshData, maxDiameter: Float? = nil,
                               maxComponentEdges: Int = 200) -> MeshData {
        let mesh = mesh.weldingDuplicateVertices()
        guard mesh.indices.count >= 3 else { return mesh }
        let gate: Float = maxDiameter ?? {
            guard let box = mesh.boundingBox() else { return 0.4 }
            return min(0.4, simd_distance(box.min, box.max) * 0.06)
        }()
        @inline(__always) func ukey(_ a: UInt32, _ b: UInt32) -> UInt64 {
            let lo = min(a, b), hi = max(a, b)
            return (UInt64(lo) << 32) | UInt64(hi)
        }
        // Undirected edge use count → the open boundary edges (used exactly once).
        var edgeUse = [UInt64: Int](minimumCapacity: mesh.indices.count)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
            edgeUse[ukey(a, b), default: 0] += 1
            edgeUse[ukey(b, c), default: 0] += 1
            edgeUse[ukey(c, a), default: 0] += 1
            i += 3
        }
        var boundary: [(UInt32, UInt32)] = []
        for (k, n) in edgeUse where n == 1 {
            boundary.append((UInt32(k >> 32), UInt32(k & 0xFFFF_FFFF)))
        }
        guard !boundary.isEmpty else { return mesh }

        // Group boundary edges into connected components (union-find over verts).
        var parent = [UInt32: UInt32]()
        func find(_ x: UInt32) -> UInt32 {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        for (a, b) in boundary {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var compEdges = [UInt32: [(UInt32, UInt32)]]()
        for (a, b) in boundary { compEdges[find(a), default: []].append((a, b)) }

        var vertices = mesh.vertices
        let hasNormals = mesh.normals.count == mesh.vertices.count
        var normals = hasNormals ? mesh.normals : []
        let hasClass = mesh.hasClassification
        var classifications = hasClass ? mesh.classifications : []
        var indices = mesh.indices
        var closed = 0

        for (_, edges) in compEdges {
            guard edges.count <= maxComponentEdges else { continue }   // frayed strip / big opening
            var verts = Set<UInt32>()
            for (a, b) in edges { verts.insert(a); verts.insert(b) }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in verts { let p = vertices[Int(v)]; lo = simd_min(lo, p); hi = simd_max(hi, p) }
            guard simd_distance(lo, hi) <= gate else { continue }   // real opening — leave it
            var centroid = SIMD3<Float>.zero
            for v in verts { centroid += vertices[Int(v)] }
            centroid /= Float(verts.count)
            let center = UInt32(vertices.count)
            vertices.append(centroid)
            if hasNormals {
                var n = SIMD3<Float>.zero
                for v in verts { n += normals[Int(v)] }
                normals.append(simd_length(n) > 1e-6 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0))
            }
            if hasClass { classifications.append(classifications[Int(edges[0].0)]) }
            // Fan every open edge to the centroid — closes the gap regardless of
            // whether the boundary formed a clean cycle.
            for (a, b) in edges { indices.append(contentsOf: [a, b, center]) }
            closed += 1
        }
        guard closed > 0 else { return mesh }
        return MeshData(vertices: vertices, normals: normals,
                        indices: indices, classifications: hasClass ? classifications : [])
    }

    /// Above this loop length the ear-clip's ~O(n²) search isn't worth it; the
    /// centroid fan takes over. Interior scan holes are almost always far smaller.
    private static let earClipMaxEdges = 600

    /// Ear-clips a boundary loop into a triangle patch that reuses the loop's own
    /// vertices (no centroid). The loop is projected onto its best-fit (Newell)
    /// plane and triangulated there; triangles come back in the loop's *reverse*
    /// order so each boundary edge u→v is matched by a patch edge v→u, keeping the
    /// fill manifold with the surrounding surface (same invariant as the fan).
    /// Returns nil when the projection is degenerate or can't be reduced (highly
    /// non-planar / self-intersecting), so the caller can fall back to the fan.
    private static func earClipPatch(loop: [UInt32],
                                     positions: [SIMD3<Float>]) -> [(UInt32, UInt32, UInt32)]? {
        let n = loop.count
        guard n >= 3 else { return nil }
        // Reverse so consecutive patch edges run v→u relative to the boundary.
        let poly = Array(loop.reversed())
        let p3 = poly.map { positions[Int($0)] }

        // Newell's method: robust polygon normal even when the loop isn't planar.
        var nrm = SIMD3<Float>.zero
        for k in 0..<n {
            let a = p3[k], b = p3[(k + 1) % n]
            nrm.x += (a.y - b.y) * (a.z + b.z)
            nrm.y += (a.z - b.z) * (a.x + b.x)
            nrm.z += (a.x - b.x) * (a.y + b.y)
        }
        let nLen = simd_length(nrm)
        guard nLen > 1e-12 else { return nil }   // collinear / zero-area
        nrm /= nLen

        // In-plane orthonormal basis (t, b2); (t, b2, nrm) is right-handed, so a
        // polygon whose 3D normal is nrm projects counter-clockwise — which is
        // exactly the winding Newell's nrm reports for `poly`.
        let ref = abs(nrm.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let t = simd_normalize(simd_cross(ref, nrm))
        let b2 = simd_cross(nrm, t)
        var centroid = SIMD3<Float>.zero
        for p in p3 { centroid += p }
        centroid /= Float(n)
        let pts = p3.map { SIMD2<Float>(simd_dot($0 - centroid, t), simd_dot($0 - centroid, b2)) }

        var idx = Array(0..<n)
        var tris: [(UInt32, UInt32, UInt32)] = []
        tris.reserveCapacity(n - 2)
        var guardCounter = 0
        let guardLimit = n * n
        while idx.count > 3 {
            guardCounter += 1
            if guardCounter > guardLimit { return nil }   // no progress — bail to fan
            let m = idx.count
            var clipped = false
            for ii in 0..<m {
                let pa = idx[(ii + m - 1) % m], pb = idx[ii], pc = idx[(ii + 1) % m]
                let a = pts[pa], b = pts[pb], c = pts[pc]
                // Convex (CCW) corner?
                let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                if cross <= 0 { continue }   // reflex or degenerate — not an ear
                // No other loop vertex inside the candidate ear.
                var contains = false
                for jj in 0..<m {
                    let pj = idx[jj]
                    if pj == pa || pj == pb || pj == pc { continue }
                    if pointInTriangle(pts[pj], a, b, c) { contains = true; break }
                }
                if contains { continue }
                tris.append((poly[pa], poly[pb], poly[pc]))
                idx.remove(at: ii)
                clipped = true
                break
            }
            if !clipped { return nil }   // self-intersecting projection — fall back
        }
        tris.append((poly[idx[0]], poly[idx[1]], poly[idx[2]]))
        return tris.count == n - 2 ? tris : nil
    }

    /// Barycentric inside test (boundary counts as inside) for a CCW triangle.
    @inline(__always)
    private static func pointInTriangle(_ p: SIMD2<Float>, _ a: SIMD2<Float>,
                                        _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        let d1 = (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
        let d2 = (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y)
        let d3 = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }
}
