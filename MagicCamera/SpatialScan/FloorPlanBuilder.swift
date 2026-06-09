//
//  FloorPlanBuilder.swift
//  Magic Camera
//
//  Derives a 2D top-down floor plan from a classified mesh: wall/door/window
//  triangles are projected onto the ground (XZ) plane as line segments, and the
//  floor area is summed from floor triangles. Pure value-type math.
//

import simd

struct FloorPlan {
    let wallSegments: [(SIMD2<Float>, SIMD2<Float>)]   // projected onto XZ
    let min: SIMD2<Float>
    let max: SIMD2<Float>
    let floorArea: Float                               // m²

    var size: SIMD2<Float> { max - min }
}

enum FloorPlanBuilder {
    private static let maxSegments = 24_000

    /// Builds a plan, or `nil` when the mesh has no classification or no walls.
    static func build(from mesh: MeshData) -> FloorPlan? {
        guard mesh.hasClassification, mesh.indices.count >= 3 else { return nil }

        let wallClasses: Set<UInt8> = [
            MeshClassification.wall.rawValue,
            MeshClassification.door.rawValue,
            MeshClassification.window.rawValue
        ]
        let floorRaw = MeshClassification.floor.rawValue

        var segments: [(SIMD2<Float>, SIMD2<Float>)] = []
        var floorArea: Float = 0
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)

        var i = 0
        while i + 2 < mesh.indices.count {
            let ia = Int(mesh.indices[i]), ib = Int(mesh.indices[i + 1]), ic = Int(mesh.indices[i + 2])
            let a = mesh.vertices[ia], b = mesh.vertices[ib], c = mesh.vertices[ic]
            let pa = SIMD2<Float>(a.x, a.z), pb = SIMD2<Float>(b.x, b.z), pc = SIMD2<Float>(c.x, c.z)
            lo = simd_min(lo, simd_min(pa, simd_min(pb, pc)))
            hi = simd_max(hi, simd_max(pa, simd_max(pb, pc)))

            let cls = triangleClass(mesh.classifications, ia, ib, ic)
            if wallClasses.contains(cls), segments.count < maxSegments {
                segments.append((pa, pb)); segments.append((pb, pc)); segments.append((pc, pa))
            } else if cls == floorRaw {
                floorArea += simd_length(simd_cross(b - a, c - a)) * 0.5
            }
            i += 3
        }

        guard !segments.isEmpty, lo.x <= hi.x else { return nil }
        return FloorPlan(wallSegments: segments, min: lo, max: hi, floorArea: floorArea)
    }

    /// Triangle class = the class shared by a majority of its vertices.
    private static func triangleClass(_ classes: [UInt8], _ a: Int, _ b: Int, _ c: Int) -> UInt8 {
        let ca = classes[a], cb = classes[b], cc = classes[c]
        if ca == cb || ca == cc { return ca }
        if cb == cc { return cb }
        return ca
    }
}
