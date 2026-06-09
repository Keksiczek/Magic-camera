//
//  MeshData.swift
//  Magic Camera
//
//  Combined triangle mesh assembled from ARKit mesh anchors (world space),
//  ready for SceneKit display and ModelIO export.
//
import ARKit
import simd

struct MeshData {
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
}

/// Thread‑safe collector for ARKit mesh anchors during a scan.
final class MeshAnchorCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.keks.MagicCamera.meshCollector")
    private var anchors: [UUID: ARMeshAnchor] = [:]

    func update(_ anchor: ARMeshAnchor) {
        queue.async { self.anchors[anchor.identifier] = anchor }
    }

    func remove(_ anchor: ARMeshAnchor) {
        queue.async { self.anchors[anchor.identifier] = nil }
    }

    func reset() {
        queue.async { self.anchors.removeAll() }
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
