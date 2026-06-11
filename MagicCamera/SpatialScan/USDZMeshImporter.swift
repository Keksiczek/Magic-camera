//
//  USDZMeshImporter.swift
//  Magic Camera
//
//  Reads a USDZ/USD/OBJ model back into the app's MeshData (+ TexturedMesh
//  when the model carries per-vertex UVs and a base-colour texture). Bridges
//  Object Capture's photogrammetry output into the scan library so a captured
//  object can be viewed, measured, edited and re-exported like any scan.
//  Pure ModelIO/ImageIO — safe to run off the main thread.
//

import Foundation
import ImageIO
import ModelIO
import simd
import UniformTypeIdentifiers

enum USDZMeshImporter {

    struct Imported {
        let mesh: MeshData
        let textured: TexturedMesh?
    }

    /// Loads every triangle mesh in the asset (transforms applied, world
    /// space). Returns nil when the file holds no readable triangles.
    static func importModel(from url: URL) -> Imported? {
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else { return nil }

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var texturePNG: Data?
        var textureSize = 0

        for mesh in meshes {
            appendMesh(mesh, vertices: &vertices, normals: &normals,
                       uvs: &uvs, indices: &indices)
            if texturePNG == nil, let (png, size) = baseColorTexture(of: mesh) {
                texturePNG = png
                textureSize = size
            }
        }
        guard !vertices.isEmpty, indices.count >= 3 else { return nil }

        // Some assets ship without (or with partial) normals — rebuild them.
        if normals.count != vertices.count {
            normals = accumulatedNormals(vertices: vertices, indices: indices)
        }
        let meshData = MeshData(vertices: vertices, normals: normals, indices: indices)

        // A texture atlas only makes sense when the UV space is one mesh's.
        var textured: TexturedMesh?
        if meshes.count == 1, uvs.count == vertices.count,
           let texturePNG, textureSize > 0 {
            textured = TexturedMesh(mesh: meshData, uvs: uvs,
                                    texturePNG: texturePNG, textureSize: textureSize)
        }
        return Imported(mesh: meshData, textured: textured)
    }

    // MARK: - Geometry

    private static func appendMesh(_ mesh: MDLMesh,
                                   vertices: inout [SIMD3<Float>],
                                   normals: inout [SIMD3<Float>],
                                   uvs: inout [SIMD2<Float>],
                                   indices: inout [UInt32]) {
        guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition,
                                                       as: .float3) else { return }
        let vertexCount = mesh.vertexCount
        guard vertexCount > 0 else { return }
        let base = UInt32(vertices.count)

        let transform = worldTransform(of: mesh)
        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))

        // The MDLVertexAttributeData locals keep their buffer maps alive while
        // reading; strides come from ModelIO after format conversion.
        for i in 0..<vertexCount {
            let p = positions.dataStart.advanced(by: positions.stride * i)
            let local = SIMD3<Float>(p.loadUnaligned(fromByteOffset: 0, as: Float.self),
                                     p.loadUnaligned(fromByteOffset: 4, as: Float.self),
                                     p.loadUnaligned(fromByteOffset: 8, as: Float.self))
            let world = transform * SIMD4<Float>(local, 1)
            vertices.append(SIMD3<Float>(world.x, world.y, world.z))
        }

        if let normalData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal,
                                                     as: .float3) {
            for i in 0..<vertexCount {
                let p = normalData.dataStart.advanced(by: normalData.stride * i)
                let n = SIMD3<Float>(p.loadUnaligned(fromByteOffset: 0, as: Float.self),
                                     p.loadUnaligned(fromByteOffset: 4, as: Float.self),
                                     p.loadUnaligned(fromByteOffset: 8, as: Float.self))
                let rotated = rotation * n
                normals.append(simd_length_squared(rotated) > 0 ? simd_normalize(rotated) : SIMD3<Float>(0, 1, 0))
            }
        }

        if let uvData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate,
                                                 as: .float2) {
            for i in 0..<vertexCount {
                let p = uvData.dataStart.advanced(by: uvData.stride * i)
                let u = p.loadUnaligned(fromByteOffset: 0, as: Float.self)
                let v = p.loadUnaligned(fromByteOffset: 4, as: Float.self)
                // USD's st origin is bottom-left; the app's atlases (and
                // SceneKit image contents) read top-left.
                uvs.append(SIMD2<Float>(u, 1 - v))
            }
        }

        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
            guard submesh.geometryType == .triangles else { continue }
            let buffer = submesh.indexBuffer(asIndexType: .uInt32)
            let map = buffer.map()
            for k in 0..<submesh.indexCount {
                let idx = map.bytes.loadUnaligned(fromByteOffset: 4 * k, as: UInt32.self)
                indices.append(base + idx)
            }
        }
    }

    /// Local transforms composed up the parent chain.
    private static func worldTransform(of object: MDLObject) -> simd_float4x4 {
        var result = matrix_identity_float4x4
        var node: MDLObject? = object
        while let current = node {
            if let matrix = current.transform?.matrix { result = matrix * result }
            node = current.parent
        }
        return result
    }

    /// Area-weighted vertex normals from face cross products.
    private static func accumulatedNormals(vertices: [SIMD3<Float>],
                                           indices: [UInt32]) -> [SIMD3<Float>] {
        var sums = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var i = 0
        while i + 2 < indices.count {
            let ia = Int(indices[i]), ib = Int(indices[i + 1]), ic = Int(indices[i + 2])
            let face = simd_cross(vertices[ib] - vertices[ia], vertices[ic] - vertices[ia])
            sums[ia] += face; sums[ib] += face; sums[ic] += face
            i += 3
        }
        return sums.map { simd_length_squared($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0) }
    }

    // MARK: - Texture

    /// PNG + pixel size of the first base-colour texture on the mesh.
    private static func baseColorTexture(of mesh: MDLMesh) -> (Data, Int)? {
        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
            guard let property = submesh.material?.property(with: .baseColor),
                  let texture = property.textureSamplerValue?.texture,
                  let cgImage = texture.imageFromTexture()?.takeRetainedValue(),
                  let png = pngData(from: cgImage) else { continue }
            return (png, Int(texture.dimensions.x))
        }
        return nil
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
