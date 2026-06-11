//
//  KeyframeSubjectFilter.swift
//  Magic Camera
//
//  Photo-mask isolation for point scans: lifts the subject silhouette from up
//  to three spread keyframe photos (Vision foreground segmentation) and keeps
//  only the cloud points that project inside every silhouette that sees them —
//  a coarse visual hull. Cuts floors, walls and surrounding clutter far more
//  reliably than geometry alone; the geometric segmenter then only has to
//  clean up what's left. Heavy (Vision per keyframe + a projection per point)
//  — run off the main thread.
//

import simd

enum KeyframeSubjectFilter {

    struct Result {
        let cloud: PointCloud
        let removedPoints: Int
        let viewsUsed: Int
    }

    /// Keep at most this many silhouettes — more adds little hull tightness.
    private static let maxViews = 3
    /// The filter must keep a believable subject: not almost nothing, and not
    /// almost everything (which would mean the masks saw "subject" everywhere).
    private static let minKeptPoints = 2_000
    private static let maxKeptFraction = 0.95

    /// Filters the cloud by the keyframes' subject silhouettes. Returns nil
    /// when there are no usable masks or the outcome looks implausible —
    /// callers then fall back to the unfiltered cloud.
    static func filter(_ cloud: PointCloud, keyframes: [ScanKeyframe]) -> Result? {
        guard cloud.count >= minKeptPoints, !keyframes.isEmpty else { return nil }

        // First / middle / last give the widest baseline the scan offers.
        let pickIndices = Set([0, keyframes.count / 2, keyframes.count - 1])
        var views: [(projection: ProjectionView, mask: SubjectMasker.MaskBitmap)] = []
        for index in pickIndices.sorted() {
            guard views.count < maxViews else { break }
            let keyframe = keyframes[index]
            guard let mask = SubjectMasker.maskBitmap(jpeg: keyframe.jpeg) else { continue }
            views.append((ProjectionView(keyframe), mask))
        }
        guard !views.isEmpty else { return nil }

        var kept = PointCloud()
        for i in 0..<cloud.count {
            let position = cloud.positions[i]
            var seen = false
            var inside = true
            for (projection, mask) in views {
                // Outside this view's frustum → it cannot vote on the point.
                guard let uv = projection.normalizedPoint(position) else { continue }
                seen = true
                if !mask.contains(normalizedX: uv.x, normalizedY: uv.y) {
                    inside = false
                    break
                }
            }
            if seen && inside {
                kept.append(position: position, color: cloud.colors[i],
                            confidence: cloud.confidences[i])
            }
        }

        guard kept.count >= minKeptPoints,
              Double(kept.count) < Double(cloud.count) * maxKeptFraction else { return nil }
        return Result(cloud: kept, removedPoints: cloud.count - kept.count,
                      viewsUsed: views.count)
    }

    // MARK: - Keyframe projection

    /// World → normalized keyframe image coordinates. Mirrors the projection
    /// in PhotoTextureBaker, minus the occlusion test: a silhouette is about
    /// image-space coverage, so points on the subject's far side must still
    /// count as inside.
    private struct ProjectionView {
        private let worldToCamera: simd_float4x4
        private let intrinsics: simd_float3x3
        private let width: Float
        private let height: Float

        init(_ keyframe: ScanKeyframe) {
            worldToCamera = keyframe.cameraTransform.inverse
            intrinsics = keyframe.intrinsics
            width = Float(keyframe.depthWidth)
            height = Float(keyframe.depthHeight)
        }

        func normalizedPoint(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let camera = worldToCamera * SIMD4<Float>(p, 1)
            let depth = -camera.z
            guard depth > 0.05 else { return nil }
            let u = camera.x / depth * intrinsics[0][0] + intrinsics[2][0]
            let v = -camera.y / depth * intrinsics[1][1] + intrinsics[2][1]
            guard u >= 0, v >= 0, u < width, v < height else { return nil }
            return SIMD2<Float>(u / width, v / height)
        }
    }
}
