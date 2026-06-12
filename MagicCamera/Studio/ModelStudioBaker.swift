//
//  ModelStudioBaker.swift
//  Magic Camera
//
//  Turns a Model Studio stage into a single saveable mesh. Object colours are
//  preserved by baking a tiny stripe-palette texture: one vertical colour
//  stripe per distinct colour, every vertex UV-pinned to the centre of its
//  object's stripe. Stripes span the full texture height, so the mapping is
//  immune to V-axis flips between viewers and exporters; sampling at stripe
//  centres keeps bilinear/mipmap bleed away from the neighbouring colours.
//

import Foundation
import simd

enum ModelStudioBaker {
    /// Texture edge and stripe count — 16 stripes of 16 px on a 256 px atlas.
    private static let textureSize = 256
    private static let stripeCount = 16

    /// Concatenates every (non-empty) object mesh into one, in stage order —
    /// the same order `bakePalette` assigns UVs in.
    static func merge(_ objects: [StudioObject]) -> MeshData {
        objects.reduce(MeshData()) { merged, object in
            merged.appending(object.mesh)
        }
    }

    /// Builds the palette texture and per-vertex UVs for `merged` (which must
    /// be the result of `merge(objects)`). Returns nil when the stage is empty
    /// or PNG encoding fails.
    static func bakePalette(_ objects: [StudioObject], merged: MeshData) -> TexturedMesh? {
        let contributing = objects.filter { !$0.mesh.isEmpty }
        guard !merged.isEmpty, !contributing.isEmpty else { return nil }

        // Distinct colours → stripe indices (first-come order, capped at the
        // stripe count; overflow reuses the nearest existing stripe).
        var stripes: [SIMD3<Float>] = []
        var stripeOfObject: [Int] = []
        for object in contributing {
            if let existing = stripes.firstIndex(where: { simd_length($0 - object.color) < 0.01 }) {
                stripeOfObject.append(existing)
            } else if stripes.count < stripeCount {
                stripeOfObject.append(stripes.count)
                stripes.append(object.color)
            } else {
                let nearest = stripes.indices.min {
                    simd_length(stripes[$0] - object.color) < simd_length(stripes[$1] - object.color)
                } ?? 0
                stripeOfObject.append(nearest)
            }
        }

        let stripeWidth = textureSize / stripeCount
        var pixels = [UInt8](repeating: 0, count: textureSize * textureSize * 4)
        for (index, color) in stripes.enumerated() {
            for y in 0..<textureSize {
                for x in (index * stripeWidth)..<((index + 1) * stripeWidth) {
                    TextureAtlas.write(color, x: x, y: y, texSize: textureSize, into: &pixels)
                }
            }
        }
        // Spread the painted stripes over the unused remainder so mip levels
        // never average in black.
        TextureAtlas.fillGutters(pixels: &pixels, size: textureSize)
        guard let png = TextureAtlas.encodePNG(pixels: pixels, size: textureSize) else { return nil }

        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity(merged.vertices.count)
        for (objectIndex, object) in contributing.enumerated() {
            let u = (Float(stripeOfObject[objectIndex]) + 0.5) / Float(stripeCount)
            uvs.append(contentsOf: repeatElement(SIMD2<Float>(u, 0.5),
                                                 count: object.mesh.vertices.count))
        }
        guard uvs.count == merged.vertices.count else { return nil }
        return TexturedMesh(mesh: merged, uvs: uvs,
                            texturePNG: png, textureSize: textureSize)
    }
}
