//
//  MeshBoolean.swift
//  Magic Camera
//
//  Voxel CSG for Model Studio: union / subtract / intersect of two solid
//  meshes. Both meshes are sampled into signed-distance grids over a shared
//  lattice — distance from a narrow-band triangle splat, sign from ray-parity
//  along Z columns — the fields are combined with the standard SDF operators
//  (min, max-of-negation, max) and the result is polygonised by the existing
//  MarchingCubes. The output is a resampled approximation at the grid
//  resolution, which is what makes the operation robust on imperfect scan
//  meshes where exact BSP-style CSG would fall over.
//
//  Open (non-solid) inputs have no well-defined inside; the parity sign then
//  degrades and the result may be empty — callers should report that honestly.
//

import Foundation
import simd

enum MeshBoolean {

    enum Operation: String, CaseIterable, Sendable {
        case union, subtract, intersect

        /// Lenient parsing for model tool calls ("carve", "join", "overlap"…).
        static func parse(_ raw: String) -> Operation? {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let exact = Operation(rawValue: name) { return exact }
            switch name {
            case "join", "add", "merge", "combine", "fuse":            return .union
            case "carve", "cut", "difference", "remove", "minus":      return .subtract
            case "intersection", "overlap", "common", "and":           return .intersect
            default: return nil
            }
        }
    }

    /// How finely a boolean resamples its result. The lattice is cubic, so cost
    /// and memory scale with the cube of the tier: `fine` is ~4.6× `standard`.
    /// A boolean *resamples* both inputs onto this lattice, so the tier is also
    /// the detail ceiling of the output — a scanned 300 k-triangle model pushed
    /// through a `fast` boolean comes back visibly softened. That is why this is
    /// a user-facing choice and not a constant.
    enum Detail: String, CaseIterable, Identifiable, Sendable {
        case fast = "Fast"
        case standard = "Standard"
        case fine = "Fine"

        var id: String { rawValue }

        /// Lattice count along the region's longest axis.
        var resolution: Int {
            switch self {
            case .fast:     return 64
            case .standard: return 96
            case .fine:     return 160
            }
        }

        var detailLine: String {
            switch self {
            case .fast:     return "Quickest — for blocking out shapes."
            case .standard: return "The balanced default."
            case .fine:     return "Keeps detail on scanned models; slower and heavier."
            }
        }
    }

    /// Cells of padding around the region; also sets the SDF band in cells.
    private static let pad = 3

    /// Combines two solid meshes. `resolution` is the lattice count along the
    /// region's longest axis. Returns nil when the operation has no defined
    /// region (intersect/subtract without overlap potential) or produces no
    /// surface (e.g. open inputs, or a subtract that removed everything).
    static func combine(_ a: MeshData, _ b: MeshData, operation: Operation,
                        resolution: Int = Detail.standard.resolution) -> MeshData? {
        guard !a.isEmpty, !b.isEmpty,
              let boxA = a.boundingBox(), let boxB = b.boundingBox() else { return nil }

        // The lattice only needs to cover where the result can have surface.
        let region: (min: SIMD3<Float>, max: SIMD3<Float>)
        switch operation {
        case .union:     region = (simd_min(boxA.min, boxB.min), simd_max(boxA.max, boxB.max))
        case .subtract:  region = boxA
        case .intersect:
            let lo = simd_max(boxA.min, boxB.min)
            let hi = simd_min(boxA.max, boxB.max)
            guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { return nil }
            region = (lo, hi)
        }

        let extent = region.max - region.min
        let maxExtent = max(extent.x, extent.y, extent.z)
        guard maxExtent > 0 else { return nil }
        let cellSize = maxExtent / Float(max(resolution, 16))
        // Fractional offsets keep lattice points off axis-aligned faces, and
        // they differ per axis so columns can't ride exactly along shared
        // triangle diagonals (x−y correlated edges would double-count parity).
        let origin = region.min - cellSize * SIMD3<Float>(Float(pad) + 0.31,
                                                          Float(pad) + 0.43,
                                                          Float(pad) + 0.37)
        let nx = Int(ceil(extent.x / cellSize)) + 2 * pad + 2
        let ny = Int(ceil(extent.y / cellSize)) + 2 * pad + 2
        let nz = Int(ceil(extent.z / cellSize)) + 2 * pad + 2
        let band = Float(pad) * cellSize

        var fieldA = signedField(a, origin: origin, cellSize: cellSize,
                                 nx: nx, ny: ny, nz: nz, band: band)
        let fieldB = signedField(b, origin: origin, cellSize: cellSize,
                                 nx: nx, ny: ny, nz: nz, band: band)

        switch operation {
        case .union:     for i in 0..<fieldA.count { fieldA[i] = min(fieldA[i], fieldB[i]) }
        case .subtract:  for i in 0..<fieldA.count { fieldA[i] = max(fieldA[i], -fieldB[i]) }
        case .intersect: for i in 0..<fieldA.count { fieldA[i] = max(fieldA[i], fieldB[i]) }
        }

        // Collect only the sign-crossing cells for the sparse polygoniser.
        var cells: [MarchingCubes.Cell] = []
        var corner = [Float](repeating: 0, count: 8)
        for k in 0..<(nz - 1) {
            for j in 0..<(ny - 1) {
                for i in 0..<(nx - 1) {
                    var negative = 0
                    for c in 0..<8 {
                        let o = MarchingCubes.cornerOffsets[c]
                        let idx = ((k + Int(o.z)) * ny + j + Int(o.y)) * nx + i + Int(o.x)
                        corner[c] = fieldA[idx]
                        if corner[c] < 0 { negative += 1 }
                    }
                    guard negative > 0, negative < 8 else { continue }
                    cells.append(MarchingCubes.Cell(
                        base: SIMD3<Int32>(Int32(i), Int32(j), Int32(k)),
                        values: (corner[0], corner[1], corner[2], corner[3],
                                 corner[4], corner[5], corner[6], corner[7])))
                }
            }
        }
        return MarchingCubes.mesh(cells: cells, origin: origin, cellSize: cellSize)
    }

    // MARK: - Signed-distance sampling

    /// Samples `mesh` on the lattice: magnitude from a 2-cell triangle splat
    /// (clamped to ±band beyond it), sign from crossing parity along +Z rays.
    /// Only voxels within one cell of the surface drive marching cubes, and
    /// those are always inside the splat, so the clamp never distorts them.
    private static func signedField(_ mesh: MeshData, origin: SIMD3<Float>,
                                    cellSize: Float, nx: Int, ny: Int, nz: Int,
                                    band: Float) -> [Float] {
        var distance = [Float](repeating: band, count: nx * ny * nz)
        var crossings = [[Float]](repeating: [], count: nx * ny)
        let splat = 2

        var t = 0
        while t + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[t])]
            let b = mesh.vertices[Int(mesh.indices[t + 1])]
            let c = mesh.vertices[Int(mesh.indices[t + 2])]
            t += 3

            // Narrow-band unsigned distance splat.
            let triMin = simd_min(simd_min(a, b), c)
            let triMax = simd_max(simd_max(a, b), c)
            let i0 = max(Int(floor((triMin.x - origin.x) / cellSize)) - splat, 0)
            let i1 = min(Int(ceil((triMax.x - origin.x) / cellSize)) + splat, nx - 1)
            let j0 = max(Int(floor((triMin.y - origin.y) / cellSize)) - splat, 0)
            let j1 = min(Int(ceil((triMax.y - origin.y) / cellSize)) + splat, ny - 1)
            let k0 = max(Int(floor((triMin.z - origin.z) / cellSize)) - splat, 0)
            let k1 = min(Int(ceil((triMax.z - origin.z) / cellSize)) + splat, nz - 1)
            if i0 <= i1, j0 <= j1, k0 <= k1 {
                for k in k0...k1 {
                    let pz = origin.z + Float(k) * cellSize
                    for j in j0...j1 {
                        let py = origin.y + Float(j) * cellSize
                        let row = (k * ny + j) * nx
                        for i in i0...i1 {
                            let p = SIMD3<Float>(origin.x + Float(i) * cellSize, py, pz)
                            let d = pointTriangleDistance(p, a, b, c)
                            if d < distance[row + i] { distance[row + i] = d }
                        }
                    }
                }
            }

            // Z-ray crossings: every lattice column whose (x, y) lies inside
            // the triangle's XY projection gets the intersection height.
            let den = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            guard abs(den) > 1e-12 else { continue }   // parallel to the ray
            let ci0 = max(Int(ceil((triMin.x - origin.x) / cellSize)), 0)
            let ci1 = min(Int(floor((triMax.x - origin.x) / cellSize)), nx - 1)
            let cj0 = max(Int(ceil((triMin.y - origin.y) / cellSize)), 0)
            let cj1 = min(Int(floor((triMax.y - origin.y) / cellSize)), ny - 1)
            guard ci0 <= ci1, cj0 <= cj1 else { continue }
            for j in cj0...cj1 {
                let py = origin.y + Float(j) * cellSize
                for i in ci0...ci1 {
                    let px = origin.x + Float(i) * cellSize
                    let u = ((px - a.x) * (c.y - a.y) - (c.x - a.x) * (py - a.y)) / den
                    let v = ((b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y)) / den
                    guard u >= 0, v >= 0, u + v <= 1 else { continue }
                    crossings[j * nx + i].append(a.z + u * (b.z - a.z) + v * (c.z - a.z))
                }
            }
        }

        // Walk each column once; parity of crossings below a voxel = inside.
        for j in 0..<ny {
            for i in 0..<nx {
                var zs = crossings[j * nx + i]
                guard !zs.isEmpty else { continue }
                zs.sort()
                var next = 0
                for k in 0..<nz {
                    let z = origin.z + Float(k) * cellSize
                    while next < zs.count && zs[next] < z { next += 1 }
                    if next % 2 == 1 {
                        let idx = (k * ny + j) * nx + i
                        distance[idx] = -distance[idx]
                    }
                }
            }
        }
        return distance
    }

    /// Distance from a point to a triangle (Ericson, *Real-Time Collision
    /// Detection* §5.1.5).
    private static func pointTriangleDistance(_ p: SIMD3<Float>, _ a: SIMD3<Float>,
                                              _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return simd_length(ap) }

        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return simd_length(bp) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return simd_length(ap - ab * v)
        }

        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return simd_length(cp) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return simd_length(ap - ac * w)
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length(bp - (c - b) * w)
        }

        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return simd_length(p - (a + ab * v + ac * w))
    }
}
