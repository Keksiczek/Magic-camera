//
//  ScanKeyframe.swift
//  Magic Camera
//
//  Keyframe capture for photo texturing: while a point scan runs, the recorder
//  keeps a small set of camera photos (JPEG) with their poses, intrinsics and
//  depth maps. PhotoTextureBaker later projects mesh texels into the
//  best-facing keyframe — far sharper textures than colours sampled from the
//  point cloud.
//
//  A new keyframe is taken when the camera moved/rotated enough since the last
//  one; the set is thinned (and the thresholds doubled) when it hits the cap,
//  so memory stays bounded on long scans.
//

import ARKit
import CoreImage
import simd

/// One captured view: photo + everything needed to reproject world points into it.
struct ScanKeyframe: Sendable {
    let jpeg: Data
    /// Camera-to-world at capture time.
    let cameraTransform: simd_float4x4
    /// Intrinsics scaled to depth-map pixel units (so projection lands in
    /// depth-map coordinates; multiply by the photo/depth scale for sampling).
    let intrinsics: simd_float3x3
    let depthWidth: Int
    let depthHeight: Int
    /// Row-major depth snapshot (`depthWidth × depthHeight`) for occlusion tests.
    let depth: [Float]
    /// Laplacian-variance focus score of the captured luma (higher = sharper).
    /// The bake favours the crisp keyframes with it. 1 = neutral (legacy keyframes
    /// with no stored score bake uniformly, exactly as before).
    var sharpness: Float = 1
}

extension PointCloudVisibilityFilter.DepthView {
    /// Geometry-only view of a keyframe (pose + depth-scaled intrinsics +
    /// depth snapshot; the JPEG stays behind) for the finish-time visibility
    /// trim.
    init(keyframe: ScanKeyframe) {
        let k = keyframe.intrinsics
        self.init(worldToCamera: keyframe.cameraTransform.inverse,
                  fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                  width: keyframe.depthWidth, height: keyframe.depthHeight,
                  depth: keyframe.depth)
    }
}

/// Collects keyframes on the scan recorder's serial queue (not thread-safe on
/// its own — ownership stays with ScanRecorder).
final class ScanKeyframeRecorder {
    /// 72 (was 48): a device room bake still had 15% of its triangles with no
    /// photo (`unseen 45994/310083`) from just 30 banked keyframes — the cap and
    /// thinning bit long sweeps well before the room was photographed. A keyframe
    /// is ~2-4 MB (JPEG ≤4096 px + 196 kB depth), so the ceiling moves ~100 MB →
    /// ~150-200 MB worst case, comfortable on the LiDAR (≥6 GB) devices this
    /// pipeline targets.
    static let maxKeyframes = 72

    private(set) var keyframes: [ScanKeyframe] = []
    private var lastTransform: simd_float4x4?
    // Capture keyframes more readily — a room scan that took only 3 keyframes left
    // the texture bake with almost no photo coverage (128 k texels fell back to
    // cloud). Denser keyframes cover more of the surface with real photos; the r30
    // sharpness scoring + sharper-of-pair thinning drop any softer ones, so casting
    // a wider net no longer risks baking blur. Tightened again after a 2.3 M-point
    // room banked only 18 keyframes (gate-limited, well under the cap): the photo
    // bake still fell back to noisy cloud colour on most walls (`repaired` high), so
    // the union of 18 photo cones simply didn't cover the room. A denser net + a
    // higher cap gives the walls real photo texture instead of per-point speckle.
    private var minTranslation: Float = 0.09
    private var minRotation: Float = .pi / 18   // ~10°
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // Steadiness gate: the previous processed frame, so the current angular
    // speed can be measured. A photo grabbed mid-sweep is motion-blurred and
    // makes a poor texture source — skip those even if the camera has moved far
    // enough since the last keyframe.
    private var previousFrameTransform: simd_float4x4?
    private var previousFrameTime: TimeInterval?
    /// Max inter-frame angular speed (rad/s ≈ 46°/s) tolerated for a keyframe.
    /// Raised from 34°/s: the old gate rejected too many frames on a normal room
    /// sweep (only 3 keyframes captured), and the r30 sharpness score now down-
    /// weights any residual motion blur in the bake, so a looser gate is safe.
    private let maxAngularSpeed: Float = 0.8

    func reset() {
        keyframes.removeAll(keepingCapacity: true)
        lastTransform = nil
        minTranslation = 0.09
        minRotation = .pi / 18
        previousFrameTransform = nil
        previousFrameTime = nil
    }

    /// Captures the frame as a keyframe when the camera moved enough since the
    /// last keyframe *and* is currently steady enough to avoid motion blur.
    /// Returns the captured keyframe's camera transform (a token for the hi-res
    /// upgrade) when one was taken.
    ///
    /// `poseCorrection` is the recorder's running ARKit→model registration
    /// (frame-to-model ICP): the stored pose must describe where the frame's
    /// *fused geometry* landed, or the bake would project photos from the
    /// uncorrected spot. Near-identity, so the movement/steadiness gates are
    /// unaffected by using the corrected pose throughout.
    @discardableResult
    func considerCapture(frame: ARFrame, poseCorrection: simd_float4x4? = nil) -> simd_float4x4? {
        let transform = poseCorrection.map { $0 * frame.camera.transform }
            ?? frame.camera.transform
        let time = frame.timestamp
        defer { previousFrameTransform = transform; previousFrameTime = time }
        if let previous = previousFrameTransform, let previousTime = previousFrameTime {
            let dt = Float(time - previousTime)
            if dt > 1e-4, rotationAngle(from: previous, to: transform) / dt > maxAngularSpeed {
                return nil   // sweeping too fast — would be blurred
            }
        }
        if let last = lastTransform, !movedEnough(from: last, to: transform) { return nil }
        guard let keyframe = makeKeyframe(frame: frame, pose: transform) else { return nil }
        lastTransform = transform
        keyframes.append(keyframe)
        thinIfNeeded()
        return transform
    }

    /// Swaps the keyframe captured at `token` for one built from the
    /// high-resolution still ARKit delivered moments later — the video stream is
    /// 1920×1440 and is what capped texture sharpness; the still is the sensor's
    /// photo resolution (12 MP+). Matching by the stored transform makes the
    /// upgrade safe against thinning (a thinned-away keyframe simply no longer
    /// matches); a still whose pose drifted past the keyframe gates is dropped
    /// (its sharper pixels would reproject from the wrong place). Long edge is
    /// capped at 4096 px so 24/48 MP sensors don't balloon memory.
    func upgradeKeyframe(token: simd_float4x4, with frame: ARFrame,
                         poseCorrection: simd_float4x4? = nil) {
        guard let index = keyframes.firstIndex(where: { $0.cameraTransform == token }) else { return }
        // Compare corrected-to-corrected: the token already carries the ICP
        // correction of its capture moment, so the still's pose must too.
        let pose = poseCorrection.map { $0 * frame.camera.transform }
            ?? frame.camera.transform
        let ta = SIMD3<Float>(token.columns.3.x, token.columns.3.y, token.columns.3.z)
        let tb = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        guard simd_distance(ta, tb) < 0.03,
              rotationAngle(from: token, to: pose) < 0.035 else { return }
        guard let upgraded = makeKeyframe(frame: frame, maxImageExtent: 4096,
                                          pose: pose) else { return }
        keyframes[index] = upgraded
    }

    // MARK: - Internals

    private func movedEnough(from a: simd_float4x4, to b: simd_float4x4) -> Bool {
        let ta = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let tb = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        if simd_distance(ta, tb) >= minTranslation { return true }
        return rotationAngle(from: a, to: b) >= minRotation
    }

    /// Rotation angle (radians) between two camera orientations.
    private func rotationAngle(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let ra = simd_quatf(simd_float3x3(columns: (
            SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
            SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
            SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))))
        let rb = simd_quatf(simd_float3x3(columns: (
            SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
            SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
            SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))))
        return (ra.inverse * rb).angle
    }

    /// `pose` overrides the stored camera transform (the ICP-corrected pose);
    /// intrinsics/depth still come from the frame itself.
    private func makeKeyframe(frame: ARFrame, maxImageExtent: CGFloat? = nil,
                              pose: simd_float4x4? = nil) -> ScanKeyframe? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)

        // Depth snapshot for occlusion testing.
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let rowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let ptr = base.assumingMemoryBound(to: Float32.self)
        var depth = [Float](repeating: 0, count: dw * dh)
        for v in 0..<dh {
            for u in 0..<dw {
                depth[v * dw + u] = ptr[v * rowStride + u]
            }
        }

        // JPEG of the camera image (sensor orientation — projection math matches).
        // Projection samples by depth-normalised coordinates, so the JPEG's pixel
        // size is transparent to the bakers — a hi-res still drops straight in.
        var image = CIImage(cvPixelBuffer: frame.capturedImage)
        if let maxImageExtent, image.extent.width > maxImageExtent {
            let scale = maxImageExtent / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let quality = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        // 0.90: keyframes are the texture's actual pixel source (both the GPU
        // baker's fixed slices and the CPU/exposure path read these JPEGs), so
        // ringing/blocking from compression shows up directly in the baked atlas.
        // The higher quality is a modest memory bump on the capped keyframe set
        // for a clearly sharper texture.
        guard let jpeg = ciContext.jpegRepresentation(
            of: image, colorSpace: colorSpace, options: [quality: 0.90]) else { return nil }

        let imageRes = frame.camera.imageResolution
        let intrinsics = DepthMath.scaledIntrinsics(
            frame.camera.intrinsics, imageWidth: Float(imageRes.width), depthWidth: Float(dw))
        // Focus score from the full-resolution luma (fixed-grid, so video and
        // upgraded high-res keyframes score on the same scale).
        let sharpness = KeyframeSharpness.measure(frame.capturedImage)
        return ScanKeyframe(jpeg: jpeg, cameraTransform: pose ?? frame.camera.transform,
                            intrinsics: intrinsics, depthWidth: dw, depthHeight: dh,
                            depth: depth, sharpness: sharpness)
    }

    /// At the cap: collapse each adjacent pair to its sharper keyframe and demand
    /// twice the movement for the next ones — halves the set (same broad coverage,
    /// bounded memory) while keeping the crisper photo of each nearby pair rather
    /// than a blind every-other cull.
    private func thinIfNeeded() {
        guard keyframes.count >= Self.maxKeyframes else { return }
        var kept: [ScanKeyframe] = []
        kept.reserveCapacity(keyframes.count / 2 + 1)
        var i = 0
        while i < keyframes.count {
            if i + 1 < keyframes.count {
                kept.append(keyframes[i].sharpness >= keyframes[i + 1].sharpness
                            ? keyframes[i] : keyframes[i + 1])
                i += 2
            } else {
                kept.append(keyframes[i])
                i += 1
            }
        }
        keyframes = kept
        // ×1.5 (was ×2): doubling made the second half of a long room sweep
        // bank keyframes at 4× the spacing of the first half — visibly patchier
        // photo texture wherever the user finished the sweep. Gentler growth
        // still converges (each thinning halves the set), it just keeps late
        // coverage closer to early coverage.
        minTranslation *= 1.5
        minRotation = min(minRotation * 1.5, .pi / 2)
    }
}
