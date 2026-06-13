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

/// A photo texture riding along with an object: per-vertex UVs into a PNG
/// atlas. Stored separately from the geometry because rigid transforms and
/// scaling leave it untouched — only topology changes (smooth, reduce, CSG,
/// merge) invalidate it. UV count always equals the object's vertex count
/// (the .mcmesh gallery format guarantees that on import).
struct StudioTexture {
    var uvs: [SIMD2<Float>]
    var texturePNG: Data
    var textureSize: Int
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
                            texturePNG: texture.texturePNG,
                            textureSize: texture.textureSize)
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
