//
//  KeyframeSharpness.swift
//  Magic Camera
//
//  A focus/sharpness measure for texture keyframes. The capture path already
//  rejects fast pans (motion blur), but a keyframe can still be soft — slight
//  motion, a focus hunt, a hand wobble — and a soft photo baked onto the mesh is
//  exactly the "textures nic moc" complaint. Scoring each keyframe's sharpness
//  lets the bake prefer the crisp views (per-triangle and in the multi-view
//  blend) and lets thinning keep the sharper of each pair instead of a blind
//  every-other cull.
//
//  The metric is the variance of the Laplacian — the classic focus measure: a
//  sharp image has strong high-frequency edges (high Laplacian energy), a blurred
//  one doesn't. It's computed over a FIXED sample grid on the luma, so the value
//  is resolution-invariant and comparable across a scan's mix of video-stream and
//  upgraded high-resolution keyframes.
//

import CoreVideo

enum KeyframeSharpness {
    /// Fixed luma sample grid — resolution-invariant, so a 1920×1440 video frame
    /// and a 4032 px still score on the same scale.
    private static let gridWidth = 160
    private static let gridHeight = 120

    /// Laplacian-variance focus score of a camera frame's luma (Y) plane. Higher
    /// is sharper; 0 for an unreadable buffer. Only the relative value within one
    /// scan matters (it drives which keyframes the bake favours).
    static func measure(_ pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard w > 16, h > 16 else { return 0 }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Sample a fixed grid over the central 80 % (skip the vignette-prone rim).
        let gw = gridWidth, gh = gridHeight
        let x0 = w / 10, y0 = h / 10
        let cw = w - 2 * x0, ch = h - 2 * y0
        guard cw > gw, ch > gh else { return 0 }
        var luma = [Float](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            let sy = y0 + gy * ch / gh
            let row = ptr + sy * stride
            for gx in 0..<gw {
                luma[gy * gw + gx] = Float(row[x0 + gx * cw / gw])
            }
        }

        // Variance of the 4-neighbour Laplacian over the grid interior.
        var sum: Float = 0, sumSq: Float = 0
        var n = 0
        for gy in 1..<(gh - 1) {
            for gx in 1..<(gw - 1) {
                let c = luma[gy * gw + gx]
                let lap = luma[(gy - 1) * gw + gx] + luma[(gy + 1) * gw + gx]
                        + luma[gy * gw + gx - 1] + luma[gy * gw + gx + 1] - 4 * c
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / Float(n)
        return max(sumSq / Float(n) - mean * mean, 0)
    }

    /// Per-view blend weights from the set's sharpness values, normalised against
    /// the set's own median so the scale (which varies with scene/exposure) drops
    /// out: the sharpest views weigh ~1, the median ~0.75, the softest ~0.5 — a
    /// gentle re-rank that favours crisp keyframes without discarding coverage.
    /// A set with no sharpness signal (all equal — e.g. legacy keyframes) weighs
    /// uniformly, so the bake behaves exactly as before.
    static func weights(for sharpness: [Float]) -> [Float] {
        guard !sharpness.isEmpty else { return [] }
        let sorted = sharpness.sorted()
        let median = max(sorted[sorted.count / 2], 1e-6)
        return sharpness.map { 0.5 + 0.5 * max($0, 0) / (max($0, 0) + median) }
    }
}
