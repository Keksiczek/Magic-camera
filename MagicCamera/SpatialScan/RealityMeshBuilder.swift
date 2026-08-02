//
//  RealityMeshBuilder.swift
//  Magic Camera
//
//  MeshData / TexturedMesh → a RealityKit `ModelEntity`. The first half of the
//  SceneKit → RealityKit migration: everything downstream of this is rendering,
//  and everything upstream is untouched.
//
//  Three things it has to get right, all of which the SceneKit path learned the
//  hard way:
//
//  · **Pages.** A room's atlas spans several 8192² sheets, and a triangle samples
//    exactly one of them. Each page becomes its own `MeshDescriptor` with its own
//    material index, the same shape the glTF exporter writes as one primitive per
//    page. Folding them would sample the wrong sheet.
//  · **UV origin.** Untouched. The atlas UVs go into glTF unchanged and render
//    correctly there, and glTF and RealityKit share the top-left origin, so a
//    flip here would be a bug, not a fix.
//  · **Double-sided.** Reconstructed surfaces are open shells seen from both
//    sides, so face culling is off — the same reason every SceneKit material in
//    this app sets `isDoubleSided`.
//

import Foundation
import simd
#if canImport(RealityKit)
import RealityKit
#endif
import CoreGraphics
import ImageIO
import UIKit

/// The per-page geometry a renderer needs, with indices remapped into a compact
/// vertex buffer for that page alone.
///
/// Pure value math, deliberately outside the RealityKit availability gate: this is
/// the part with the off-by-one risk, so it stays testable on any OS.
enum MeshPageGeometry {
    struct Page: Sendable {
        var page: Int
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var textureCoordinates: [SIMD2<Float>]
        /// Triangle indices into this page's own vertex arrays.
        var indices: [UInt32]
    }

    /// Splits a mesh into one entry per non-empty atlas page.
    ///
    /// `uvs` and `pageOfTri` come from `TexturedMesh`; pass an empty `uvs` for an
    /// untextured mesh and the single page comes back with no texture
    /// coordinates. Pages that own no triangles are dropped — an empty draw call
    /// is invalid in glTF and pointless here.
    static func pages(mesh: MeshData, uvs: [SIMD2<Float>] = [],
                      pageOfTri: [UInt8] = [], pageCount: Int = 1) -> [Page] {
        let triangleCount = mesh.indices.count / 3
        guard triangleCount > 0 else { return [] }
        let hasUVs = uvs.count == mesh.vertices.count
        let hasNormals = mesh.normals.count == mesh.vertices.count
        let pages = max(pageCount, 1)

        var result: [Page] = []
        for page in 0..<pages {
            // A remap per page, so a vertex shared by two pages is duplicated into
            // both rather than dragging the whole vertex buffer into each.
            var remap = [Int32](repeating: -1, count: mesh.vertices.count)
            var current = Page(page: page, positions: [], normals: [],
                               textureCoordinates: [], indices: [])
            for t in 0..<triangleCount {
                let owner = pageOfTri.isEmpty ? 0 : Int(pageOfTri[min(t, pageOfTri.count - 1)])
                guard owner == page else { continue }
                for k in 0..<3 {
                    let v = Int(mesh.indices[t * 3 + k])
                    guard v < mesh.vertices.count else { continue }
                    if remap[v] < 0 {
                        remap[v] = Int32(current.positions.count)
                        current.positions.append(mesh.vertices[v])
                        current.normals.append(hasNormals ? mesh.normals[v] : SIMD3(0, 1, 0))
                        if hasUVs { current.textureCoordinates.append(uvs[v]) }
                    }
                    current.indices.append(UInt32(remap[v]))
                }
            }
            // A partial triangle would mean a corrupt index buffer; drop the tail
            // rather than hand a renderer something it will assert on.
            let whole = current.indices.count - current.indices.count % 3
            current.indices = Array(current.indices.prefix(whole))
            if !current.indices.isEmpty { result.append(current) }
        }
        return result
    }
}

#if canImport(RealityKit)
@available(iOS 18.0, *)
enum RealityMeshBuilder {

    enum BuildError: LocalizedError {
        case empty
        var errorDescription: String? { "There is no geometry to show." }
    }

    /// Neutral surface for an untextured mesh — the same read as SceneKit's
    /// default-lit grey, so switching renderers does not also change the look.
    private static let untexturedColor = CGColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1)

    static func entity(mesh: MeshData, textured: TexturedMesh? = nil) throws -> ModelEntity {
        let pages = MeshPageGeometry.pages(mesh: textured?.mesh ?? mesh,
                                           uvs: textured?.uvs ?? [],
                                           pageOfTri: textured?.pageOfTri ?? [],
                                           pageCount: textured?.textures.count ?? 1)
        guard !pages.isEmpty else { throw BuildError.empty }

        var descriptors: [MeshDescriptor] = []
        var materials: [any RealityKit.Material] = []
        for (slot, page) in pages.enumerated() {
            var descriptor = MeshDescriptor(name: "page-\(page.page)")
            descriptor.positions = MeshBuffers.Positions(page.positions)
            descriptor.normals = MeshBuffers.Normals(page.normals)
            if page.textureCoordinates.count == page.positions.count {
                descriptor.textureCoordinates =
                    MeshBuffers.TextureCoordinates(page.textureCoordinates)
            }
            descriptor.primitives = .triangles(page.indices)
            descriptor.materials = .allFaces(UInt32(slot))
            descriptors.append(descriptor)
            materials.append(material(for: textured, page: page.page))
        }

        let resource = try MeshResource.generate(from: descriptors)
        return ModelEntity(mesh: resource, materials: materials)
    }

    private static func material(for textured: TexturedMesh?, page: Int) -> any RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        // Baked photo colour is already lit; treat it as pure albedo so the
        // renderer does not light it a second time.
        material.roughness = 1.0
        material.metallic = 0.0
        // Reconstructed surfaces are open shells — the inside of a room IS the
        // side you look at.
        material.faceCulling = .none
        if let textured, page < textured.textures.count,
           let image = cgImage(textured.textures[page]),
           let resource = try? TextureResource(image: image, options: .init(semantic: .color)) {
            material.baseColor = .init(texture: .init(resource))
        } else {
            material.baseColor = .init(tint: UIColor(cgColor: untexturedColor))
        }
        return material
    }

    /// Decodes an encoded atlas page. The atlas ships as JPEG (PNG for Studio
    /// palettes), so this must not assume either.
    private static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
#endif
