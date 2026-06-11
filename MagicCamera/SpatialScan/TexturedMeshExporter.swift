//
//  TexturedMeshExporter.swift
//  Magic Camera
//
//  Exports a baked TexturedMesh:
//    - GLB: self-contained binary glTF with POSITION/NORMAL/TEXCOORD_0 and the
//      PNG atlas embedded as the material's baseColor texture (no ModelIO).
//    - USDZ: SceneKit geometry with a UV source + diffuse atlas, written via
//      SCNScene so AR Quick Look shows the colour texture.
//

import Foundation
import SceneKit
import UIKit
import simd

enum TexturedMeshExporter {
    enum Format: String, CaseIterable, Identifiable {
        case glb = "GLB (textured)"
        case usdz = "USDZ (textured)"
        var id: String { rawValue }
        var fileExtension: String { self == .glb ? "glb" : "usdz" }
    }

    static func write(_ textured: TexturedMesh, format: Format,
                      filename: String = "MagicCamera-textured") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filename).\(format.fileExtension)")
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .glb:
            try glbData(from: textured).write(to: url, options: .atomic)
        case .usdz:
            try writeUSDZ(textured, to: url)
        }
        return url
    }

    // MARK: - GLB

    /// Serialises the textured mesh to GLB bytes (also used by the web viewer).
    static func glbData(from textured: TexturedMesh) throws -> Data {
        let mesh = textured.mesh
        guard !mesh.isEmpty, textured.uvs.count == mesh.vertices.count else {
            throw MeshExporter.ExportError.empty
        }

        // Binary chunk: indices | positions | normals | uvs | png (each 4-aligned).
        var bin = Data()
        let indicesOffset = 0
        for i in mesh.indices { appendUInt32(i, to: &bin) }
        let indicesLength = bin.count - indicesOffset

        let positionOffset = bin.count
        var lo = mesh.vertices[0], hi = mesh.vertices[0]
        for v in mesh.vertices {
            appendFloat(v.x, to: &bin); appendFloat(v.y, to: &bin); appendFloat(v.z, to: &bin)
            lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        let positionLength = bin.count - positionOffset

        let normalOffset = bin.count
        for n in mesh.normals {
            appendFloat(n.x, to: &bin); appendFloat(n.y, to: &bin); appendFloat(n.z, to: &bin)
        }
        let normalLength = bin.count - normalOffset

        let uvOffset = bin.count
        for uv in textured.uvs {
            appendFloat(uv.x, to: &bin); appendFloat(uv.y, to: &bin)
        }
        let uvLength = bin.count - uvOffset

        let imageOffset = bin.count
        bin.append(textured.texturePNG)
        let imageLength = bin.count - imageOffset
        while bin.count % 4 != 0 { bin.append(0) }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "MagicCamera"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [[
                "primitives": [[
                    "attributes": ["POSITION": 1, "NORMAL": 2, "TEXCOORD_0": 3],
                    "indices": 0,
                    "material": 0,
                    "mode": 4
                ]]
            ]],
            "materials": [[
                "pbrMetallicRoughness": [
                    "baseColorTexture": ["index": 0],
                    "metallicFactor": 0,
                    "roughnessFactor": 0.9
                ],
                "doubleSided": true
            ]],
            "textures": [["sampler": 0, "source": 0]],
            "samplers": [["magFilter": 9729, "minFilter": 9729, "wrapS": 33071, "wrapT": 33071]],
            "images": [["bufferView": 4, "mimeType": "image/png"]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": indicesOffset, "byteLength": indicesLength,
                 "target": 34963],
                ["buffer": 0, "byteOffset": positionOffset, "byteLength": positionLength,
                 "target": 34962],
                ["buffer": 0, "byteOffset": normalOffset, "byteLength": normalLength,
                 "target": 34962],
                ["buffer": 0, "byteOffset": uvOffset, "byteLength": uvLength,
                 "target": 34962],
                ["buffer": 0, "byteOffset": imageOffset, "byteLength": imageLength]
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5125, "count": mesh.indices.count,
                 "type": "SCALAR"],
                ["bufferView": 1, "componentType": 5126, "count": mesh.vertices.count,
                 "type": "VEC3", "min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]],
                ["bufferView": 2, "componentType": 5126, "count": mesh.normals.count,
                 "type": "VEC3"],
                ["bufferView": 3, "componentType": 5126, "count": textured.uvs.count,
                 "type": "VEC2"]
            ]
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }   // pad with spaces

        var out = Data()
        appendUInt32(0x4654_6C67, to: &out)                       // "glTF"
        appendUInt32(2, to: &out)
        appendUInt32(UInt32(12 + 8 + jsonData.count + 8 + bin.count), to: &out)
        appendUInt32(UInt32(jsonData.count), to: &out)
        appendUInt32(0x4E4F_534A, to: &out)                       // "JSON"
        out.append(jsonData)
        appendUInt32(UInt32(bin.count), to: &out)
        appendUInt32(0x004E_4942, to: &out)                       // "BIN\0"
        out.append(bin)
        return out
    }

    // MARK: - USDZ (SceneKit)

    private static func writeUSDZ(_ textured: TexturedMesh, to url: URL) throws {
        guard let geometry = geometry(from: textured) else {
            throw MeshExporter.ExportError.empty
        }
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw MeshExporter.ExportError.failed("USDZ write failed")
        }
    }

    /// SCNGeometry with vertex / normal / UV sources and the atlas as diffuse.
    static func geometry(from textured: TexturedMesh) -> SCNGeometry? {
        let mesh = textured.mesh
        guard !mesh.isEmpty, textured.uvs.count == mesh.vertices.count,
              let image = UIImage(data: textured.texturePNG) else { return nil }
        let stride3 = MemoryLayout<SIMD3<Float>>.stride

        let vData = mesh.vertices.withUnsafeBytes { Data($0) }
        let vSource = SCNGeometrySource(
            data: vData, semantic: .vertex, vectorCount: mesh.vertices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride3)

        let nData = mesh.normals.withUnsafeBytes { Data($0) }
        let nSource = SCNGeometrySource(
            data: nData, semantic: .normal, vectorCount: mesh.normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride3)

        let tData = textured.uvs.withUnsafeBytes { Data($0) }
        let tSource = SCNGeometrySource(
            data: tData, semantic: .texcoord, vectorCount: textured.uvs.count,
            usesFloatComponents: true, componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride)

        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vSource, nSource, tSource], elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = image
        material.roughness.contents = 0.9
        material.metalness.contents = 0
        material.isDoubleSided = true
        geometry.firstMaterial = material
        return geometry
    }

    // MARK: - Little-endian append helpers

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
