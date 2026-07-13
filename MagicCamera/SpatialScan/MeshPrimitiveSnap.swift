//
//  MeshPrimitiveSnap.swift
//  Magic Camera
//
//  Recognises the SURFACES OF REVOLUTION an everyday object is turned from — the
//  huge family that covers pots, cups, cans, bottles, vases, bowls, lamp shades,
//  funnels, a teardrop diffuser — plus whole spheres (balls, globes, rounded
//  tops), and snaps the vertices that already agree with that shape exactly onto
//  its ideal, perfectly round profile. It is the curved-surface sibling of
//  `MeshPlanarRegularizer`: that one flattens the walls/floor of a room, this one
//  rounds the pot back into a clean turned shape instead of the lumpy barrel a
//  noisy marching-cubes surface bakes — the "škoda že to nedokáže poznávat common
//  tvary" wish.
//
//  Rather than a fixed menu of primitives, it fits ONE general model: an axis of
//  revolution plus a data-driven radial profile r(h) — the radius the surface has
//  at each height along the axis, read straight from the mesh (binned median). A
//  flat profile is a cylinder, a linear one a cone, an arc a bowl, an arbitrary
//  curve a vase or a teardrop; all fall out of the same fit, so an irregular
//  turned shape is handled as naturally as a can. A dedicated sphere fit runs
//  alongside it for round objects, whose vertical tangents at the poles an
//  axis-binned profile can't resolve.
//
//  Safety — and the answer to "what if part of it is something the fit doesn't
//  know" (a handle on a mug, a spout, an embossed logo, a lid): a vertex is only
//  snapped when it passes several tests — it lies within `tolerance` of the
//  profile, its normal has essentially no AZIMUTHAL component (a real turned
//  surface has none; a handle or a box face does, so it's rejected even at the
//  right radius) and a real RADIAL one (so a flat cap / disc / floor, normal
//  along the axis, is left alone), and — crucially — the accepted inliers must
//  wrap most of the way AROUND the axis. That azimuthal-coverage test is what
//  rejects a box (whose four face-centre strips otherwise mimic a cylinder) and a
//  half-captured curved wall: only a genuine body of revolution passes. The
//  profile median is built from those same axisymmetric points, so a handle can't
//  drag it; everything else is untouched, moves are clamped, and a shape with no
//  turned surface passes straight through. Safe to run unconditionally.
//
//  Raised DECORATION is kept, not flattened: an inlier is snapped onto the profile
//  plus the spatially-coherent part of its own radial deviation, so a mug's
//  fluting, a moulded crest or a band of relief survives while the incoherent
//  reconstruction crinkle and noise are removed (see `reliefSmoothingIterations`).
//
//  Pure value math, ARKit-free, off-main, deterministic. Reuses the planar
//  regulariser's size-scaled `adaptiveTolerance` and `SeededGenerator`.
//

import simd

enum MeshPrimitiveSnap {

    /// A fitted surface of revolution: an axis (point + unit direction), an
    /// in-plane basis for measuring azimuth, and the radial profile `r(h)` sampled
    /// in uniform height bins from `hmin`.
    struct RevolutionFit {
        var axis: SIMD3<Float>      // unit
        var center: SIMD3<Float>    // a point on the axis
        var hmin: Float
        var binWidth: Float
        var profile: [Float]        // radius per bin (gap-filled, no NaNs)

        /// Radius at height `h`. Linear interpolation between the two nearest bin
        /// centres, and — since the extreme rows of a cone/teardrop sit up to half
        /// a bin past the end bin's centre where the profile is steepest — a linear
        /// CONTINUATION past the ends rather than a flat clamp (which left the top
        /// and bottom rings a few mm proud).
        func radiusAt(_ h: Float) -> Float {
            let last = profile.count - 1
            guard last >= 1 else { return profile.first ?? 0 }
            let t = (h - hmin) / binWidth - 0.5
            if t <= 0 { return max(0.005, profile[0] + t * (profile[1] - profile[0])) }
            if t >= Float(last) {
                return max(0.005, profile[last] + (t - Float(last)) * (profile[last] - profile[last - 1]))
            }
            let i = Int(t.rounded(.down)); let frac = t - Float(i)
            return profile[i] * (1 - frac) + profile[i + 1] * frac
        }
    }

    struct Sphere { var center: SIMD3<Float>; var radius: Float }

    struct Stats {
        var revolutions = 0    // turned surfaces detected + snapped
        var spheres = 0        // whole spheres detected + snapped
        var snapped = 0        // vertices pulled onto one
        var total = 0          // welded vertex count considered
        var meanShiftMM: Float = 0
        var summary: String {
            "revolutions \(revolutions) · spheres \(spheres) · snapped \(snapped)/\(total)"
                + " · avg \(String(format: "%.1f", meanShiftMM))mm"
        }
    }

    /// Physically sane radius band — below 1 cm is noise, above 2 m is not an
    /// object we regularise (and a near-flat huge radius is a plane, already
    /// owned by the planar step).
    static let minRadius: Float = 0.01
    static let maxRadius: Float = 2.0
    /// Max distance a vertex may be pulled — a bad inlier can only nudge, never
    /// teleport (same guard as `MeshCloudSnap`).
    private static let maxShift: Float = 0.03
    /// A turned surface has NO azimuthal (around-the-axis) normal component; allow
    /// ~24° for LiDAR normal noise. Rejects a handle / spout / box face at radius.
    private static let azimuthGate: Float = 0.40
    /// …and it DOES have a radial component. Requiring one rejects a flat cap,
    /// disc or floor (normal along the axis) so it's never dragged into a ring.
    private static let minRadialNormal: Float = 0.30
    private static let minBinCount = 5      // points needed to trust a bin's median radius
    private static let minDefinedBins = 4   // a real revolution spans several heights, not one ring
    /// The inliers must wrap most of the way around the axis. 16 sectors, ≥60 %
    /// populated: a full turned object clears it, a box (4 strips) or a
    /// half-captured wall does not.
    private static let azimuthSectors = 16
    private static let minAzimuthCoverage: Float = 0.6
    /// Relief preservation: instead of snapping every inlier onto the bare
    /// profile (which flattens raised decoration a mug's fluting, a crest, a
    /// band of text just as it flattens noise), we snap onto the profile PLUS the
    /// spatially-coherent part of each inlier's radial residual. The residual is
    /// smoothed by an iterated 1-ring MEAN over the fitted shape's own inliers:
    /// an oscillatory reconstruction crinkle and random noise cancel toward zero
    /// (opposite-signed neighbours average out), while a SUSTAINED offset — real
    /// relief that agrees with its neighbours over a region — survives with only
    /// softened edges. Deliberately scoped to ONE fit's inliers, so a different
    /// object, scene clutter or bleed (never an inlier) can't be mistaken for this
    /// surface's decoration. A mean, not a median/bilateral: those preserve a
    /// directional zigzag, which is exactly the crinkle we must remove.
    private static let reliefSmoothingIterations = 5

    /// Detects up to `maxPrimitives` dominant turned surfaces / spheres and snaps
    /// each one's inliers onto its ideal profile. Returns the mesh (unchanged when
    /// nothing qualifies) and what was found.
    ///
    /// - up: world up — the primary axis candidate (most turned objects stand
    ///   upright); the subject's principal axes are tried too, so a bottle on its
    ///   side still registers.
    /// - tolerance: max radial distance (m) from the profile to snap; `nil`
    ///   derives it from the scan's size (shared `adaptiveTolerance`).
    /// - minInlierFraction: minimum share of welded vertices a shape must claim —
    ///   higher than the planar step's 0.04, since a spurious curved fit deforms
    ///   geometry.
    static func snap(_ input: MeshData,
                     up: SIMD3<Float> = SIMD3(0, 1, 0),
                     tolerance: Float? = nil,
                     minInlierFraction: Float = 0.12,
                     maxPrimitives: Int = 3)
        -> (mesh: MeshData, stats: Stats) {
        var stats = Stats()
        let mesh = input.weldingDuplicateVertices()
        let n = mesh.vertices.count
        stats.total = n
        guard n >= 300, mesh.indices.count >= 3, mesh.normals.count == n else {
            return (input, stats)
        }
        let tol = tolerance ?? MeshPlanarRegularizer.adaptiveTolerance(mesh.vertices)
        let minInliers = max(Int(Float(n) * minInlierFraction), 200)

        var verts = mesh.vertices
        let normals = mesh.normals
        var rng = SeededGenerator(seed: 0x2545_F491_4F6C_DD1D)
        var shiftSum: Float = 0
        // 1-ring adjacency for relief-preserving residual smoothing — built once,
        // lazily, only if something actually snaps (a room scan that finds no
        // turned surface never pays for it).
        var adjacency: [[Int32]]?

        // Fit each spatially-separated object about its OWN axis and centroid: a
        // room with two vases, or a lasso holding two subjects, no longer averages
        // their centres into a fit that matches neither. minInliers is taken per
        // CLUSTER, so a small object in a big scan still qualifies. Fully-connected
        // geometry (objects joined through a shared floor) stays one cluster — that
        // needs the planar background stripped first, a separate step.
        for cluster in spatialClusters(verts, cell: max(2 * tol, 0.05)) {
            let clusterMin = max(Int(Float(cluster.count) * minInlierFraction), 200)
            guard cluster.count >= clusterMin else { continue }
            var assigned = [Bool](repeating: false, count: n)   // only this cluster's members flip

            for _ in 0..<maxPrimitives {
                var pool: [Int] = []
                pool.reserveCapacity(cluster.count)
                for i in cluster where !assigned[i] { pool.append(i) }
                guard pool.count >= clusterMin else { break }

                // Best turned surface (over the axis candidates) and best whole
                // sphere; the one that explains more of the cluster this round wins.
                var bestRev: (fit: RevolutionFit, inliers: [Int])?
                for axis in candidateAxes(verts, pool: pool, up: up) {
                    guard let candidate = fitRevolution(verts, normals: normals, pool: pool,
                                                        axis: axis, tolerance: tol,
                                                        minInliers: clusterMin)
                    else { continue }
                    if bestRev == nil || candidate.inliers.count > bestRev!.inliers.count {
                        bestRev = candidate
                    }
                }
                let bestSph = bestSphere(verts, normals: normals, pool: pool,
                                         tolerance: tol, minInliers: clusterMin, rng: &rng)

                let revCount = bestRev?.inliers.count ?? 0
                let sphCount = bestSph?.inliers.count ?? 0
                if revCount == 0 && sphCount == 0 { break }

                if adjacency == nil {
                    adjacency = buildAdjacency(indices: mesh.indices, vertexCount: n)
                }
                let adj = adjacency!
                if revCount >= sphCount, let bestRev {
                    let moved = snapToRevolution(&verts, inliers: bestRev.inliers,
                                                 fit: bestRev.fit, adjacency: adj, shiftSum: &shiftSum)
                    guard moved > 0 else { break }
                    for i in bestRev.inliers { assigned[i] = true }
                    stats.revolutions += 1
                    stats.snapped += moved
                } else if let bestSph {
                    let moved = snapToSphere(&verts, inliers: bestSph.inliers,
                                             sphere: bestSph.sphere, adjacency: adj, shiftSum: &shiftSum)
                    guard moved > 0 else { break }
                    for i in bestSph.inliers { assigned[i] = true }
                    stats.spheres += 1
                    stats.snapped += moved
                } else {
                    break
                }
            }
        }

        guard stats.snapped > 0 else { return (input, stats) }
        stats.meanShiftMM = shiftSum / Float(stats.snapped) * 1000
        let outNormals = recomputeNormals(vertices: verts, indices: mesh.indices)
        return (MeshData(vertices: verts, normals: outNormals,
                         indices: mesh.indices, classifications: mesh.classifications),
                stats)
    }

    // MARK: - Surface-of-revolution fit

    /// Fits a surface of revolution about `axis` and returns it with its inliers,
    /// or nil if the mesh doesn't hold a real turned surface about this axis.
    static func fitRevolution(_ verts: [SIMD3<Float>], normals: [SIMD3<Float>],
                              pool: [Int], axis: SIMD3<Float>, tolerance: Float,
                              minInliers: Int) -> (fit: RevolutionFit, inliers: [Int])? {
        // The centroid lies on the axis of any surface of revolution.
        var center = SIMD3<Float>.zero
        for i in pool { center += verts[i] }
        center /= Float(pool.count)
        let (uAxis, wAxis) = orthonormalBasis(axis)   // for measuring azimuth

        var hmin = Float.greatestFiniteMagnitude, hmax = -Float.greatestFiniteMagnitude
        for i in pool {
            let h = simd_dot(verts[i] - center, axis)
            hmin = min(hmin, h); hmax = max(hmax, h)
        }
        let extent = hmax - hmin
        guard extent > max(4 * tolerance, 0.03) else { return nil }
        let numBins = min(64, max(minDefinedBins * 2, Int(extent / tolerance)))
        let binWidth = extent / Float(numBins)
        let minRho = max(tolerance * 0.5, 0.005)

        // Accumulate the radii of the AXISYMMETRIC points per height bin (normal
        // has a radial component and no azimuthal one). A handle / cap can't enter.
        var bins = [[Float]](repeating: [], count: numBins)
        for i in pool {
            let d = verts[i] - center
            let h = simd_dot(d, axis)
            let radialVec = d - axis * h
            let rho = simd_length(radialVec)
            guard rho > minRho else { continue }
            let rHat = radialVec / rho
            guard abs(simd_dot(normals[i], rHat)) >= minRadialNormal else { continue }
            let aziHat = simd_cross(axis, rHat)   // unit: axis ⟂ rHat, both unit
            guard abs(simd_dot(normals[i], aziHat)) <= azimuthGate else { continue }
            let b = min(numBins - 1, max(0, Int((h - hmin) / binWidth)))
            bins[b].append(rho)
        }

        var profile = [Float](repeating: .nan, count: numBins)
        var defined = 0
        for b in 0..<numBins where bins[b].count >= minBinCount {
            profile[b] = median(bins[b]); defined += 1
        }
        guard defined >= minDefinedBins else { return nil }
        let fit = RevolutionFit(axis: axis, center: center, hmin: hmin,
                                binWidth: binWidth, profile: fillGaps(profile))

        // Collect the vertices on the fitted profile (same gates) and track their
        // spread along and AROUND the axis.
        var inliers: [Int] = []
        var inHmin = Float.greatestFiniteMagnitude, inHmax = -Float.greatestFiniteMagnitude
        var sectorHit = [Bool](repeating: false, count: azimuthSectors)
        for i in pool {
            let d = verts[i] - center
            let h = simd_dot(d, axis)
            let radialVec = d - axis * h
            let rho = simd_length(radialVec)
            guard rho > minRho else { continue }
            let r = fit.radiusAt(h)
            guard r >= minRadius, r <= maxRadius, abs(rho - r) <= tolerance else { continue }
            let rHat = radialVec / rho
            guard abs(simd_dot(normals[i], rHat)) >= minRadialNormal else { continue }
            let aziHat = simd_cross(axis, rHat)
            guard abs(simd_dot(normals[i], aziHat)) <= azimuthGate else { continue }
            inliers.append(i)
            inHmin = min(inHmin, h); inHmax = max(inHmax, h)
            // Coverage is measured from the NORMAL's azimuth, not the point's: on a
            // real turned surface the normals sweep the whole circle, whereas a box
            // has only four fixed face directions — so a box's four face-centre
            // strips (which do span point-azimuth) collapse to four sectors here.
            let nRad = normals[i] - axis * simd_dot(normals[i], axis)
            let az = atan2f(simd_dot(nRad, wAxis), simd_dot(nRad, uAxis))  // −π…π
            let sector = min(azimuthSectors - 1,
                             max(0, Int((az + .pi) / (2 * .pi) * Float(azimuthSectors))))
            sectorHit[sector] = true
        }
        guard inliers.count >= minInliers else { return nil }
        // The inliers must span the axis (not one ring) AND wrap around it (not a
        // few strips of a box / a partial arc).
        guard inHmax - inHmin >= max(4 * binWidth, 0.03) else { return nil }
        let coverage = Float(sectorHit.filter { $0 }.count) / Float(azimuthSectors)
        guard coverage >= minAzimuthCoverage else { return nil }
        return (fit, inliers)
    }

    private static func snapToRevolution(_ verts: inout [SIMD3<Float>], inliers: [Int],
                                         fit: RevolutionFit, adjacency: [[Int32]],
                                         shiftSum: inout Float) -> Int {
        // Radial residual of each inlier against the bare profile, then keep only
        // its spatially-coherent part (see `reliefSmoothingIterations`): decoration
        // survives, crinkle + noise cancel.
        var residual = [Float](repeating: .nan, count: verts.count)
        for i in inliers {
            let d = verts[i] - fit.center
            let h = simd_dot(d, fit.axis)
            let rho = simd_length(d - fit.axis * h)
            residual[i] = rho - fit.radiusAt(h)
        }
        let keep = smoothResidual(residual, inliers: inliers, adjacency: adjacency)

        var moved = 0
        for i in inliers {
            let p = verts[i]
            let d = p - fit.center
            let h = simd_dot(d, fit.axis)
            let radialVec = d - fit.axis * h
            let rho = simd_length(radialVec)
            guard rho > 1e-5 else { continue }
            let targetRho = max(0.005, fit.radiusAt(h) + keep[i])
            let target = fit.center + fit.axis * h + radialVec * (targetRho / rho)
            let shift = simd_clamp(target - p, SIMD3(repeating: -maxShift), SIMD3(repeating: maxShift))
            let mag = simd_length(shift)
            guard mag > 1e-5 else { continue }
            verts[i] = p + shift; shiftSum += mag; moved += 1
        }
        return moved
    }

    // MARK: - Sphere fit (for the poles a height-binned profile can't resolve)

    /// Best sphere over `iterations` random 2-vertex-with-normals seeds — each
    /// outward normal points away from the centre, so two normal rays name the
    /// centre and radius directly. Scored against a strided subset like the planar
    /// RANSAC, then refit (Kåsa) to all inliers.
    private static func bestSphere(_ verts: [SIMD3<Float>], normals: [SIMD3<Float>],
                                   pool: [Int], tolerance: Float, minInliers: Int,
                                   rng: inout SeededGenerator,
                                   iterations: Int = 160) -> (sphere: Sphere, inliers: [Int])? {
        let m = pool.count
        guard m >= 2 else { return nil }
        let scoreCap = 20_000
        let stride = max(m / scoreCap, 1)
        let scored = stride == 1 ? pool : Swift.stride(from: 0, to: m, by: stride).map { pool[$0] }
        let minScored = Int(Float(minInliers) * Float(scored.count) / Float(m))

        var best: Sphere?
        var bestCount = minScored - 1
        for _ in 0..<iterations {
            let a = pool[Int(rng.next(upTo: UInt64(m)))]
            let b = pool[Int(rng.next(upTo: UInt64(m)))]
            guard a != b, let s = seedSphere(verts[a], normals[a], verts[b], normals[b]) else { continue }
            var count = 0
            for idx in scored where abs(simd_length(verts[idx] - s.center) - s.radius) <= tolerance { count += 1 }
            if count > bestCount { bestCount = count; best = s }
        }
        guard let best, let refined = refitSphere(verts, inliers: sphereInliers(
                verts, normals: normals, pool: pool, best, tolerance: tolerance)) else { return nil }
        let inliers = sphereInliers(verts, normals: normals, pool: pool, refined, tolerance: tolerance)
        guard inliers.count >= minInliers else { return nil }
        return (refined, inliers)
    }

    static func seedSphere(_ p0: SIMD3<Float>, _ n0: SIMD3<Float>,
                           _ p1: SIMD3<Float>, _ n1: SIMD3<Float>) -> Sphere? {
        let d0 = -n0, d1 = -n1, r = p0 - p1
        let b = simd_dot(d0, d1)
        let denom = 1 - b * b
        guard abs(denom) > 1e-5 else { return nil }
        let s = (b * simd_dot(d1, r) - simd_dot(d0, r)) / denom
        let t = (simd_dot(d1, r) - b * simd_dot(d0, r)) / denom
        let center = (p0 + d0 * s + p1 + d1 * t) * 0.5
        let radius = (simd_length(center - p0) + simd_length(center - p1)) * 0.5
        guard radius >= minRadius, radius <= maxRadius else { return nil }
        return Sphere(center: center, radius: radius)
    }

    private static func sphereInliers(_ verts: [SIMD3<Float>], normals: [SIMD3<Float>],
                                      pool: [Int], _ s: Sphere, tolerance: Float) -> [Int] {
        pool.filter { i in
            let d = verts[i] - s.center
            let dl = simd_length(d)
            guard abs(dl - s.radius) <= tolerance, dl > 1e-5 else { return false }
            return abs(simd_dot(normals[i], d / dl)) >= minRadialNormal
        }
    }

    /// Kåsa algebraic sphere fit: minimise Σ(x²+y²+z² + D·x+E·y+F·z+G)² over inliers.
    private static func refitSphere(_ verts: [SIMD3<Float>], inliers: [Int]) -> Sphere? {
        guard inliers.count >= 8 else { return nil }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var atb = [Double](repeating: 0, count: 4)
        for i in inliers {
            let p = verts[i]
            let x = Double(p.x), y = Double(p.y), z = Double(p.z)
            let row = [x, y, z, 1.0]; let rhs = -(x * x + y * y + z * z)
            for r in 0..<4 { for c in 0..<4 { ata[r][c] += row[r] * row[c] }; atb[r] += row[r] * rhs }
        }
        guard let sol = solve(ata, atb) else { return nil }
        let cx = -sol[0] / 2, cy = -sol[1] / 2, cz = -sol[2] / 2
        let r2 = cx * cx + cy * cy + cz * cz - sol[3]
        guard r2 > 0 else { return nil }
        let radius = Float(r2.squareRoot())
        guard radius >= minRadius, radius <= maxRadius else { return nil }
        return Sphere(center: SIMD3(Float(cx), Float(cy), Float(cz)), radius: radius)
    }

    private static func snapToSphere(_ verts: inout [SIMD3<Float>], inliers: [Int],
                                     sphere: Sphere, adjacency: [[Int32]],
                                     shiftSum: inout Float) -> Int {
        // Same relief preservation as the revolution snap: coherent bumps on a ball
        // (a relief globe, a moulded pattern) are kept; noise + crinkle cancel.
        var residual = [Float](repeating: .nan, count: verts.count)
        for i in inliers { residual[i] = simd_length(verts[i] - sphere.center) - sphere.radius }
        let keep = smoothResidual(residual, inliers: inliers, adjacency: adjacency)

        var moved = 0
        for i in inliers {
            let p = verts[i]
            let d = p - sphere.center
            let dl = simd_length(d)
            guard dl > 1e-5 else { continue }
            let target = sphere.center + d * (max(0.005, sphere.radius + keep[i]) / dl)
            let shift = simd_clamp(target - p, SIMD3(repeating: -maxShift), SIMD3(repeating: maxShift))
            let mag = simd_length(shift)
            guard mag > 1e-5 else { continue }
            verts[i] = p + shift; shiftSum += mag; moved += 1
        }
        return moved
    }

    /// Iterated 1-ring mean of a radial-residual field, restricted to the fit's
    /// own inliers (non-inliers are `NaN` and never contribute). Oscillatory
    /// crinkle and random noise average toward zero; a sustained offset (real
    /// relief) is preserved with softened edges.
    private static func smoothResidual(_ field: [Float], inliers: [Int],
                                       adjacency: [[Int32]]) -> [Float] {
        var cur = field
        for _ in 0..<reliefSmoothingIterations {
            var next = cur
            for i in inliers {
                var sum = cur[i], n: Float = 1
                for j in adjacency[i] {
                    let r = cur[Int(j)]
                    if !r.isNaN { sum += r; n += 1 }   // inlier neighbours only
                }
                next[i] = sum / n
            }
            cur = next
        }
        return cur
    }

    /// Groups vertices into spatially-connected clusters via a voxel grid
    /// (26-connectivity over occupied `cell`-sized cells) — each disjoint object
    /// becomes its own cluster so it can be fit about its own centre. One
    /// connected blob (or an empty cell size) returns a single cluster, i.e. the
    /// whole mesh, preserving the single-object behaviour exactly.
    private static func spatialClusters(_ verts: [SIMD3<Float>], cell: Float) -> [[Int]] {
        guard cell > 0, verts.count > 0 else { return [Array(0..<verts.count)] }
        let inv = 1 / cell
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x * inv).rounded(.down)),
                         Int32((p.y * inv).rounded(.down)),
                         Int32((p.z * inv).rounded(.down)))
        }
        var cells = [SIMD3<Int32>: [Int]](minimumCapacity: verts.count / 4)
        for i in 0..<verts.count { cells[key(verts[i]), default: []].append(i) }

        var visited = Set<SIMD3<Int32>>(minimumCapacity: cells.count)
        var clusters: [[Int]] = []
        for start in cells.keys where !visited.contains(start) {
            var stack = [start]; visited.insert(start)
            var members: [Int] = []
            while let k = stack.popLast() {
                members.append(contentsOf: cells[k] ?? [])
                for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    let nb = k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))
                    if cells[nb] != nil, !visited.contains(nb) { visited.insert(nb); stack.append(nb) }
                } } }
            }
            clusters.append(members)
        }
        return clusters
    }

    /// Undirected 1-ring adjacency from the triangle list. Shared edges appear
    /// more than once, which simply weights nearer neighbours a little more in the
    /// mean — harmless, and cheaper than de-duplicating.
    private static func buildAdjacency(indices: [UInt32], vertexCount: Int) -> [[Int32]] {
        var adjacency = [[Int32]](repeating: [], count: vertexCount)
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            adjacency[a].append(Int32(b)); adjacency[a].append(Int32(c))
            adjacency[b].append(Int32(a)); adjacency[b].append(Int32(c))
            adjacency[c].append(Int32(a)); adjacency[c].append(Int32(b))
            t += 3
        }
        return adjacency
    }

    // MARK: - Axis candidates

    /// World-up (upright turned objects) plus the pool's three principal axes (a
    /// lying / tilted object whose elongation is its axis).
    static func candidateAxes(_ verts: [SIMD3<Float>], pool: [Int],
                              up: SIMD3<Float>) -> [SIMD3<Float>] {
        var axes = [simd_normalize(up)]
        axes.append(contentsOf: principalAxes(verts, pool: pool))
        return axes
    }

    private static func principalAxes(_ verts: [SIMD3<Float>], pool: [Int]) -> [SIMD3<Float>] {
        guard pool.count >= 3 else { return [] }
        var centroid = SIMD3<Float>.zero
        for i in pool { centroid += verts[i] }
        centroid /= Float(pool.count)
        var c = simd_float3x3(0)
        for i in pool {
            let d = verts[i] - centroid
            c.columns.0 += d * d.x; c.columns.1 += d * d.y; c.columns.2 += d * d.z
        }
        let e1 = dominantEigenvector(c, seed: simd_normalize(SIMD3<Float>(1, 1, 1)))
        let l1 = simd_dot(e1, c * e1)
        var d = c
        d.columns.0 -= e1 * (l1 * e1.x); d.columns.1 -= e1 * (l1 * e1.y); d.columns.2 -= e1 * (l1 * e1.z)
        let e2 = dominantEigenvector(d, seed: simd_normalize(SIMD3<Float>(1, -1, 0.5)))
        let e3raw = simd_cross(e1, e2)
        let e3 = simd_length(e3raw) > 1e-6 ? simd_normalize(e3raw) : SIMD3<Float>(0, 1, 0)
        return [e1, e2, e3]
    }

    private static func dominantEigenvector(_ m: simd_float3x3, seed: SIMD3<Float>) -> SIMD3<Float> {
        var v = seed
        for _ in 0..<48 {
            let next = m * v
            let len = simd_length(next)
            if len < 1e-12 { return v }
            v = next / len
        }
        return v
    }

    // MARK: - Small helpers

    /// An orthonormal (u, w) spanning the plane perpendicular to unit `axis`.
    static func orthonormalBasis(_ axis: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let t: SIMD3<Float> = abs(axis.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(axis, t))
        return (u, simd_cross(axis, u))
    }

    private static func median(_ values: [Float]) -> Float {
        let s = values.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) * 0.5
    }

    /// Fills undefined (sparse) profile bins by linear interpolation between the
    /// nearest defined neighbours, extrapolating flat past the ends. Precondition:
    /// at least one bin is defined (the caller gates on `minDefinedBins`).
    private static func fillGaps(_ profile: [Float]) -> [Float] {
        var f = profile
        let defined = (0..<f.count).filter { !f[$0].isNaN }
        guard let first = defined.first, let last = defined.last else { return f }
        for i in 0..<first { f[i] = f[first] }
        for i in (last + 1)..<f.count { f[i] = f[last] }
        for k in 0..<(defined.count - 1) {
            let a = defined[k], b = defined[k + 1]
            guard b > a + 1 else { continue }
            for i in (a + 1)..<b {
                let ratio = Float(i - a) / Float(b - a)
                f[i] = f[a] * (1 - ratio) + f[b] * ratio
            }
        }
        return f
    }

    /// Gauss–Jordan solve of a small dense system (the 4×4 sphere normal
    /// equations), partial pivoting; nil when singular.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        let n = b.count
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            if pivot != col { m.swapAt(pivot, col); v.swapAt(pivot, col) }
            let diag = m[col][col]
            for r in 0..<n where r != col {
                let f = m[r][col] / diag
                if f == 0 { continue }
                for cc in col..<n { m[r][cc] -= f * m[col][cc] }
                v[r] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[i] = v[i] / m[i][i] }
        return x
    }

    private static func recomputeNormals(vertices: [SIMD3<Float>],
                                         indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let faceNormal = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            normals[a] += faceNormal; normals[b] += faceNormal; normals[c] += faceNormal
            i += 3
        }
        for v in 0..<normals.count {
            let length = simd_length(normals[v])
            normals[v] = length > 1e-6 ? normals[v] / length : SIMD3<Float>(0, 1, 0)
        }
        return normals
    }
}
