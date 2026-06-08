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

    var count: Int { vertices.count }
    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }

    init() {}

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
    }

    func boundingBox() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = vertices.first else { return nil }
        var lo = first, hi = first
        for v in vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        return (lo, hi)
    }
}

/// Thread-safe collector for ARKit mesh anchors during a scan.
final class MeshAnchorCollector {
    private let lock = NSLock()
    private var anchors: [UUID: ARMeshAnchor] = [:]

    func update(_ anchor: ARMeshAnchor) {
        lock.lock(); anchors[anchor.identifier] = anchor; lock.unlock()
    }

    func remove(_ anchor: ARMeshAnchor) {
        lock.lock(); anchors[anchor.identifier] = nil; lock.unlock()
    }

    func reset() {
        lock.lock(); anchors.removeAll(); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return anchors.count
    }

    func snapshot() -> MeshData {
        lock.lock(); let values = Array(anchors.values); lock.unlock()
        return MeshData(anchors: values)
    }
}
