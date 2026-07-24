//
//  StudioObject.swift
//  Magic Camera
//
//  One named object on the Model Studio stage. Geometry lives in world space
//  (the same convention as the scan editing ops); `revision` is bumped on any
//  geometry or colour change so the renderer knows to rebuild that node.
//

import Foundation
import simd

/// A photo texture riding along with an object: per-vertex UVs into an atlas.
/// Stored separately from the geometry because rigid transforms and
/// scaling leave it untouched — only topology changes (smooth, reduce, CSG,
/// merge) invalidate it. UV count always equals the object's vertex count
/// (the .mcmesh gallery format guarantees that on import).
///
/// Mirrors `TexturedMesh`'s paging: a room baked across several atlas sheets
/// keeps all of them here, so importing it to the stage doesn't throw away the
/// density the extra pages bought.
struct StudioTexture {
    var uvs: [SIMD2<Float>]
    /// One encoded atlas image per page. Never empty.
    var textures: [Data]
    var textureSize: Int
    /// Page index per triangle. Empty for a single-page atlas.
    var pageOfTri: [UInt8]

    init(uvs: [SIMD2<Float>], texturePNG: Data, textureSize: Int) {
        self.init(uvs: uvs, textures: [texturePNG], textureSize: textureSize, pageOfTri: [])
    }

    init(uvs: [SIMD2<Float>], textures: [Data], textureSize: Int, pageOfTri: [UInt8]) {
        self.uvs = uvs
        self.textures = textures.isEmpty ? [Data()] : textures
        self.textureSize = textureSize
        self.pageOfTri = self.textures.count > 1 ? pageOfTri : []
    }

    /// Everything a baked atlas carries, kept together so the two types convert
    /// without either having to know the other's field list.
    init(_ textured: TexturedMesh) {
        self.init(uvs: textured.uvs, textures: textured.textures,
                  textureSize: textured.textureSize, pageOfTri: textured.pageOfTri)
    }

    var pageCount: Int { textures.count }
    var texturePNG: Data { textures[0] }
}

struct StudioObject: Identifiable {
    let id: UUID
    var name: String
    var mesh: MeshData
    var color: SIMD3<Float>
    var colorName: String
    var texture: StudioTexture?
    var revision: Int

    init(name: String, mesh: MeshData,
         color: SIMD3<Float> = StudioPalette.defaultColor,
         colorName: String = StudioPalette.defaultName,
         texture: StudioTexture? = nil,
         revision: Int) {
        self.id = UUID()
        self.name = name
        self.mesh = mesh
        self.color = color
        self.colorName = colorName
        self.texture = texture
        self.revision = revision
    }

    /// The texture re-attached to the live geometry (which transforms move,
    /// but UVs don't care). Nil when the counts ever disagree.
    var texturedMesh: TexturedMesh? {
        guard let texture, texture.uvs.count == mesh.vertices.count else { return nil }
        return TexturedMesh(mesh: mesh, uvs: texture.uvs,
                            textures: texture.textures,
                            textureSize: texture.textureSize,
                            pageOfTri: texture.pageOfTri)
    }

    /// Bounding-box size in metres (zero for a somehow-empty mesh).
    var dimensions: SIMD3<Float> {
        guard let box = mesh.boundingBox() else { return .zero }
        return box.max - box.min
    }

    var center: SIMD3<Float> {
        guard let box = mesh.boundingBox() else { return .zero }
        return (box.min + box.max) * 0.5
    }
}
