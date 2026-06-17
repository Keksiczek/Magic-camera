//
//  SurfaceMask.swift
//  Magic Camera
//
//  Cleans a raw LiDAR point cloud using ARKit's own scene mesh, captured in the
//  same gravity-aligned world space during an Object scan.
//
//  Why this exists: the custom point pipeline keeps every depth sample, so a
//  subject's silhouette carries "flying pixels" — points smeared into empty
//  space between the subject and its background. ARKit's scene reconstruction
//  regularises its mesh and simply never places geometry on those floaters, so
//  the mesh is a ready-made occupancy oracle. Keeping only cloud points that lie
//  near a real ARKit surface strips the bleed that the geometric isolation
//  (plane removal + clustering) leaves behind, because those floaters sit right
//  at the subject's edge and survive clustering.
//
//  Pure value math — ARKit-free at the type level, off-main-thread friendly and
//  unit-testable.
//

import simd

enum SurfaceMask {
    /// A sensible masking tolerance for a cloud: ~2× its mean point spacing, but
    /// never below 2 cm (ARKit's mesh is coarser than a dense close-up cloud, so
    /// too tight a tolerance would hole legitimate detail).
    static func tolerance(for cloud: PointCloud) -> Float {
        let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
        return max(spacing * 2, 0.02)
    }

    /// Keeps only the cloud points lying within ~2·`tolerance` (Chebyshev) of a
    /// reference surface's vertices. Returns `nil` — so the caller keeps the raw
    /// cloud — when the surface is empty or the mask would gut the cloud (a sign
    /// the mesh is too sparse or misaligned to trust).
    static func maskToSurface(_ cloud: PointCloud, surface: MeshData,
                              tolerance: Float) -> PointCloud? {
        guard cloud.count > 0, !surface.vertices.isEmpty, tolerance > 0 else { return nil }
        let cell = tolerance

        @inline(__always) func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }

        var occupied = Set<SIMD3<Int32>>()
        occupied.reserveCapacity(surface.vertices.count)
        for v in surface.vertices { occupied.insert(key(v)) }

        var out = PointCloud()
        out.reserveCapacity(cloud.count)
        for i in 0..<cloud.count {
            let k = key(cloud.positions[i])
            var near = false
            search: for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 where occupied.contains(k &+ SIMD3<Int32>(dx, dy, dz)) {
                        near = true
                        break search
                    }
                }
            }
            if near {
                out.append(position: cloud.positions[i], color: cloud.colors[i],
                           confidence: cloud.confidences[i])
            }
        }
        // Misaligned / too-sparse mesh: bail rather than return a gutted cloud.
        guard out.count >= max(50, cloud.count / 20) else { return nil }
        return out
    }

    /// The floor height (world Y; scans are gravity-aligned) inferred from a
    /// classified ARKit scene mesh — the median Y of its floor-classified
    /// vertices. `nil` when the mesh carries no classification or too little
    /// floor to be reliable.
    static func floorLevel(of surface: MeshData, minVertices: Int = 40) -> Float? {
        guard surface.hasClassification else { return nil }
        let floorRaw = MeshClassification.floor.rawValue
        var ys: [Float] = []
        for i in 0..<surface.vertices.count where surface.classifications[i] == floorRaw {
            ys.append(surface.vertices[i].y)
        }
        guard ys.count >= minVertices else { return nil }
        ys.sort()
        return ys[ys.count / 2]
    }

    /// Drops every point at or below `y + tolerance` — used to lift a subject off
    /// a detected floor without holing its lowest real geometry.
    static func croppingAbove(_ cloud: PointCloud, floorY y: Float,
                              tolerance: Float = 0.02) -> PointCloud {
        let cutoff = y + tolerance
        var out = PointCloud()
        out.reserveCapacity(cloud.count)
        for i in 0..<cloud.count where cloud.positions[i].y > cutoff {
            out.append(position: cloud.positions[i], color: cloud.colors[i],
                       confidence: cloud.confidences[i])
        }
        return out
    }

    /// One-call cleanup with a captured ARKit scene mesh: mask the cloud to the
    /// real surface (drop silhouette floaters), then crop the classified floor.
    /// Each step keeps the input when it would gut the cloud, and the whole thing
    /// is a no-op when no usable scene mesh was captured (room/area scans, or
    /// hardware without scene reconstruction) — so callers can apply it blindly.
    static func cleaned(_ cloud: PointCloud, using surface: MeshData?) -> PointCloud {
        guard let surface, !surface.isEmpty else { return cloud }
        var working = maskToSurface(cloud, surface: surface,
                                    tolerance: tolerance(for: cloud)) ?? cloud
        if let floorY = floorLevel(of: surface) {
            let cropped = croppingAbove(working, floorY: floorY)
            if cropped.count >= max(50, working.count / 20) { working = cropped }
        }
        return working
    }
}
