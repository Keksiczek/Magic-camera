//
//  MeshSceneBuilder.swift
//  Magic Camera
//
//  Builds SCNGeometry from a MeshData (for the result viewer) and a live
//  wireframe from a raw ARMeshGeometry (for the scanning overlay).
//

import ARKit
import SceneKit
import UIKit

enum MeshSceneBuilder {
    static func geometry(from mesh: MeshData) -> SCNGeometry? {
        guard !mesh.isEmpty else { return nil }
        let stride = MemoryLayout<SIMD3<Float>>.stride

        let vData = mesh.vertices.withUnsafeBytes { Data($0) }
        let vSource = SCNGeometrySource(
            data: vData, semantic: .vertex, vectorCount: mesh.vertices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)

        let nData = mesh.normals.withUnsafeBytes { Data($0) }
        let nSource = SCNGeometrySource(
            data: nData, semantic: .normal, vectorCount: mesh.normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)

        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vSource, nSource], elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(white: 0.82, alpha: 1)
        material.roughness.contents = 0.9
        material.isDoubleSided = true
        geometry.firstMaterial = material
        return geometry
    }

    static func node(from mesh: MeshData) -> SCNNode {
        let node = SCNNode()
        node.geometry = geometry(from: mesh)
        return node
    }

    /// Live wireframe straight from an ARMeshGeometry (local space; the anchor
    /// node carries the transform).
    static func wireframe(from arGeometry: ARMeshGeometry) -> SCNGeometry {
        let vertices = arGeometry.vertices
        let source = SCNGeometrySource(
            buffer: vertices.buffer, vertexFormat: vertices.format, semantic: .vertex,
            vertexCount: vertices.count, dataOffset: vertices.offset, dataStride: vertices.stride)

        let faces = arGeometry.faces
        let faceData = Data(bytesNoCopy: faces.buffer.contents(),
                            count: faces.buffer.length, deallocator: .none)
        let element = SCNGeometryElement(
            data: faceData, primitiveType: .triangles,
            primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.fillMode = .lines
        material.diffuse.contents = UIColor(red: 0.2, green: 0.95, blue: 0.85, alpha: 1)
        material.isDoubleSided = true
        material.lightingModel = .constant
        geometry.firstMaterial = material
        return geometry
    }
}
