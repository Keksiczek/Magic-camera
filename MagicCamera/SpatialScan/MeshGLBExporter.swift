//
//  MeshGLBExporter.swift
//  Magic Camera
//
//  Serialises a MeshData into a self-contained binary glTF 2.0 (.glb) file:
//  positions, normals and indices with a default metallic-roughness PBR
//  material. Pure Foundation/simd (no ModelIO), so it is unit-testable and works
//  for meshes ModelIO cannot export to glTF. The result opens in Blender, Maya,
//  Unity, Unreal, three.js / model-viewer and macOS Quick Look.
//
//  GLB layout: 12-byte header, then a JSON chunk, then a BIN chunk. The JSON
//  references the BIN buffer; both chunks are padded to a 4-byte boundary.
//

import Foundation
import simd

enum MeshGLBExporter {
    // glTF / GLB magic numbers.
    private static let glbMagic: UInt32 = 0x46546C67    // "glTF"
    private static let jsonChunkType: UInt32 = 0x4E4F534A  // "JSON"
    private static let binChunkType: UInt32 = 0x004E4942   // "BIN\0"
    private static let componentFloat = 5126               // GL FLOAT
    private static let componentUInt = 5125                // GL UNSIGNED_INT
    private static let targetArrayBuffer = 34962           // ARRAY_BUFFER
    private static let targetElementBuffer = 34963         // ELEMENT_ARRAY_BUFFER
    private static let modeTriangles = 4

    /// Serialise `mesh` to GLB bytes.
    static func data(from mesh: MeshData) throws -> Data {
        guard !mesh.isEmpty else { throw MeshExporter.ExportError.empty }
        let hasNormals = mesh.normals.count == mesh.vertices.count

        // --- Binary buffer: indices, then positions, then optional normals.
        // Each block's offset stays 4-byte aligned (4|indexBytes, 12|vertexBytes),
        // which is what glTF accessors and GLB chunks require.
        var bin = Data()
        bin.reserveCapacity(mesh.indices.count * 4 + mesh.vertices.count * (hasNormals ? 24 : 12))

        let indicesOffset = 0
        for idx in mesh.indices { appendUInt32LE(idx, to: &bin) }
        let indicesLength = bin.count - indicesOffset

        let positionOffset = bin.count
        var lo = mesh.vertices[0], hi = mesh.vertices[0]
        for v in mesh.vertices {
            appendFloatLE(v.x, to: &bin); appendFloatLE(v.y, to: &bin); appendFloatLE(v.z, to: &bin)
            lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        let positionLength = bin.count - positionOffset

        var normalOffset = 0, normalLength = 0
        if hasNormals {
            normalOffset = bin.count
            for n in mesh.normals {
                appendFloatLE(n.x, to: &bin); appendFloatLE(n.y, to: &bin); appendFloatLE(n.z, to: &bin)
            }
            normalLength = bin.count - normalOffset
        }
        padTo4(&bin, with: 0)

        // --- glTF JSON.
        var bufferViews: [[String: Any]] = [
            ["buffer": 0, "byteOffset": indicesOffset, "byteLength": indicesLength, "target": targetElementBuffer],
            ["buffer": 0, "byteOffset": positionOffset, "byteLength": positionLength, "target": targetArrayBuffer],
        ]
        var accessors: [[String: Any]] = [
            ["bufferView": 0, "componentType": componentUInt, "count": mesh.indices.count, "type": "SCALAR"],
            ["bufferView": 1, "componentType": componentFloat, "count": mesh.vertices.count, "type": "VEC3",
             "min": [Double(lo.x), Double(lo.y), Double(lo.z)],
             "max": [Double(hi.x), Double(hi.y), Double(hi.z)]],
        ]
        var attributes: [String: Any] = ["POSITION": 1]
        if hasNormals {
            bufferViews.append(["buffer": 0, "byteOffset": normalOffset,
                                "byteLength": normalLength, "target": targetArrayBuffer])
            accessors.append(["bufferView": 2, "componentType": componentFloat,
                              "count": mesh.vertices.count, "type": "VEC3"])
            attributes["NORMAL"] = 2
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Magic Camera"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "materials": [[
                "name": "Scan",
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.8, 0.8, 0.82, 1.0],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.9,
                ],
                "doubleSided": true,
            ]],
            "meshes": [["primitives": [[
                "attributes": attributes,
                "indices": 0,
                "material": 0,
                "mode": modeTriangles,
            ]]]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": accessors,
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        padTo4(&jsonData, with: 0x20)   // JSON chunk is padded with spaces

        // --- GLB container.
        let totalLength = 12 + 8 + jsonData.count + 8 + bin.count
        var glb = Data(capacity: totalLength)
        appendUInt32LE(glbMagic, to: &glb)
        appendUInt32LE(2, to: &glb)                       // glTF version
        appendUInt32LE(UInt32(totalLength), to: &glb)
        appendUInt32LE(UInt32(jsonData.count), to: &glb)
        appendUInt32LE(jsonChunkType, to: &glb)
        glb.append(jsonData)
        appendUInt32LE(UInt32(bin.count), to: &glb)
        appendUInt32LE(binChunkType, to: &glb)
        glb.append(bin)
        return glb
    }

    /// Serialise and write to a temp file, returning its URL.
    static func write(_ mesh: MeshData, filename: String = "MagicCamera-mesh") throws -> URL {
        let payload = try data(from: mesh)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filename).glb")
        try? FileManager.default.removeItem(at: url)
        try payload.write(to: url)
        return url
    }

    // MARK: - Helpers

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendFloatLE(_ value: Float, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func padTo4(_ data: inout Data, with byte: UInt8) {
        let remainder = data.count % 4
        if remainder != 0 { data.append(contentsOf: repeatElement(byte, count: 4 - remainder)) }
    }
}
