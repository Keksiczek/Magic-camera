//
//  CapturedRoomMesh.swift
//  Magic Camera
//
//  Bridges RoomPlan into the spatial-scan world: converts a CapturedRoom's
//  parametric elements (walls, doors, windows, floors, objects) into the app's
//  classified MeshData. Each element becomes an oriented box carrying the
//  matching surface classification, so a saved room behaves like any other
//  scan — viewable in the mesh viewer (with classification colours), measurable
//  with the 3D ruler, floor-plannable and exportable to every mesh format.
//

#if canImport(RoomPlan)

import RoomPlan
import simd

enum CapturedRoomMesh {

    /// Surfaces are parametrically flat (z ≈ 0); give them a little body so
    /// they render from both sides and export as solids. Doors/windows are a
    /// touch thicker than walls so they stand proud instead of z-fighting.
    private static let surfaceThickness: Float = 0.04
    private static let insetThickness: Float = 0.07

    /// Builds a classified triangle mesh (world space) from the room.
    static func meshData(from room: CapturedRoom) -> MeshData {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var classes: [UInt8] = []

        func add(_ dimensions: SIMD3<Float>, _ transform: simd_float4x4,
                 _ classification: MeshClassification, minThickness: Float) {
            appendBox(dimensions: dimensions, transform: transform,
                      classification: classification, minThickness: minThickness,
                      vertices: &vertices, normals: &normals,
                      indices: &indices, classes: &classes)
        }

        for s in room.walls   { add(s.dimensions, s.transform, .wall,   minThickness: surfaceThickness) }
        for s in room.doors   { add(s.dimensions, s.transform, .door,   minThickness: insetThickness) }
        for s in room.windows { add(s.dimensions, s.transform, .window, minThickness: insetThickness) }
        for s in room.floors  { add(s.dimensions, s.transform, .floor,  minThickness: surfaceThickness) }
        for o in room.objects { add(o.dimensions, o.transform, classification(for: o.category),
                                    minThickness: surfaceThickness) }
        // Openings are passages (holes in walls) — boxing them would block the
        // doorway visually, so they are intentionally skipped.

        return MeshData(vertices: vertices, normals: normals,
                        indices: indices, classifications: classes)
    }

    /// RoomPlan object categories → the ARKit-style classes the viewers know.
    /// Anything without a sensible counterpart renders as unclassified grey.
    private static func classification(for category: CapturedRoom.Object.Category)
        -> MeshClassification {
        switch category {
        case .table:              return .table
        case .sofa, .chair, .bed: return .seat
        default:                  return .none
        }
    }

    /// Appends one oriented box (6 faces × 2 triangles, flat-shaded normals).
    private static func appendBox(dimensions: SIMD3<Float>, transform: simd_float4x4,
                                  classification: MeshClassification, minThickness: Float,
                                  vertices: inout [SIMD3<Float>], normals: inout [SIMD3<Float>],
                                  indices: inout [UInt32], classes: inout [UInt8]) {
        let half = SIMD3<Float>(max(dimensions.x, minThickness),
                                max(dimensions.y, minThickness),
                                max(dimensions.z, minThickness)) * 0.5
        guard half.min() > 0 else { return }
        let rotation = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))

        // Outward normal + in-plane axes per face; the (u, v) order makes the
        // corner loop counter-clockwise when seen from outside the box.
        let xAxis = SIMD3<Float>(1, 0, 0)
        let yAxis = SIMD3<Float>(0, 1, 0)
        let zAxis = SIMD3<Float>(0, 0, 1)
        let faces: [(n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (xAxis, yAxis, zAxis), (-xAxis, zAxis, yAxis),
            (yAxis, zAxis, xAxis), (-yAxis, xAxis, zAxis),
            (zAxis, xAxis, yAxis), (-zAxis, yAxis, xAxis),
        ]
        for face in faces {
            let base = UInt32(vertices.count)
            let centre: SIMD3<Float> = face.n * half
            let du: SIMD3<Float> = face.u * half
            let dv: SIMD3<Float> = face.v * half
            let c0: SIMD3<Float> = centre - du - dv
            let c1: SIMD3<Float> = centre + du - dv
            let c2: SIMD3<Float> = centre + du + dv
            let c3: SIMD3<Float> = centre - du + dv
            let corners: [SIMD3<Float>] = [c0, c1, c2, c3]
            let worldNormal = simd_normalize(rotation * face.n)
            for corner in corners {
                let world = transform * SIMD4<Float>(corner, 1)
                vertices.append(SIMD3(world.x, world.y, world.z))
                normals.append(worldNormal)
                classes.append(classification.rawValue)
            }
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }
    }
}

#endif
