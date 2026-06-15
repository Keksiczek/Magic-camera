//
//  MeshSceneBuilder.swift
//  Magic Camera
//
//  Builds SCNGeometry from a MeshData (for the result viewer) and a live
//  wireframe from a raw ARMeshGeometry (for the scanning overlay).
//

import ARKit
import SceneKit
import simd
import UIKit

enum MeshColorMode: String, CaseIterable, Identifiable {
    case shaded = "Shaded"
    case classification = "Surfaces"
    case height = "Height"
    case normals = "Normals"
    var id: String { rawValue }

    /// Modes valid for a given mesh — classification only when it carries data.
    static func available(classified: Bool) -> [MeshColorMode] {
        classified ? [.shaded, .classification, .height, .normals] : [.shaded, .height, .normals]
    }
}

enum MeshSceneBuilder {
    static func geometry(from mesh: MeshData, colorMode: MeshColorMode = .shaded) -> SCNGeometry? {
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

        var sources = [vSource, nSource]
        let vertexColors = colors(for: mesh, mode: colorMode)
        if let vertexColors {
            let cData = vertexColors.withUnsafeBytes { Data($0) }
            let cSource = SCNGeometrySource(
                data: cData, semantic: .color, vectorCount: vertexColors.count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)
            sources.append(cSource)
        }

        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        material.isDoubleSided = true
        if vertexColors != nil {
            material.lightingModel = .blinn
            material.diffuse.contents = UIColor.white   // modulated by per-vertex colour
        } else {
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor(white: 0.82, alpha: 1)
            material.roughness.contents = 0.9
        }
        geometry.firstMaterial = material
        return geometry
    }

    /// Per-vertex colours for a colour mode, or `nil` for plain shading.
    private static func colors(for mesh: MeshData, mode: MeshColorMode) -> [SIMD3<Float>]? {
        switch mode {
        case .shaded:
            return nil
        case .classification:
            guard mesh.hasClassification else { return nil }
            return mesh.classifications.map {
                MeshClassification(rawValue: $0)?.color ?? MeshClassification.none.color
            }
        case .height:
            guard let box = mesh.boundingBox() else { return nil }
            let span = max(box.max.y - box.min.y, 0.0001)
            return mesh.vertices.map { heatRamp(($0.y - box.min.y) / span) }
        case .normals:
            return mesh.normals.map { simd_normalize($0) * 0.5 + 0.5 }
        }
    }

    private static func heatRamp(_ t: Float) -> SIMD3<Float> {
        let x = min(max(t, 0), 1)
        let r = min(max(1.5 - abs(4 * x - 1.5), 0), 1)
        let g = min(max(1.5 - abs(4 * x - 2.5), 0), 1)
        let b = min(max(1.5 - abs(4 * x - 3.5), 0), 1)
        return SIMD3<Float>(r, g, b)
    }

    static func node(from mesh: MeshData, colorMode: MeshColorMode = .shaded) -> SCNNode {
        let node = SCNNode()
        node.geometry = geometry(from: mesh, colorMode: colorMode)
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

    /// Live *shaded* surface straight from an ARMeshGeometry — a lit, lightly
    /// translucent skin over the captured geometry so the user sees coverage as
    /// a solid surface (clearer "what's filled in" feedback than a wireframe)
    /// while still seeing a little of the camera through it. Uses the anchor's
    /// own normals for shading.
    static func liveSurface(from arGeometry: ARMeshGeometry) -> SCNGeometry {
        let vertices = arGeometry.vertices
        let vSource = SCNGeometrySource(
            buffer: vertices.buffer, vertexFormat: vertices.format, semantic: .vertex,
            vertexCount: vertices.count, dataOffset: vertices.offset, dataStride: vertices.stride)

        let normals = arGeometry.normals
        let nSource = SCNGeometrySource(
            buffer: normals.buffer, vertexFormat: normals.format, semantic: .normal,
            vertexCount: normals.count, dataOffset: normals.offset, dataStride: normals.stride)

        let faces = arGeometry.faces
        let faceData = Data(bytesNoCopy: faces.buffer.contents(),
                            count: faces.buffer.length, deallocator: .none)
        let element = SCNGeometryElement(
            data: faceData, primitiveType: .triangles,
            primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)

        let geometry = SCNGeometry(sources: [vSource, nSource], elements: [element])
        let material = SCNMaterial()
        material.fillMode = .fill
        material.lightingModel = .blinn
        material.diffuse.contents = UIColor(red: 0.30, green: 0.78, blue: 0.95, alpha: 1)
        material.isDoubleSided = true
        material.transparency = 0.82   // mostly opaque; a hint of camera shows through
        geometry.firstMaterial = material
        return geometry
    }
}
