//
//  StudioPrimitives.swift
//  Magic Camera
//
//  Parametric primitive meshes for Model Studio — generated as plain MeshData
//  so every existing mesh tool (smooth, decimate, weld, export, texture-bake)
//  works on them unchanged. All primitives sit on the ground plane (y = 0),
//  centred on the origin in X/Z; `size` is the bounding box in metres.
//  Triangles wind counter-clockwise seen from outside, normals are analytic.
//

import Foundation
import simd

/// The shapes Model Studio can create, by button or by model tool call.
enum PrimitiveShape: String, CaseIterable, Identifiable, Sendable {
    case box, sphere, cylinder, cone, torus, plane
    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .box:      return "cube"
        case .sphere:   return "circle"
        case .cylinder: return "cylinder"
        case .cone:     return "cone"
        case .torus:    return "circle.circle"
        case .plane:    return "square"
        }
    }

    /// Sensible tabletop default when no size is given.
    var defaultSize: SIMD3<Float> {
        switch self {
        case .box:      return SIMD3(0.2, 0.2, 0.2)
        case .sphere:   return SIMD3(0.2, 0.2, 0.2)
        case .cylinder: return SIMD3(0.15, 0.25, 0.15)
        case .cone:     return SIMD3(0.18, 0.25, 0.18)
        case .torus:    return SIMD3(0.25, 0.07, 0.25)
        case .plane:    return SIMD3(0.5, 0, 0.5)
        }
    }

    /// Lenient name parsing for model tool calls ("ball", "block", "disc"…).
    static func parse(_ raw: String) -> PrimitiveShape? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = PrimitiveShape(rawValue: name) { return exact }
        switch name {
        case "cube", "block", "brick", "rectangle", "cuboid": return .box
        case "ball", "orb", "ellipsoid", "globe":             return .sphere
        case "tube", "pillar", "column", "disc", "disk", "puck": return .cylinder
        case "pyramid", "spike":                              return .cone
        case "ring", "donut", "doughnut":                     return .torus
        case "floor", "ground", "quad", "sheet", "slab":      return .plane
        default: return nil
        }
    }
}

enum PrimitiveMesher {

    /// Builds `shape` with bounding box `size` (clamped to 1 cm … 10 m per
    /// axis), base resting on y = 0 and centred on the origin in X/Z.
    static func mesh(_ shape: PrimitiveShape, size: SIMD3<Float>) -> MeshData {
        let s = SIMD3<Float>(clamp(size.x), shape == .plane ? 0 : clamp(size.y), clamp(size.z))
        switch shape {
        case .box:      return box(s)
        case .sphere:   return sphere(s)
        case .cylinder: return cylinder(s)
        case .cone:     return cone(s)
        case .torus:    return torus(s)
        case .plane:    return plane(s)
        }
    }

    private static func clamp(_ v: Float) -> Float {
        min(max(v.isFinite ? v : 0.2, 0.01), 10)
    }

    // MARK: - Builder state

    private struct Builder {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        mutating func add(_ position: SIMD3<Float>, _ normal: SIMD3<Float>) -> UInt32 {
            vertices.append(position)
            normals.append(normal)
            return UInt32(vertices.count - 1)
        }

        mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
            indices.append(a); indices.append(b); indices.append(c)
        }

        var mesh: MeshData { MeshData(vertices: vertices, normals: normals, indices: indices) }
    }

    // MARK: - Box

    private static func box(_ s: SIMD3<Float>) -> MeshData {
        let hx = s.x / 2, h = s.y, hz = s.z / 2
        var b = Builder()
        // Each face gets its own four vertices (flat normals), wound CCW from
        // outside: (a, b, c, d) → triangles (a, b, c) and (a, c, d).
        func face(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>,
                  _ p3: SIMD3<Float>, normal: SIMD3<Float>) {
            let i0 = b.add(p0, normal), i1 = b.add(p1, normal)
            let i2 = b.add(p2, normal), i3 = b.add(p3, normal)
            b.triangle(i0, i1, i2)
            b.triangle(i0, i2, i3)
        }
        face(SIMD3(-hx, h, -hz), SIMD3(-hx, h, hz), SIMD3(hx, h, hz), SIMD3(hx, h, -hz),
             normal: SIMD3(0, 1, 0))                                   // top
        face(SIMD3(-hx, 0, -hz), SIMD3(hx, 0, -hz), SIMD3(hx, 0, hz), SIMD3(-hx, 0, hz),
             normal: SIMD3(0, -1, 0))                                  // bottom
        face(SIMD3(-hx, 0, hz), SIMD3(hx, 0, hz), SIMD3(hx, h, hz), SIMD3(-hx, h, hz),
             normal: SIMD3(0, 0, 1))                                   // front (+z)
        face(SIMD3(hx, 0, -hz), SIMD3(-hx, 0, -hz), SIMD3(-hx, h, -hz), SIMD3(hx, h, -hz),
             normal: SIMD3(0, 0, -1))                                  // back (−z)
        face(SIMD3(hx, 0, hz), SIMD3(hx, 0, -hz), SIMD3(hx, h, -hz), SIMD3(hx, h, hz),
             normal: SIMD3(1, 0, 0))                                   // right (+x)
        face(SIMD3(-hx, 0, -hz), SIMD3(-hx, 0, hz), SIMD3(-hx, h, hz), SIMD3(-hx, h, -hz),
             normal: SIMD3(-1, 0, 0))                                  // left (−x)
        return b.mesh
    }

    // MARK: - Sphere (ellipsoid)

    private static func sphere(_ s: SIMD3<Float>, rings: Int = 16, segments: Int = 24) -> MeshData {
        let r = SIMD3<Float>(s.x / 2, s.y / 2, s.z / 2)
        let center = SIMD3<Float>(0, r.y, 0)
        var b = Builder()
        // (rings+1) × (segments+1) grid, seam column duplicated.
        for ring in 0...rings {
            let theta = Float.pi * Float(ring) / Float(rings)
            for seg in 0...segments {
                let phi = 2 * Float.pi * Float(seg) / Float(segments)
                let unit = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                // Ellipsoid normal is the gradient of the implicit surface.
                let normal = simd_normalize(unit / r)
                _ = b.add(center + unit * r, normal)
            }
        }
        let cols = UInt32(segments + 1)
        for ring in 0..<rings {
            for seg in 0..<segments {
                let a = UInt32(ring) * cols + UInt32(seg)        // (ring, seg)
                let below = a + cols                             // (ring+1, seg)
                // CCW from outside (verified by cross product at the pole).
                b.triangle(a, below + 1, below)
                b.triangle(a, a + 1, below + 1)
            }
        }
        return b.mesh
    }

    // MARK: - Cylinder

    private static func cylinder(_ s: SIMD3<Float>, segments: Int = 32) -> MeshData {
        let rx = s.x / 2, rz = s.z / 2, h = s.y
        var b = Builder()
        // Side: two rings with smooth radial normals.
        for seg in 0...segments {
            let phi = 2 * Float.pi * Float(seg) / Float(segments)
            let p = SIMD3<Float>(cos(phi) * rx, 0, sin(phi) * rz)
            let normal = simd_normalize(SIMD3<Float>(cos(phi) * rz, 0, sin(phi) * rx))
            _ = b.add(p, normal)                                  // bottom ring: 2*seg
            _ = b.add(SIMD3(p.x, h, p.z), normal)                 // top ring:    2*seg+1
        }
        for seg in 0..<segments {
            let b0 = UInt32(2 * seg), t0 = b0 + 1
            let b1 = UInt32(2 * (seg + 1)), t1 = b1 + 1
            b.triangle(b0, t0, t1)
            b.triangle(b0, t1, b1)
        }
        addCap(&b, y: h, rx: rx, rz: rz, up: true, segments: segments)
        addCap(&b, y: 0, rx: rx, rz: rz, up: false, segments: segments)
        return b.mesh
    }

    /// Triangle-fan cap at height `y`; `up` picks the facing and winding.
    private static func addCap(_ b: inout Builder, y: Float, rx: Float, rz: Float,
                               up: Bool, segments: Int) {
        let normal = SIMD3<Float>(0, up ? 1 : -1, 0)
        let center = b.add(SIMD3(0, y, 0), normal)
        var ring: [UInt32] = []
        for seg in 0...segments {
            let phi = 2 * Float.pi * Float(seg) / Float(segments)
            ring.append(b.add(SIMD3(cos(phi) * rx, y, sin(phi) * rz), normal))
        }
        for seg in 0..<segments {
            if up { b.triangle(center, ring[seg + 1], ring[seg]) }
            else  { b.triangle(center, ring[seg], ring[seg + 1]) }
        }
    }

    // MARK: - Cone

    private static func cone(_ s: SIMD3<Float>, segments: Int = 32) -> MeshData {
        let rx = s.x / 2, rz = s.z / 2, h = s.y
        let slope = (rx + rz) / 2                      // mean radius sets the tilt
        var b = Builder()
        var base: [UInt32] = []
        var apex: [UInt32] = []
        for seg in 0...segments {
            let phi = 2 * Float.pi * Float(seg) / Float(segments)
            let radial = simd_normalize(SIMD3<Float>(cos(phi) * rz, 0, sin(phi) * rx))
            let normal = simd_normalize(radial * h + SIMD3<Float>(0, slope, 0))
            base.append(b.add(SIMD3(cos(phi) * rx, 0, sin(phi) * rz), normal))
            // The apex is duplicated per segment so the side stays smooth
            // around the rim without smearing one normal across the tip.
            apex.append(b.add(SIMD3(0, h, 0), normal))
        }
        for seg in 0..<segments {
            b.triangle(base[seg], apex[seg], base[seg + 1])
        }
        addCap(&b, y: 0, rx: rx, rz: rz, up: false, segments: segments)
        return b.mesh
    }

    // MARK: - Torus

    private static func torus(_ s: SIMD3<Float>, segments: Int = 32, sides: Int = 16) -> MeshData {
        // Tube radius from the height; the major radius fills the footprint.
        let tube = min(s.y / 2, min(s.x, s.z) / 4)
        let rx = s.x / 2 - tube, rz = s.z / 2 - tube
        var b = Builder()
        for seg in 0...segments {
            let phi = 2 * Float.pi * Float(seg) / Float(segments)
            let radial = SIMD3<Float>(cos(phi), 0, sin(phi))
            let ringCenter = SIMD3<Float>(radial.x * rx, tube, radial.z * rz)
            for side in 0...sides {
                let psi = 2 * Float.pi * Float(side) / Float(sides)
                let normal = simd_normalize(radial * cos(psi) + SIMD3<Float>(0, sin(psi), 0))
                _ = b.add(ringCenter + normal * tube, normal)
            }
        }
        let cols = UInt32(sides + 1)
        for seg in 0..<segments {
            for side in 0..<sides {
                let p00 = UInt32(seg) * cols + UInt32(side)
                let p01 = p00 + 1            // next side (around the tube)
                let p10 = p00 + cols         // next segment (around the axis)
                let p11 = p10 + 1
                b.triangle(p00, p01, p11)
                b.triangle(p00, p11, p10)
            }
        }
        return b.mesh
    }

    // MARK: - Plane

    private static func plane(_ s: SIMD3<Float>) -> MeshData {
        let hx = s.x / 2, hz = s.z / 2
        var b = Builder()
        let n = SIMD3<Float>(0, 1, 0)
        let a = b.add(SIMD3(-hx, 0, -hz), n)
        let p1 = b.add(SIMD3(hx, 0, -hz), n)
        let p2 = b.add(SIMD3(hx, 0, hz), n)
        let p3 = b.add(SIMD3(-hx, 0, hz), n)
        b.triangle(a, p2, p1)
        b.triangle(a, p3, p2)
        return b.mesh
    }
}

/// Named display colours for Studio objects — model tool calls and the manual
/// swatch row share this vocabulary.
enum StudioPalette {
    static let colors: [(name: String, value: SIMD3<Float>)] = [
        ("gray",   SIMD3(0.66, 0.66, 0.68)),
        ("white",  SIMD3(0.94, 0.94, 0.94)),
        ("black",  SIMD3(0.13, 0.13, 0.14)),
        ("red",    SIMD3(0.90, 0.25, 0.22)),
        ("orange", SIMD3(0.98, 0.56, 0.19)),
        ("yellow", SIMD3(0.95, 0.83, 0.23)),
        ("green",  SIMD3(0.30, 0.72, 0.36)),
        ("mint",   SIMD3(0.45, 0.88, 0.70)),
        ("teal",   SIMD3(0.22, 0.66, 0.72)),
        ("blue",   SIMD3(0.28, 0.51, 0.92)),
        ("purple", SIMD3(0.58, 0.41, 0.88)),
        ("pink",   SIMD3(0.94, 0.50, 0.72)),
        ("brown",  SIMD3(0.55, 0.40, 0.26)),
    ]

    static let defaultName = "gray"
    static var defaultColor: SIMD3<Float> { colors[0].value }

    /// Case-insensitive lookup with a couple of spellings ("grey", "violet").
    static func color(named raw: String) -> (name: String, value: SIMD3<Float>)? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "grey", "silver": name = "gray"
        case "violet":         name = "purple"
        case "turquoise", "cyan": name = "teal"
        case "lime":           name = "green"
        case "tan", "beige", "wood": name = "brown"
        default: break
        }
        guard let match = colors.first(where: { $0.name == name }) else { return nil }
        return match
    }
}
