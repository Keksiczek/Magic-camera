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
}

/// Collects keyframes on the scan recorder's serial queue (not thread-safe on
/// its own — ownership stays with ScanRecorder).
final class ScanKeyframeRecorder {
    static let maxKeyframes = 32

    private(set) var keyframes: [ScanKeyframe] = []
    private var lastTransform: simd_float4x4?
    private var minTranslation: Float = 0.18
    private var minRotation: Float = .pi / 10   // 18°
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // Steadiness gate: the previous processed frame, so the current angular
    // speed can be measured. A photo grabbed mid-sweep is motion-blurred and
    // makes a poor texture source — skip those even if the camera has moved far
    // enough since the last keyframe.
    private var previousFrameTransform: simd_float4x4?
    private var previousFrameTime: TimeInterval?
    /// Max inter-frame angular speed (rad/s ≈ 34°/s) tolerated for a keyframe.
    /// Generous: careful scanning sits well below it, only fast pans are cut.
    private let maxAngularSpeed: Float = 0.6

    func reset() {
        keyframes.removeAll(keepingCapacity: true)
        lastTransform = nil
        minTranslation = 0.18
        minRotation = .pi / 10
        previousFrameTransform = nil
        previousFrameTime = nil
    }

    /// Captures the frame as a keyframe when the camera moved enough since the
    /// last keyframe *and* is currently steady enough to avoid motion blur.
    /// Returns the captured keyframe's camera transform (a token for the hi-res
    /// upgrade) when one was taken.
    @discardableResult
    func considerCapture(frame: ARFrame) -> simd_float4x4? {
        let transform = frame.camera.transform
        let time = frame.timestamp
        defer { previousFrameTransform = transform; previousFrameTime = time }
        if let previous = previousFrameTransform, let previousTime = previousFrameTime {
            let dt = Float(time - previousTime)
            if dt > 1e-4, rotationAngle(from: previous, to: transform) / dt > maxAngularSpeed {
                return nil   // sweeping too fast — would be blurred
            }
        }
        if let last = lastTransform, !movedEnough(from: last, to: transform) { return nil }
        guard let keyframe = makeKeyframe(frame: frame) else { return nil }
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
    func upgradeKeyframe(token: simd_float4x4, with frame: ARFrame) {
        guard let index = keyframes.firstIndex(where: { $0.cameraTransform == token }) else { return }
        let ta = SIMD3<Float>(token.columns.3.x, token.columns.3.y, token.columns.3.z)
        let tb = SIMD3<Float>(frame.camera.transform.columns.3.x,
                              frame.camera.transform.columns.3.y,
                              frame.camera.transform.columns.3.z)
        guard simd_distance(ta, tb) < 0.03,
              rotationAngle(from: token, to: frame.camera.transform) < 0.035 else { return }
        guard let upgraded = makeKeyframe(frame: frame, maxImageExtent: 4096) else { return }
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

    private func makeKeyframe(frame: ARFrame, maxImageExtent: CGFloat? = nil) -> ScanKeyframe? {
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
        return ScanKeyframe(jpeg: jpeg, cameraTransform: frame.camera.transform,
                            intrinsics: intrinsics, depthWidth: dw, depthHeight: dh,
                            depth: depth)
    }

    /// At the cap: drop every other keyframe and demand twice the movement for
    /// the next ones — long scans keep broad coverage with bounded memory.
    private func thinIfNeeded() {
        guard keyframes.count >= Self.maxKeyframes else { return }
        keyframes = keyframes.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        minTranslation *= 2
        minRotation = min(minRotation * 2, .pi / 2)
    }
}
