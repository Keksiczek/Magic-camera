//
//  SubjectMasker.swift
//  Magic Camera
//
//  One-shot Vision foreground-instance segmentation: returns a tight bounding
//  box of the most prominent subject (Vision-normalized coordinates). Pixel
//  accurate, unlike objectness saliency, which only proposes loose
//  "interesting" regions. Synchronous and fairly heavy (~100 ms on the Neural
//  Engine) — call on a background queue, one shot per user action.
//

import CoreVideo
import Vision

enum SubjectMasker {
    /// Smallest believable subject as a fraction of the frame — anything
    /// smaller is usually segmentation noise, not the thing being scanned.
    private static let minCoverage: Float = 0.004

    /// Tight bounding box (Vision normalized, bottom-left origin) of the
    /// largest lifted foreground instance, or nil when nothing lifts.
    static func subjectBox(pixelBuffer: CVPixelBuffer,
                           orientation: CGImagePropertyOrientation) -> CGRect? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else { return nil }

        // The low-res instance mask holds one label per pixel (0 = background).
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        guard width > 0, height > 0 else { return nil }

        // One pass: per-label pixel counts and pixel-space bounds.
        var counts = [Int](repeating: 0, count: 256)
        var minXs = [Int](repeating: .max, count: 256)
        var minYs = [Int](repeating: .max, count: 256)
        var maxXs = [Int](repeating: -1, count: 256)
        var maxYs = [Int](repeating: -1, count: 256)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let label = Int(row.load(fromByteOffset: x, as: UInt8.self))
                guard label != 0 else { continue }
                counts[label] += 1
                if x < minXs[label] { minXs[label] = x }
                if x > maxXs[label] { maxXs[label] = x }
                if y < minYs[label] { minYs[label] = y }
                if y > maxYs[label] { maxYs[label] = y }
            }
        }
        guard let best = (1..<256).max(by: { counts[$0] < counts[$1] }),
              counts[best] > 0,
              Float(counts[best]) / Float(width * height) >= minCoverage else { return nil }

        // Buffer rows run top-down; Vision rects use a bottom-left origin.
        return CGRect(x: CGFloat(minXs[best]) / CGFloat(width),
                      y: 1 - CGFloat(maxYs[best] + 1) / CGFloat(height),
                      width: CGFloat(maxXs[best] - minXs[best] + 1) / CGFloat(width),
                      height: CGFloat(maxYs[best] - minYs[best] + 1) / CGFloat(height))
    }
}
