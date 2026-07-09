//
//  MeshData.swift
//  Magic Camera
//
//  Combined triangle mesh assembled from ARKit mesh anchors (world space),
//  ready for SceneKit display and ModelIO export.
//
import ARKit
import QuartzCore
import simd

struct MeshData: Sendable {
    var vertices: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    /// Per-vertex ARKit surface classification (`MeshClassification` raw value).
    /// Empty when the scan was captured without `.meshWithClassification`.
    var classifications: [UInt8] = []
    /// True once any anchor actually supplied classification data (so an
    /// unclassified scan padded with `.none` is not mistaken for a classified one).
    private(set) var classificationAvailable = false

    var count: Int { vertices.count }
    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }
    var hasClassification: Bool {
        classificationAvailable && classifications.count == vertices.count && !classifications.isEmpty
    }

    init() {}

    init(vertices: [SIMD3<Float>], normals: [SIMD3<Float>],
         indices: [UInt32], classifications: [UInt8] = []) {
        self.vertices = vertices
        self.normals = normals
        self.indices = indices
        self.classifications = classifications
        self.classificationAvailable = !classifications.isEmpty
    }

    init(anchors: [ARMeshAnchor]) {
        for anchor in anchors { append(anchor) }
    }

    mutating func append(_ anchor: ARMeshAnchor) {
        let geometry = anchor.geometry
        let vertexSource = geometry.vertices
        let normalSource = geometry.normals
        let faces = geometry.faces
        let transform = anchor.transform
        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))

        let base = UInt32(vertices.count)
        let vPtr = vertexSource.buffer.contents()
        let nPtr = normalSource.buffer.contents()
        let firstNewVertex = vertices.count
        for i in 0..<vertexSource.count {
            let vOff = vertexSource.offset + vertexSource.stride * i
            let x = vPtr.load(fromByteOffset: vOff, as: Float.self)
            let y = vPtr.load(fromByteOffset: vOff + 4, as: Float.self)
            let z = vPtr.load(fromByteOffset: vOff + 8, as: Float.self)
            let world = transform * SIMD4<Float>(x, y, z, 1)
            vertices.append(SIMD3<Float>(world.x, world.y, world.z))

            let nOff = normalSource.offset + normalSource.stride * i
            let nx = nPtr.load(fromByteOffset: nOff, as: Float.self)
            let ny = nPtr.load(fromByteOffset: nOff + 4, as: Float.self)
            let nz = nPtr.load(fromByteOffset: nOff + 8, as: Float.self)
            normals.append(simd_normalize(rotation * SIMD3<Float>(nx, ny, nz)))
        }

        let fPtr = faces.buffer.contents()
        let indexCount = faces.count * faces.indexCountPerPrimitive
        for i in 0..<indexCount {
            let idx = fPtr.load(fromByteOffset: faces.bytesPerIndex * i, as: UInt32.self)
            indices.append(base + idx)
        }

        appendClassification(from: geometry, faces: faces, vertexBase: firstNewVertex,
                             newVertexCount: vertexSource.count)
    }

    /// ARKit exposes one classification per face; project it onto vertices so the
    /// mesh can be coloured per surface type (last face wins for shared vertices).
    private mutating func appendClassification(from geometry: ARMeshGeometry,
                                               faces: ARGeometryElement,
                                               vertexBase: Int, newVertexCount: Int) {
        // Keep the per-vertex array aligned with `vertices` even when this anchor
        // (or a previous one) lacks classification data.
        if classifications.count < vertexBase {
            classifications.append(contentsOf:
                repeatElement(MeshClassification.none.rawValue, count: vertexBase - classifications.count))
        }
        let defaults = [UInt8](repeating: MeshClassification.none.rawValue, count: newVertexCount)
        classifications.append(contentsOf: defaults)

        guard let classification = geometry.classification else { return }
        classificationAvailable = true
        let cPtr = classification.buffer.contents()
        let fPtr = faces.buffer.contents()
        let perFace = faces.indexCountPerPrimitive
        for f in 0..<faces.count {
            let cOff = classification.offset + classification.stride * f
            let value = cPtr.load(fromByteOffset: cOff, as: UInt8.self)
            for k in 0..<perFace {
                let idx = fPtr.load(fromByteOffset: faces.bytesPerIndex * (f * perFace + k), as: UInt32.self)
                let vertexIndex = vertexBase + Int(idx)
                if vertexIndex < classifications.count { classifications[vertexIndex] = value }
            }
        }
    }

    func boundingBox() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = vertices.first else { return nil }
        var lo = first, hi = first
        for v in vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        return (lo, hi)
    }

    /// True when the mesh is a thin slab — an open surface (wall / floor / façade)
    /// rather than a closed object with real volume. Drives the scene-aware finish
    /// (tidy vs solidify) and whether a texture bake should even out its lighting.
    var isThinOpenSurface: Bool {
        guard let b = boundingBox() else { return false }
        let e = b.max - b.min
        let dims = [e.x, e.y, e.z].sorted()
        return dims[2] > 0.05 && dims[0] < dims[2] * 0.12
    }

    /// Total triangle area in m². Drives the texture atlas's adaptive resolution:
    /// a mesh whose triangles cover more physical area (room walls/floor, meshed
    /// coarse) earns a larger atlas so its texels-per-metre match a small object's
    /// fine triangles instead of washing out.
    func surfaceArea() -> Float {
        guard indices.count >= 3 else { return 0 }
        var sum: Float = 0
        var i = 0
        while i + 2 < indices.count {
            let a = vertices[Int(indices[i])]
            let b = vertices[Int(indices[i + 1])]
            let c = vertices[Int(indices[i + 2])]
            sum += simd_length(simd_cross(b - a, c - a)) * 0.5
            i += 3
        }
        return sum
    }

    /// Enclosed volume in m³ via the divergence theorem (signed tetrahedra summed
    /// over triangles). Exact for closed meshes; an estimate for open ones.
    func volume() -> Float {
        guard indices.count >= 3 else { return 0 }
        var sixV: Float = 0
        var i = 0
        while i + 2 < indices.count {
            let a = vertices[Int(indices[i])]
            let b = vertices[Int(indices[i + 1])]
            let c = vertices[Int(indices[i + 2])]
            sixV += simd_dot(a, simd_cross(b, c))
            i += 3
        }
        return abs(sixV) / 6
    }

    /// Returns the mesh rigidly transformed into another frame (positions by
    /// the full matrix, normals by its rotation part) — used when ICP-aligning
    /// a second scan before merging.
    func transformed(by transform: simd_float4x4) -> MeshData {
        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let newVertices = vertices.map { v -> SIMD3<Float> in
            let w = transform * SIMD4<Float>(v, 1)
            return SIMD3<Float>(w.x, w.y, w.z)
        }
        let newNormals = normals.map { simd_normalize(rotation * $0) }
        return MeshData(vertices: newVertices, normals: newNormals,
                        indices: indices, classifications: classifications)
    }

    /// Concatenates two meshes into one (indices re-based). Classification is
    /// kept when either side has it; the other side pads as unclassified.
    func appending(_ other: MeshData) -> MeshData {
        guard !other.isEmpty else { return self }
        guard !isEmpty else { return other }
        var newVertices = vertices
        newVertices.append(contentsOf: other.vertices)
        var newNormals = normals
        newNormals.append(contentsOf: other.normals)
        let base = UInt32(vertices.count)
        var newIndices = indices
        newIndices.append(contentsOf: other.indices.map { base + $0 })

        var newClasses: [UInt8] = []
        if hasClassification || other.hasClassification {
            newClasses = hasClassification
                ? classifications
                : [UInt8](repeating: MeshClassification.none.rawValue, count: vertices.count)
            newClasses.append(contentsOf: other.hasClassification
                ? other.classifications
                : [UInt8](repeating: MeshClassification.none.rawValue, count: other.vertices.count))
        }
        return MeshData(vertices: newVertices, normals: newNormals,
                        indices: newIndices, classifications: newClasses)
    }

    /// Index-welded copy: bit-identical vertex positions merge into one vertex
    /// and the triangles are remapped (degenerates dropped). Texture baking and
    /// USDZ import emit per-corner duplicated vertices ("triangle soup"); tools
    /// that walk mesh connectivity (smoothing, hole filling) read soup as
    /// thousands of isolated triangles and tear the surface apart along every
    /// edge — weld first. Returns `self` unchanged when nothing is duplicated.
    func weldingDuplicateVertices() -> MeshData {
        guard !isEmpty else { return self }
        var canonical = [SIMD3<Float>: UInt32](minimumCapacity: vertices.count)
        var remap = [UInt32](repeating: 0, count: vertices.count)
        var newVertices: [SIMD3<Float>] = []
        let hasNormals = normals.count == vertices.count
        var normalSums: [SIMD3<Float>] = []
        let hasClass = hasClassification
        var newClasses: [UInt8] = []

        for i in 0..<vertices.count {
            let p = vertices[i]
            if let existing = canonical[p] {
                remap[i] = existing
                if hasNormals { normalSums[Int(existing)] += normals[i] }
            } else {
                let index = UInt32(newVertices.count)
                canonical[p] = index
                newVertices.append(p)
                if hasNormals { normalSums.append(normals[i]) }
                if hasClass { newClasses.append(classifications[i]) }
                remap[i] = index
            }
        }
        guard newVertices.count < vertices.count else { return self }

        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(indices.count)
        var t = 0
        while t + 2 < indices.count {
            let a = remap[Int(indices[t])]
            let b = remap[Int(indices[t + 1])]
            let c = remap[Int(indices[t + 2])]
            if a != b, b != c, a != c {
                newIndices.append(a); newIndices.append(b); newIndices.append(c)
            }
            t += 3
        }
        let newNormals: [SIMD3<Float>] = hasNormals
            ? normalSums.map { n in
                let length = simd_length(n)
                return length > 1e-6 ? n / length : SIMD3<Float>(0, 1, 0)
            }
            : []
        return MeshData(vertices: newVertices, normals: newNormals,
                        indices: newIndices, classifications: hasClass ? newClasses : [])
    }

    /// Returns a new mesh with every triangle belonging to one of `classes`
    /// dropped (a triangle is dropped when at least two of its three vertices
    /// carry a removed classification), then compacts the surviving vertices.
    /// Used to strip walls/floor/ceiling and leave just the subject. Returns
    /// `self` unchanged when the mesh has no classification data.
    func removingSurfaces(_ classes: Set<MeshClassification>) -> MeshData {
        guard hasClassification, !classes.isEmpty else { return self }
        let removed = Set(classes.map { $0.rawValue })
        let hasNormals = normals.count == vertices.count

        var remap = [UInt32: UInt32]()
        remap.reserveCapacity(vertices.count)
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newClasses: [UInt8] = []
        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(indices.count)

        func mapped(_ old: UInt32) -> UInt32 {
            if let m = remap[old] { return m }
            let m = UInt32(newVertices.count)
            remap[old] = m
            newVertices.append(vertices[Int(old)])
            if hasNormals { newNormals.append(normals[Int(old)]) }
            newClasses.append(classifications[Int(old)])
            return m
        }

        var i = 0
        while i + 2 < indices.count {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            let removedCount = (removed.contains(classifications[Int(a)]) ? 1 : 0)
                + (removed.contains(classifications[Int(b)]) ? 1 : 0)
                + (removed.contains(classifications[Int(c)]) ? 1 : 0)
            if removedCount < 2 {
                newIndices.append(mapped(a))
                newIndices.append(mapped(b))
                newIndices.append(mapped(c))
            }
            i += 3
        }

        return MeshData(vertices: newVertices, normals: newNormals,
                        indices: newIndices, classifications: newClasses)
    }

    /// Removes the dominant flat support surface (the floor / table / placemat the
    /// object rests on) and everything below it, keeping the object that stands on
    /// it — the manual companion to the one-tap model's automatic support lift, for
    /// a scan that kept its base. Detects the dominant near-horizontal plane with
    /// the gravity-aware RANSAC and drops triangles whose centroid isn't clearly
    /// above it. Returns self unchanged when no clear horizontal support is found
    /// or removing it would gut the mesh (so a genuinely flat object is left alone).
    func removingBasePlane(up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> MeshData {
        guard triangleCount > 4 else { return self }
        // Reuse the point-cloud RANSAC on the mesh vertices.
        var cloud = PointCloud()
        cloud.reserveCapacity(vertices.count)
        for v in vertices { cloud.append(position: v, color: SIMD3<Float>(repeating: 1), confidence: 1) }
        guard let plane = PointCloudSegmenter.detectDominantPlane(
            cloud, minInlierFraction: 0.18, up: up, horizontalBias: 0.85),
            abs(simd_dot(plane.normal, up)) > 0.7 else { return self }   // must be ~horizontal
        // Orient the plane normal along `up` so "above" is unambiguous.
        let flip = simd_dot(plane.normal, up) < 0
        let n = flip ? -plane.normal : plane.normal
        let d = flip ? -plane.d : plane.d
        let band = max((BallPivotingMesher.meanSpacing(vertices) ?? 0.01) * 2, 0.01)

        let hasNormals = normals.count == vertices.count
        let hasClass = hasClassification
        var remap = [UInt32: UInt32](); remap.reserveCapacity(vertices.count)
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newClasses: [UInt8] = []
        var newIndices: [UInt32] = []; newIndices.reserveCapacity(indices.count)
        func mapped(_ old: UInt32) -> UInt32 {
            if let m = remap[old] { return m }
            let m = UInt32(newVertices.count)
            remap[old] = m
            newVertices.append(vertices[Int(old)])
            if hasNormals { newNormals.append(normals[Int(old)]) }
            if hasClass { newClasses.append(classifications[Int(old)]) }
            return m
        }

        var i = 0
        while i + 2 < indices.count {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            let centroid = (vertices[Int(a)] + vertices[Int(b)] + vertices[Int(c)]) / 3
            if simd_dot(n, centroid) + d > band {   // clearly above the support
                newIndices.append(mapped(a)); newIndices.append(mapped(b)); newIndices.append(mapped(c))
            }
            i += 3
        }
        // Don't gut the mesh: bail if nothing (or almost nothing) stands above the
        // plane — that means it wasn't an object on a support, just a flat surface.
        guard newIndices.count >= 9, newIndices.count < indices.count else { return self }
        return MeshData(vertices: newVertices, normals: newNormals,
                        indices: newIndices, classifications: hasClass ? newClasses : [])
    }

    /// Trims the frayed / flared boundary triangles a surface reconstruction
    /// leaves where the scan ran out of points — the long, thin triangles that
    /// stretch across sparse gaps and stick out past the real surface
    /// ("rozuteklé okraje", worst on open / outdoor scans with no natural edge).
    /// Two shapes of straggler go: one whose longest edge exceeds `factor`× the
    /// median edge (a long spike), and one that is a *sliver* — a triangle stretched
    /// so thin that its altitude onto the longest edge is under `sliverFraction`× the
    /// median edge (the flat fray that a pure long-edge test misses because each
    /// individual edge is only moderately long). A lattice-clean mesh has near-
    /// uniform, well-shaped triangles, so this is a no-op on the body; it bails
    /// rather than gut a mesh with genuinely varied triangle sizes.
    /// Erodes the flaky fringe reconstruction leaves along open boundaries — the
    /// single-cell triangles hanging off a wall edge by one shared edge (or just a
    /// vertex) that read as "shredded" borders in the viewer. A triangle with two
    /// or more boundary edges is such a flake; a straight open rim keeps exactly
    /// one boundary edge per triangle, so the surface's real border survives (its
    /// corners round by at most `passes` triangles). Iterates because removing a
    /// flake can expose the next one behind it. Needs welded connectivity (true
    /// for reconstruction output; see [[soup-mesh-weld-rule]]). Bails rather than
    /// gut a genuinely ragged mesh (keeps ≥ 70% of the triangles). Kept at 2
    /// passes: legitimate thin features (a stair railing is one triangle wide)
    /// have two boundary edges per triangle too, and each extra pass eats a ring
    /// off them — 3 passes visibly chewed good geometry on a stairwell scan.
    /// Number of open boundary edges — edges used by exactly one triangle — after
    /// welding duplicate corners. A closed, watertight surface returns 0; a high
    /// count is the "empty triangles / holes" signal on a scanned wall. Cheap
    /// telemetry for the reconstruction breadcrumbs (welds a soup mesh first, so
    /// an exported per-corner mesh doesn't report every edge as a boundary).
    var boundaryEdgeCount: Int {
        let welded = weldingDuplicateVertices()
        guard welded.indices.count >= 3 else { return 0 }
        var used = [UInt64: Int8](minimumCapacity: welded.indices.count)
        @inline(__always) func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            let lo = min(a, b), hi = max(a, b)
            return (UInt64(lo) << 32) | UInt64(hi)
        }
        var i = 0
        while i + 2 < welded.indices.count {
            let a = welded.indices[i], b = welded.indices[i + 1], c = welded.indices[i + 2]
            used[key(a, b), default: 0] += 1
            used[key(b, c), default: 0] += 1
            used[key(c, a), default: 0] += 1
            i += 3
        }
        return used.values.reduce(0) { $0 + ($1 == 1 ? 1 : 0) }
    }

    func erodingBoundaryFlakes(passes: Int = 2) -> MeshData {
        guard triangleCount > 20 else { return self }
        @inline(__always) func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            (UInt64(a) << 32) | UInt64(b)
        }
        var current = self
        for _ in 0..<max(passes, 1) {
            var directed = Set<UInt64>()
            directed.reserveCapacity(current.indices.count)
            var i = 0
            while i + 2 < current.indices.count {
                let a = current.indices[i], b = current.indices[i + 1], c = current.indices[i + 2]
                directed.insert(key(a, b)); directed.insert(key(b, c)); directed.insert(key(c, a))
                i += 3
            }
            var newIndices: [UInt32] = []
            newIndices.reserveCapacity(current.indices.count)
            i = 0
            while i + 2 < current.indices.count {
                let a = current.indices[i], b = current.indices[i + 1], c = current.indices[i + 2]
                var boundaryEdges = 0
                if !directed.contains(key(b, a)) { boundaryEdges += 1 }
                if !directed.contains(key(c, b)) { boundaryEdges += 1 }
                if !directed.contains(key(a, c)) { boundaryEdges += 1 }
                if boundaryEdges < 2 {
                    newIndices.append(a); newIndices.append(b); newIndices.append(c)
                }
                i += 3
            }
            if newIndices.count == current.indices.count { break }   // stable — done
            guard newIndices.count >= (indices.count * 7) / 10 else { return self }
            current.indices = newIndices
        }
        return current
    }

    func trimmingLongEdges(factor: Float = 3.5, sliverFraction: Float = 0.12) -> MeshData {
        let triCount = triangleCount
        guard triCount > 20 else { return self }
        var longest = [Float](repeating: 0, count: triCount)
        var altitude = [Float](repeating: 0, count: triCount)
        var i = 0, t = 0
        while i + 2 < indices.count {
            let a = vertices[Int(indices[i])]
            let b = vertices[Int(indices[i + 1])]
            let c = vertices[Int(indices[i + 2])]
            let long = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
            longest[t] = long
            // Altitude onto the longest edge = 2·area / longest: collapses toward
            // zero for a thin fray triangle, stays near the edge length for a
            // well-shaped one. Also sweeps out zero-area degenerates.
            let area = simd_length(simd_cross(b - a, c - a)) * 0.5
            altitude[t] = long > 1e-9 ? 2 * area / long : 0
            i += 3; t += 1
        }
        let median = longest.sorted()[triCount / 2]
        guard median > 0 else { return self }
        let threshold = median * factor
        let minAltitude = median * sliverFraction

        let hasNormals = normals.count == vertices.count
        let hasClass = hasClassification
        var remap = [UInt32: UInt32](); remap.reserveCapacity(vertices.count)
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newClasses: [UInt8] = []
        var newIndices: [UInt32] = []; newIndices.reserveCapacity(indices.count)
        func mapped(_ old: UInt32) -> UInt32 {
            if let m = remap[old] { return m }
            let m = UInt32(newVertices.count)
            remap[old] = m
            newVertices.append(vertices[Int(old)])
            if hasNormals { newNormals.append(normals[Int(old)]) }
            if hasClass { newClasses.append(classifications[Int(old)]) }
            return m
        }
        i = 0; t = 0
        while i + 2 < indices.count {
            if longest[t] <= threshold, altitude[t] >= minAltitude {
                newIndices.append(mapped(indices[i]))
                newIndices.append(mapped(indices[i + 1]))
                newIndices.append(mapped(indices[i + 2]))
            }
            i += 3; t += 1
        }
        // No-op when nothing is unusually long or sliver-thin; bail rather than gut
        // a mesh that legitimately varies in size (keep ≥ 70% of the triangles).
        guard newIndices.count < indices.count,
              newIndices.count >= (indices.count * 7) / 10 else { return self }
        return MeshData(vertices: newVertices, normals: newNormals,
                        indices: newIndices, classifications: hasClass ? newClasses : [])
    }

    /// Drops small disconnected fragments — the floating blobs and specks that
    /// surface reconstruction leaves in the air around the real object — keeping
    /// only the connected components whose triangle count is at least
    /// `minFraction` of the largest component's. Welds first (connectivity on
    /// triangle soup is meaningless). Returns the welded mesh unchanged when there
    /// is a single component or nothing small enough to drop.
    func removingSmallComponents(minFraction: Float = 0.05) -> MeshData {
        let welded = weldingDuplicateVertices()
        let vertexCount = welded.vertices.count
        let triCount = welded.indices.count / 3
        guard vertexCount > 0, triCount > 1 else { return welded }

        // Union-find over vertices joined by shared triangle edges.
        var parent = Array(0..<vertexCount)
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
        while t + 2 < welded.indices.count {
            let a = Int(welded.indices[t]), b = Int(welded.indices[t + 1]), c = Int(welded.indices[t + 2])
            union(a, b); union(b, c)
            t += 3
        }

        // Triangle count per component, by the root of its first corner.
        var componentTris = [Int: Int]()
        var triRoot = [Int](repeating: 0, count: triCount)
        t = 0
        var ti = 0
        while t + 2 < welded.indices.count {
            let root = find(Int(welded.indices[t]))
            triRoot[ti] = root
            componentTris[root, default: 0] += 1
            t += 3; ti += 1
        }
        guard componentTris.count > 1, let largest = componentTris.values.max() else { return welded }
        let threshold = max(Int(Float(largest) * minFraction), 1)

        let hasNormals = welded.normals.count == vertexCount
        let hasClass = welded.hasClassification
        var remap = [UInt32: UInt32](minimumCapacity: vertexCount)
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newClasses: [UInt8] = []
        var newIndices: [UInt32] = []
        func mapped(_ old: UInt32) -> UInt32 {
            if let m = remap[old] { return m }
            let m = UInt32(newVertices.count)
            remap[old] = m
            newVertices.append(welded.vertices[Int(old)])
            if hasNormals { newNormals.append(welded.normals[Int(old)]) }
            if hasClass { newClasses.append(welded.classifications[Int(old)]) }
            return m
        }
        t = 0; ti = 0
        while t + 2 < welded.indices.count {
            if (componentTris[triRoot[ti]] ?? 0) >= threshold {
                newIndices.append(mapped(welded.indices[t]))
                newIndices.append(mapped(welded.indices[t + 1]))
                newIndices.append(mapped(welded.indices[t + 2]))
            }
            t += 3; ti += 1
        }
        guard !newIndices.isEmpty else { return welded }
        return MeshData(vertices: newVertices, normals: newNormals,
                        indices: newIndices, classifications: hasClass ? newClasses : [])
    }
}

/// Thread‑safe collector for ARKit mesh anchors during a scan.
final class MeshAnchorCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.keks.MagicCamera.meshCollector")
    private var anchors: [UUID: ARMeshAnchor] = [:]
    private var lastTriangleReport: TimeInterval = 0

    /// Live total triangle count for the scanning HUD (throttled, on main).
    var onTriangleCount: (@MainActor @Sendable (Int) -> Void)?

    func update(_ anchor: ARMeshAnchor) {
        queue.async {
            self.anchors[anchor.identifier] = anchor
            self.reportTriangleCount()
        }
    }

    func remove(_ anchor: ARMeshAnchor) {
        queue.async {
            self.anchors[anchor.identifier] = nil
            self.reportTriangleCount()
        }
    }

    func reset() {
        queue.async { self.anchors.removeAll() }
    }

    /// Called on `queue`. Sums face counts (cheap — header reads on a few dozen
    /// anchors) at most a few times a second and publishes to the main thread.
    private func reportTriangleCount() {
        guard let onTriangleCount else { return }
        let now = CACurrentMediaTime()
        guard now - lastTriangleReport >= 0.3 else { return }
        lastTriangleReport = now
        let total = anchors.values.reduce(0) { $0 + $1.geometry.faces.count }
        DispatchQueue.main.async { onTriangleCount(total) }
    }

    var count: Int {
        var result = 0
        queue.sync { result = self.anchors.count }
        return result
    }

    func snapshot() -> MeshData {
        var result = MeshData()
        queue.sync { result = MeshData(anchors: Array(self.anchors.values)) }
        return result
    }
}
