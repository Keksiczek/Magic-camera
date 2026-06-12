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

struct StudioObject: Identifiable {
    let id: UUID
    var name: String
    var mesh: MeshData
    var color: SIMD3<Float>
    var colorName: String
    var revision: Int

    init(name: String, mesh: MeshData,
         color: SIMD3<Float> = StudioPalette.defaultColor,
         colorName: String = StudioPalette.defaultName,
         revision: Int) {
        self.id = UUID()
        self.name = name
        self.mesh = mesh
        self.color = color
        self.colorName = colorName
        self.revision = revision
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
