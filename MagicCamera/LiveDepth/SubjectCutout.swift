//
//  SubjectCutout.swift
//  Magic Camera
//
//  One-tap subject cutout: lifts the foreground with Vision's instance mask
//  (the same matting Photos uses), blends it over a transparent background,
//  crops to the subject and returns a PNG with alpha. Synchronous and heavy
//  (full-resolution matte + Core Image render) — call on a background queue.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import ImageIO
import Vision

enum SubjectCutout {
    /// Padding around the subject box, as a fraction of its larger side.
    private static let boxPadding: CGFloat = 0.05

    /// Transparent-background PNG of the lifted subject(s), or nil when
    /// nothing lifts. `orientation` maps the sensor buffer to display-upright.
    static func cutoutPNG(from pixelBuffer: CVPixelBuffer,
                          orientation: CGImagePropertyOrientation) -> Data? {
        // Orient first and hand Vision the oriented image, so the matte, the
        // crop box and the render all live in one coordinate space.
        let source = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try? handler.perform([request])
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let matte = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler) else { return nil }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = CIImage(color: .clear).cropped(to: source.extent)
        blend.maskImage = CIImage(cvPixelBuffer: matte)
        guard let masked = blend.outputImage else { return nil }

        let crop = subjectRect(in: observation.instanceMask, imageExtent: source.extent)
            ?? source.extent
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.pngRepresentation(of: masked.cropped(to: crop),
                                         format: .RGBA8, colorSpace: srgb)
    }

    /// Bounding box of every lifted instance, padded, in image coordinates
    /// (bottom-left origin, matching Core Image).
    private static func subjectRect(in mask: CVPixelBuffer, imageExtent: CGRect) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        guard width > 0, height > 0 else { return nil }

        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<width where row.load(fromByteOffset: x, as: UInt8.self) != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Mask rows run top-down; Core Image's origin is bottom-left.
        let scaleX = imageExtent.width / CGFloat(width)
        let scaleY = imageExtent.height / CGFloat(height)
        var rect = CGRect(x: CGFloat(minX) * scaleX,
                          y: CGFloat(height - 1 - maxY) * scaleY,
                          width: CGFloat(maxX - minX + 1) * scaleX,
                          height: CGFloat(maxY - minY + 1) * scaleY)
        let pad = max(rect.width, rect.height) * boxPadding
        rect = rect.insetBy(dx: -pad, dy: -pad).intersection(imageExtent)
        return rect.isEmpty ? nil : rect
    }
}
