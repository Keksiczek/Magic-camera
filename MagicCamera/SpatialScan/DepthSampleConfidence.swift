//
//  DepthSampleConfidence.swift
//  Magic Camera
//
//  How much do we believe one depth sample?
//
//  Until now a sample's confidence was ARKit's three-level `confidenceMap`
//  (low/medium/high → 0 / 0.5 / 1) and nothing else, and every other quality
//  signal was a *hard gate*: a depth jump over `edgeThreshold` dropped the texel,
//  a fast pose delta dropped the whole frame. Binary gates have to be set loose
//  enough not to hole real geometry, and everything under the bar then enters at
//  FULL confidence — which is exactly how "bleed" (flying pixels smeared across a
//  silhouette, points hanging in free space) gets in with the same standing as a
//  wall seen twenty times.
//
//  This grades instead of gating. Each sample gets a multiplicative reliability
//  score in 0…1 from several independent signals; the score multiplies ARKit's
//  level to produce the confidence the point carries. Downstream that number is
//  already load-bearing:
//    · `ScanRecorder.fuse` uses it as the TSDF weight, so a doubtful sample barely
//      moves the running mean and a confirmed surface converges on the good value;
//    · `ReconstructionPipeline.dropLowConfidence` drops what never earned belief.
//  So a point only survives if *something* eventually vouches for it.
//
//  The design rule that keeps this safe: **no single signal may reject a sample.**
//  Each one only lowers the grade toward its own floor; a sample is dropped solely
//  when the PRODUCT falls under `minGrade`, i.e. when several independent signals
//  agree it is bad. That is the signature of bleed (a depth cliff seen edge-on,
//  far away, while sweeping) and not of an honest-but-awkward measurement (a real
//  wall at a grazing angle, which keeps ~0.15 and recovers the moment it is seen
//  from anywhere better).
//
//  These constants are the single source of truth: the CPU fallback calls this
//  type directly, and the GPU kernel receives the same numbers through
//  `SampleGrading` in the uniforms rather than duplicating them in Metal.
//

import simd

enum DepthSampleConfidence {

    // MARK: - Tunables

    /// Depth-jump ratio (relative to the reject threshold) below which a sample
    /// is considered clear of any silhouette.
    static let edgeKnee: Float = 0.35
    /// Grade for a sample sitting right at the depth-jump reject threshold.
    static let edgeFloor: Float = 0.28

    /// cos of the incidence angle at/below which the incidence floor applies
    /// (0.15 ≈ 81° off the surface normal — a LiDAR return that grazes).
    static let grazingCos: Float = 0.15
    /// cos at/above which incidence costs nothing (0.50 = 60°).
    static let trustedCos: Float = 0.50
    static let incidenceFloor: Float = 0.15

    /// Range (m) within which depth noise is negligible.
    static let trustedRange: Float = 1.5
    /// Grade at `maxDepth`. Deliberately shallow — distance makes a sample
    /// noisier, not false.
    static let rangeFloor: Float = 0.75

    /// Normalised radius (0 = principal point, 1 = frame corner) within which
    /// the sensor's dot pattern is dense.
    static let trustedRadius: Float = 0.65
    static let radialFloor: Float = 0.85

    /// Pose-rate (rad/s, m/s) below which the frame is steady enough to trust.
    static let steadyAngularSpeed: Float = 0.35
    static let steadyLinearSpeed: Float = 0.20
    /// Pose-rate at which the motion floor applies.
    static let blurredAngularSpeed: Float = 1.20
    static let blurredLinearSpeed: Float = 0.60
    static let motionFloor: Float = 0.50

    /// Reject only when the product of every signal falls below this. With the
    /// floors above, one bad signal can never get here on its own: the lowest a
    /// single-signal sample reaches is `incidenceFloor` = 0.15.
    static let minGrade: Float = 0.10

    /// Confidence at/below which a fused point is treated as never-confirmed.
    /// Mirrors `ReconstructionPipeline.dropLowConfidence`, and is what the
    /// capture diagnostics report against.
    static let lowConfidenceMark: Float = 0.25

    // MARK: - Factors

    /// Linear ramp: `floor` at `t <= 0`, 1 at `t >= 1`.
    static func ramp(_ t: Float, floor: Float) -> Float {
        floor + (1 - floor) * min(max(t, 0), 1)
    }

    /// `relativeJump` is the largest neighbour depth jump expressed as a fraction
    /// of the reject threshold: 0 = flat, 1 = right at the bar. Only meaningful
    /// where a threshold is configured; callers pass 0 when it is disabled.
    static func edgeFactor(relativeJump: Float) -> Float {
        guard relativeJump > edgeKnee else { return 1 }
        return ramp((1 - relativeJump) / (1 - edgeKnee), floor: edgeFloor)
    }

    /// `cosIncidence` = |n̂ · r̂| between the local surface normal (estimated from
    /// the depth map) and the view ray. A flying pixel bridging a depth cliff has
    /// a normal nearly perpendicular to the ray, so this is the signal that sees
    /// bleed the binary edge test lets past — and it works even where no edge
    /// threshold is configured at all.
    static func incidenceFactor(cosIncidence: Float) -> Float {
        let c = min(max(cosIncidence, 0), 1)
        guard c < trustedCos else { return 1 }
        return ramp((c - grazingCos) / (trustedCos - grazingCos), floor: incidenceFloor)
    }

    /// LiDAR depth error grows with range; a 6 m wall sample is honest but coarse.
    static func rangeFactor(depth: Float, maxDepth: Float) -> Float {
        guard depth > trustedRange, maxDepth > trustedRange else { return 1 }
        return ramp((maxDepth - depth) / (maxDepth - trustedRange), floor: rangeFloor)
    }

    /// The dot pattern stretches toward the frame edge. Mild by design.
    static func radialFactor(normalizedRadius: Float) -> Float {
        guard normalizedRadius > trustedRadius else { return 1 }
        return ramp((1 - normalizedRadius) / (1 - trustedRadius), floor: radialFloor)
    }

    /// Per-frame, not per-sample: hand-shake motion-blurs the depth map into
    /// flying pixels. Object mode already *drops* frames over a hard bar; this
    /// grades every preset's frames below that bar too.
    static func motionFactor(angularSpeed: Float, linearSpeed: Float) -> Float {
        let angular = ramp((blurredAngularSpeed - angularSpeed)
                           / (blurredAngularSpeed - steadyAngularSpeed), floor: motionFloor)
        let linear = ramp((blurredLinearSpeed - linearSpeed)
                          / (blurredLinearSpeed - steadyLinearSpeed), floor: motionFloor)
        return min(angular, linear)
    }

    // MARK: - Combined

    /// The product of every signal. `frameGrade` is `motionFactor` for the frame.
    ///
    /// `frameGrade` is clamped to `motionFloor`, not to 0. The other four factors
    /// each enforce their own non-zero floor inside their own function, which is
    /// what makes the "no single signal may reject a sample" invariant structural.
    /// This one arrived pre-computed from the caller and was clamped `max(·, 0)`,
    /// so a 0 — a future caller, a lowered `motionFloor`, an uninitialised field —
    /// would collapse the product to 0 no matter how perfect the other four were.
    /// That is a single signal rejecting alone. It is unreachable today (the sole
    /// producer, `motionFactor`, already floors at `motionFloor`) but the
    /// invariant should not depend on a caller remembering.
    static func grade(relativeJump: Float, cosIncidence: Float,
                      depth: Float, maxDepth: Float,
                      normalizedRadius: Float, frameGrade: Float) -> Float {
        edgeFactor(relativeJump: relativeJump)
            * incidenceFactor(cosIncidence: cosIncidence)
            * rangeFactor(depth: depth, maxDepth: maxDepth)
            * radialFactor(normalizedRadius: normalizedRadius)
            * min(max(frameGrade, motionFloor), 1)
    }

    static func isRejected(grade: Float) -> Bool { grade < minGrade }

    // MARK: - Depth-map geometry

    /// Camera-space point for a depth texel (image convention: +x right, +y down,
    /// +z forward → ARKit's camera axes). Mirrors the unprojection in the kernel
    /// and `DepthMath.cameraLocalPoint`.
    static func cameraPoint(u: Float, v: Float, depth: Float,
                            fx: Float, fy: Float, cx: Float, cy: Float) -> SIMD3<Float> {
        SIMD3<Float>((u + 0.5 - cx) / max(fx, 1e-3) * depth,
                     -(v + 0.5 - cy) / max(fy, 1e-3) * depth,
                     -depth)
    }

    /// |n̂ · r̂| from four depth neighbours, using whichever side of each axis has
    /// a valid sample. Returns 1 (no penalty) when an axis has no usable
    /// neighbour — a missing measurement is not evidence of a bad one.
    ///
    /// `left`/`right`/`up`/`down` are neighbour depths; a value ≤ 0 means absent.
    static func cosIncidence(depth: Float, u: Float, v: Float,
                             left: Float, right: Float, up: Float, down: Float,
                             fx: Float, fy: Float, cx: Float, cy: Float) -> Float {
        let center = cameraPoint(u: u, v: v, depth: depth, fx: fx, fy: fy, cx: cx, cy: cy)

        func tangent(_ negative: Float, _ positive: Float,
                     _ du: Float, _ dv: Float) -> SIMD3<Float>? {
            let hasNegative = negative > 0 && negative.isFinite
            let hasPositive = positive > 0 && positive.isFinite
            if hasNegative && hasPositive {
                let a = cameraPoint(u: u - du, v: v - dv, depth: negative,
                                    fx: fx, fy: fy, cx: cx, cy: cy)
                let b = cameraPoint(u: u + du, v: v + dv, depth: positive,
                                    fx: fx, fy: fy, cx: cx, cy: cy)
                return b - a
            }
            if hasPositive {
                return cameraPoint(u: u + du, v: v + dv, depth: positive,
                                   fx: fx, fy: fy, cx: cx, cy: cy) - center
            }
            if hasNegative {
                return center - cameraPoint(u: u - du, v: v - dv, depth: negative,
                                            fx: fx, fy: fy, cx: cx, cy: cy)
            }
            return nil
        }

        guard let alongX = tangent(left, right, 1, 0),
              let alongY = tangent(up, down, 0, 1) else { return 1 }
        let normal = simd_cross(alongX, alongY)
        let normalLength = simd_length(normal)
        let rayLength = simd_length(center)
        guard normalLength > 1e-9, rayLength > 1e-9 else { return 1 }
        return abs(simd_dot(normal / normalLength, center / rayLength))
    }

    /// Largest neighbour depth jump as a fraction of the reject threshold, over
    /// the same three rings the kernel tests (ring r is allowed r× the jump).
    /// Returns 0 when grading has no threshold to measure against.
    ///
    /// Byte-for-byte the kernel's rule, including the part that looks like an
    /// oversight: a neighbour of 0 (no depth returned there) counts as a full-size
    /// jump rather than being skipped. That is what `unprojectKernel` does, and
    /// the kernel is what runs on every LiDAR device — so it is the behaviour this
    /// function has to mirror to be a source of truth rather than a second
    /// opinion. It means a texel bordering a depth hole is treated as a silhouette
    /// and dropped, which is defensible (holes and silhouettes co-occur) but does
    /// erode the rim around every dark or glossy patch.
    ///
    /// Whether that rim erosion is wanted is a real open question — but changing
    /// it changes what the capture keeps, so it belongs in a device round of its
    /// own, not smuggled in under a refactor. This function previously skipped
    /// invalid neighbours and was never called from production, so the divergence
    /// cost nothing; now that the CPU fallback routes through it, matching the
    /// kernel is the only safe reading.
    static func relativeJump(depth: Float, threshold: Float,
                             ring1: [Float], ring2: [Float], ring3: [Float]) -> Float {
        guard threshold > 0, depth > 0 else { return 0 }
        let maxJump = threshold * depth
        var worst: Float = 0
        for (ring, scale) in [(ring1, Float(1)), (ring2, Float(2)), (ring3, Float(3))] {
            for neighbour in ring where neighbour.isFinite {
                worst = max(worst, abs(neighbour - depth) / (scale * maxJump))
            }
        }
        return worst
    }

    // MARK: - GPU hand-off

    /// Packs the constants above into the uniform the kernel reads, so Metal
    /// never hard-codes a second copy of them.
    ///
    /// `frameGrade` is floored at `motionFloor` HERE rather than in the kernel, so
    /// the shader's `saturate()` becomes a no-op and both paths honour the "no
    /// single signal may reject a sample" invariant without the uniform having to
    /// carry a twelfth constant. See `grade(…)` for why the floor matters.
    static func gpuGrading(enabled: Bool, frameGrade: Float) -> SampleGrading {
        SampleGrading(enabled: enabled ? 1 : 0,
                      edgeKnee: edgeKnee,
                      edgeFloor: edgeFloor,
                      grazingCos: grazingCos,
                      trustedCos: trustedCos,
                      incidenceFloor: incidenceFloor,
                      trustedRange: trustedRange,
                      rangeFloor: rangeFloor,
                      trustedRadius: trustedRadius,
                      radialFloor: radialFloor,
                      frameGrade: min(max(frameGrade, motionFloor), 1),
                      minGrade: minGrade)
    }
}
