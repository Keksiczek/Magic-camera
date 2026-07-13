//
//  PointCloudVisibilityFilter.swift
//  Magic Camera
//
//  Finish-time bleed removal by multi-view visibility consensus. Silhouette
//  "flying pixels" fuse into points floating in free space between a subject's
//  edge and its background; per-cell observation counts can't separate them
//  from real surface because they are dwell-confounded (standing still re-fuses
//  the same bleed every frame). Keyframes are the dwell-independent observation
//  set — they only bank when the camera has MOVED (9 cm / 10° gate) and each
//  carries its own depth map — so they provide exactly the parallax evidence
//  needed: a point some keyframe saw *through* (its depth there lands clearly
//  BEHIND the point) is provably in free space; a point hidden behind closer
//  geometry yields no evidence and is kept, so occluded real surface survives.
//  The one physically undecidable case — bleed observed from a single spot and
//  never revisited — is kept too (no parallax, no verdict, same as a human).
//
//  Pure value math (simd + Dispatch only): unit-testable off-device.
//

import Foundation
import simd

enum PointCloudVisibilityFilter {

    /// One keyframe's geometry: pose, depth-map-scaled intrinsics and the
    /// depth snapshot itself. Mirrors PhotoTextureBaker.View's (proven)
    /// projection convention: depth = −z in camera space, v axis flipped,
    /// row-major depth indexed `[v * width + u]`.
    struct DepthView {
        let worldToCamera: simd_float4x4
        let fx: Float, fy: Float, cx: Float, cy: Float
        let width: Int, height: Int
        let depth: [Float]
    }

    /// Verdict thresholds. A view SUPPORTS a point when its stored depth at
    /// the projected pixel matches the point's depth within `supportTolerance`
    /// (fusion averaging, snapping and mm-scale registration all move points a
    /// little); it CONTRADICTS when the stored depth lands clearly behind
    /// (`contradictionSlack`) — the sensor saw through the point's position to
    /// a farther surface. Between the two bands there is deliberately no
    /// verdict, and a stored depth in FRONT of the point is occlusion — also
    /// no verdict.
    @inline(__always) private static func supportTolerance(_ depth: Float) -> Float {
        max(0.03, depth * 0.02)
    }
    @inline(__always) private static func contradictionSlack(_ depth: Float) -> Float {
        max(0.07, depth * 0.04)
    }

    /// A point is dropped only on strong evidence: at least `minContradictions`
    /// clean see-throughs AND at least `supportOutvoteRatio`× more of them
    /// than supports. The ratio (not an absolute support cap) matters because
    /// captured bleed always has SOME supporters — the very keyframes whose
    /// depth maps carried the flying pixels that fused it (a shaker's bleed
    /// wing survived a `supports ≤ 1` rule with exactly those self-votes).
    /// Real surface accumulates supports from every side, so the ratio never
    /// reaches it; bleed's supporters are capped by the artifact's narrow
    /// origin while clean views keep contradicting from everywhere else.
    static let minContradictions = 3
    static let supportOutvoteRatio = 2
    /// Fewer pose-diverse views than this can't form a consensus — the filter
    /// becomes a no-op instead of guessing on thin evidence.
    static let minViews = 6

    /// Keep/drop mask for `positions` under the views' visibility consensus.
    static func keepMask(positions: [SIMD3<Float>], views: [DepthView]) -> [Bool] {
        guard views.count >= minViews, !positions.isEmpty else {
            return [Bool](repeating: true, count: positions.count)
        }
        var keep = [Bool](repeating: true, count: positions.count)
        // Chunked parallel sweep; each point is independent and the mask
        // slots are disjoint per iteration.
        let chunk = 4_096
        let chunks = (positions.count + chunk - 1) / chunk
        keep.withUnsafeMutableBufferPointer { mask in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * chunk
                let hi = min(lo + chunk, positions.count)
                for i in lo..<hi where !isVisible(positions[i], views: views) {
                    mask[i] = false
                }
            }
        }
        return keep
    }

    /// True when the point survives the consensus (kept), false when enough
    /// views saw through it.
    private static func isVisible(_ p: SIMD3<Float>, views: [DepthView]) -> Bool {
        var supports = 0
        var contradictions = 0
        for (visited, view) in views.enumerated() {
            // Early keep: dropping needs `minContradictions` clean see-throughs
            // AND `ratio × supports` of them; once the views left can no longer
            // reach either bar (supports only ever raise it), the verdict is
            // settled — real surface exits after a handful of views.
            let remaining = views.count - visited
            if contradictions + remaining < minContradictions
                || contradictions + remaining < supportOutvoteRatio * supports {
                return true
            }
            let pc = view.worldToCamera * SIMD4<Float>(p, 1)
            let depth = -pc.z
            guard depth > 0.05 else { continue }
            let u = pc.x / depth * view.fx + view.cx
            let v = -pc.y / depth * view.fy + view.cy
            // One-texel ring stays inside bounds for the ring scan below.
            guard u >= 1, v >= 1,
                  u < Float(view.width - 1), v < Float(view.height - 1) else { continue }
            let ui = Int(u), vi = Int(v)
            let stored = view.depth[vi * view.width + ui]
            guard stored > 0, stored.isFinite else { continue }
            let tolerance = supportTolerance(depth)
            if abs(stored - depth) <= tolerance {
                supports += 1
                continue
            }
            guard stored > depth + contradictionSlack(depth) else { continue }
            // Candidate see-through — the verdict comes from the 3×3 ring:
            //  · any neighbouring texel agreeing with the point RESCUES it
            //    into a support: thin structure (a wicker strand, a stem) is
            //    narrower than a depth texel, so the centre often reads the
            //    background BESIDE it — the ray-through-gap quantisation that
            //    once shredded the chair via consensus carving;
            //  · a contradiction only counts when the whole ring lands behind
            //    the point (genuinely open space along the whole beam), so a
            //    silhouette grazing this view yields no verdict instead of a
            //    false see-through.
            var rescued = false
            var cleanBehind = true
            var validNeighbors = 0
            let slack = contradictionSlack(depth)
            for dv in -1...1 {
                for du in -1...1 where dv != 0 || du != 0 {
                    let neighbor = view.depth[(vi + dv) * view.width + (ui + du)]
                    guard neighbor > 0, neighbor.isFinite else { continue }
                    validNeighbors += 1
                    if abs(neighbor - depth) <= tolerance {
                        rescued = true
                        break
                    }
                    if neighbor <= depth + slack { cleanBehind = false }
                }
                if rescued { break }
            }
            if rescued {
                supports += 1
            } else if cleanBehind, validNeighbors >= 4 {
                contradictions += 1
            }
        }
        return !(contradictions >= minContradictions
                 && contradictions >= supportOutvoteRatio * supports)
    }

    /// Convenience: filters a cloud (and its index-aligned view directions)
    /// down to the visible consensus. Directions pass through untouched when
    /// they aren't aligned (callers already treat that as "no directions").
    static func trim(_ cloud: PointCloud, viewDirections: [SIMD3<Float>],
                     views: [DepthView])
        -> (cloud: PointCloud, viewDirections: [SIMD3<Float>], removed: Int) {
        guard views.count >= minViews, !cloud.isEmpty else {
            return (cloud, viewDirections, 0)
        }
        let keep = keepMask(positions: cloud.positions, views: views)
        var removed = 0
        for kept in keep where !kept { removed += 1 }
        guard removed > 0 else { return (cloud, viewDirections, 0) }
        let aligned = viewDirections.count == cloud.count
        var filtered = PointCloud()
        filtered.reserveCapacity(cloud.count - removed)
        var directions: [SIMD3<Float>] = []
        if aligned { directions.reserveCapacity(cloud.count - removed) }
        for i in 0..<cloud.count where keep[i] {
            filtered.append(position: cloud.positions[i],
                            color: cloud.colors[i],
                            confidence: cloud.confidences[i])
            if aligned { directions.append(viewDirections[i]) }
        }
        return (filtered, aligned ? directions : viewDirections, removed)
    }
}
