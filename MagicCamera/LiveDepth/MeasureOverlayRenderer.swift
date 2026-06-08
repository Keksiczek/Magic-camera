//
//  MeasureOverlayRenderer.swift
//  Magic Camera
//
//  Bakes the tap-to-measure polyline (points, segments and total distance) into
//  a captured photo, so a saved measurement screenshot is self-contained.
//

import CoreGraphics
import UIKit

enum MeasureOverlayRenderer {
    private static let lineColor = UIColor(red: 1.0, green: 0.55, blue: 0.30, alpha: 1)

    /// Returns a new image with the measurement annotations drawn over `base`.
    /// `screenPoints` are in view points; they are scaled to the image's pixels.
    static func compose(base: CGImage, screenPoints: [CGPoint], segments: [Float],
                        total: Float?, viewSize: CGSize) -> CGImage? {
        guard screenPoints.count >= 2, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let pixelSize = CGSize(width: base.width, height: base.height)
        let scaleX = pixelSize.width / viewSize.width
        let scaleY = pixelSize.height / viewSize.height
        let pts = screenPoints.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
        let lineWidth = max(pixelSize.width, pixelSize.height) * 0.004
        let dotRadius = lineWidth * 2.2
        let fontSize = max(pixelSize.width, pixelSize.height) * 0.022

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext

            // Base image (CGImage origin is top-left; UIKit context is bottom-up).
            cg.saveGState()
            cg.translateBy(x: 0, y: pixelSize.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(base, in: CGRect(origin: .zero, size: pixelSize))
            cg.restoreGState()

            // Polyline.
            cg.setStrokeColor(lineColor.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setLineDash(phase: 0, lengths: [lineWidth * 4, lineWidth * 3])
            cg.beginPath()
            cg.move(to: pts[0])
            for p in pts.dropFirst() { cg.addLine(to: p) }
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])

            // Vertices.
            cg.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
            cg.setStrokeColor(lineColor.cgColor)
            cg.setLineWidth(lineWidth)
            for p in pts {
                let rect = CGRect(x: p.x - dotRadius, y: p.y - dotRadius,
                                  width: dotRadius * 2, height: dotRadius * 2)
                cg.fillEllipse(in: rect)
                cg.strokeEllipse(in: rect)
            }

            // Per-segment labels at midpoints.
            for (i, seg) in segments.enumerated() where i + 1 < pts.count {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2,
                                  y: (pts[i].y + pts[i + 1].y) / 2)
                drawLabel(distanceString(seg), at: mid, fontSize: fontSize, in: cg)
            }

            // Total near the last point.
            if let total, let last = pts.last {
                drawLabel("Σ " + distanceString(total),
                          at: CGPoint(x: last.x, y: last.y + dotRadius * 3.5),
                          fontSize: fontSize * 1.1, in: cg)
            }
        }
        return image.cgImage
    }

    private static func drawLabel(_ text: String, at center: CGPoint,
                                  fontSize: CGFloat, in cg: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let pad = fontSize * 0.4
        let box = CGRect(x: center.x - textSize.width / 2 - pad,
                         y: center.y - textSize.height / 2 - pad,
                         width: textSize.width + pad * 2,
                         height: textSize.height + pad * 2)
        let path = UIBezierPath(roundedRect: box, cornerRadius: box.height * 0.3)
        cg.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()
        str.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2))
    }

    private static func distanceString(_ meters: Float) -> String {
        meters < 1 ? String(format: "%.0f cm", meters * 100) : String(format: "%.2f m", meters)
    }
}
