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
    ///
    /// A paged atlas becomes one glTF PRIMITIVE per page, each with its own
    /// material/texture/image and its own slice of the index buffer, all sharing
    /// the single POSITION/NORMAL/TEXCOORD_0 accessors (legal and standard — the
    /// attributes are page-independent because UVs are normalised within a
    /// triangle's own sheet). A single-page mesh emits exactly one primitive,
    /// i.e. the file this produced before paging existed.
    static func glbData(from textured: TexturedMesh) throws -> Data {
        let mesh = textured.mesh
        guard !mesh.isEmpty, textured.uvs.count == mesh.vertices.count else {
            throw MeshExporter.ExportError.empty
        }
        // Pages that ended up with no triangles carry no primitive — an empty
        // one is invalid glTF.
        let groups = textured.trianglesByPage().enumerated()
            .filter { !$0.element.isEmpty }
        guard !groups.isEmpty else { throw MeshExporter.ExportError.empty }

        // Binary chunk: indices per page | positions | normals | uvs | images.
        var bin = Data()
        var indexRanges: [(offset: Int, length: Int, count: Int)] = []
        for (_, triangles) in groups {
            let start = bin.count
            for t in triangles {
                let base = Int(t) * 3
                appendUInt32(mesh.indices[base], to: &bin)
                appendUInt32(mesh.indices[base + 1], to: &bin)
                appendUInt32(mesh.indices[base + 2], to: &bin)
            }
            indexRanges.append((start, bin.count - start, triangles.count * 3))
        }

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

        var imageRanges: [(offset: Int, length: Int, mime: String)] = []
        for (page, _) in groups {
            while bin.count % 4 != 0 { bin.append(0) }
            let start = bin.count
            let image = textured.textures[min(page, textured.textures.count - 1)]
            bin.append(image)
            imageRanges.append((start, bin.count - start, TextureAtlas.imageMIMEType(image)))
        }
        while bin.count % 4 != 0 { bin.append(0) }

        // Index views come first, then the three shared attribute views, then one
        // image view per page.
        let pageCount = groups.count
        let attributeView = pageCount
        let imageView = pageCount + 3
        var bufferViews: [[String: Any]] = indexRanges.map {
            ["buffer": 0, "byteOffset": $0.offset, "byteLength": $0.length, "target": 34963]
        }
        bufferViews.append(["buffer": 0, "byteOffset": positionOffset,
                            "byteLength": positionLength, "target": 34962])
        bufferViews.append(["buffer": 0, "byteOffset": normalOffset,
                            "byteLength": normalLength, "target": 34962])
        bufferViews.append(["buffer": 0, "byteOffset": uvOffset,
                            "byteLength": uvLength, "target": 34962])
        bufferViews.append(contentsOf: imageRanges.map {
            ["buffer": 0, "byteOffset": $0.offset, "byteLength": $0.length]
        })

        var accessors: [[String: Any]] = indexRanges.enumerated().map { i, range in
            ["bufferView": i, "componentType": 5125, "count": range.count, "type": "SCALAR"]
        }
        accessors.append(["bufferView": attributeView, "componentType": 5126,
                          "count": mesh.vertices.count, "type": "VEC3",
                          "min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]])
        accessors.append(["bufferView": attributeView + 1, "componentType": 5126,
                          "count": mesh.normals.count, "type": "VEC3"])
        accessors.append(["bufferView": attributeView + 2, "componentType": 5126,
                          "count": textured.uvs.count, "type": "VEC2"])

        let attributes = ["POSITION": pageCount, "NORMAL": pageCount + 1,
                          "TEXCOORD_0": pageCount + 2]
        let primitives: [[String: Any]] = (0..<pageCount).map { page in
            ["attributes": attributes, "indices": page, "material": page, "mode": 4]
        }
        let materials: [[String: Any]] = (0..<pageCount).map { page in
            ["pbrMetallicRoughness": ["baseColorTexture": ["index": page],
                                      "metallicFactor": 0, "roughnessFactor": 0.9],
             "doubleSided": true]
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "MagicCamera"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": primitives]],
            "materials": materials,
            "textures": (0..<pageCount).map { ["sampler": 0, "source": $0] },
            "samplers": [["magFilter": 9729, "minFilter": 9729, "wrapS": 33071, "wrapT": 33071]],
            "images": imageRanges.enumerated().map { i, range in
                ["bufferView": imageView + i, "mimeType": range.mime]
            },
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": accessors
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
        guard let geometry = geometry(from: textured, doubleSided: true) else {
            throw MeshExporter.ExportError.empty
        }
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw MeshExporter.ExportError.failed("USDZ write failed")
        }
    }

    /// SCNGeometry with vertex / normal / UV sources and the atlas as diffuse.
    /// `doubleSided` emits an explicit reversed-winding back-face per triangle —
    /// needed for the USDZ / AR Quick Look path (see the element-building note).
    ///
    /// A paged atlas becomes one geometry ELEMENT per page, each bound to its own
    /// material, since SceneKit pairs `elements[i]` with `materials[i]`. That is
    /// the mechanism behind both the in-app textured viewer and the USDZ export,
    /// so neither drops pages.
    static func geometry(from textured: TexturedMesh, doubleSided: Bool = false) -> SCNGeometry? {
        let mesh = textured.mesh
        guard !mesh.isEmpty, textured.uvs.count == mesh.vertices.count else { return nil }
        let images = textured.textures.map { UIImage(data: $0) }
        guard images.allSatisfy({ $0 != nil }) else { return nil }
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

        // AR Quick Look (RealityKit) ignores a material's doubleSided flag and
        // renders single-sided, so from behind the front faces cull and the model
        // looks see-through / shows its inside ("wrong side or transparent in AR").
        // For the USDZ path, emit an explicit back-face per triangle — reversed
        // winding over the same vertices + UVs — so both sides always draw. The
        // in-app SceneKit viewer keeps the single-sided geometry and relies on
        // `isDoubleSided` (which SceneKit honours) instead.
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for (page, triangles) in textured.trianglesByPage().enumerated() where !triangles.isEmpty {
            var indices: [UInt32] = []
            indices.reserveCapacity(triangles.count * (doubleSided ? 6 : 3))
            for t in triangles {
                let base = Int(t) * 3
                indices.append(contentsOf: [mesh.indices[base], mesh.indices[base + 1],
                                            mesh.indices[base + 2]])
            }
            if doubleSided {
                for t in triangles {
                    let base = Int(t) * 3
                    indices.append(contentsOf: [mesh.indices[base], mesh.indices[base + 2],
                                                mesh.indices[base + 1]])
                }
            }
            elements.append(SCNGeometryElement(indices: indices, primitiveType: .triangles))
            materials.append(atlasMaterial(image: images[min(page, images.count - 1)]))
        }
        guard !elements.isEmpty else { return nil }
        let geometry = SCNGeometry(sources: [vSource, nSource, tSource], elements: elements)
        geometry.materials = materials
        return geometry
    }

    /// Material for one atlas page.
    private static func atlasMaterial(image: UIImage?) -> SCNMaterial {
        let material = SCNMaterial()
        // Unlit: the baked atlas already holds the captured colour + lighting, so
        // re-lighting it with PBR + the viewer's default light blew a pale/white
        // subject out to flat white ("make texture doesn't work"). `.constant`
        // shows the baked texture as-is, in the viewer and the exported USDZ.
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        // Force the opaque render pass. The baked atlas is opaque, but a stray
        // alpha channel would otherwise let SceneKit sort this double-sided mesh
        // into the transparent pass and render it half-see-through from some
        // angles. `.replace` keeps it solid regardless of the texture's alpha.
        material.blendMode = .replace
        // Disable mipmapping. This is a *per-triangle* atlas: each triangle owns
        // a tiny (~16 px) chart, and neighbouring charts in the atlas are not its
        // neighbours on the surface. Mip levels average 2×2→4×4→… texels, so as
        // soon as a triangle shrinks on screen the sampler blends across chart
        // borders and the model breaks into a grid of colour seams. Sampling the
        // base level (linear min/mag, clamped) keeps every texel inside its own
        // chart — the dilated gutters already cover bilinear at the edges.
        material.diffuse.mipFilter = .none
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        return material
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
