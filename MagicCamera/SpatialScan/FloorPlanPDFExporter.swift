//
//  FloorPlanPDFExporter.swift
//  Magic Camera
//
//  Renders a FloorPlan into a shareable A4 PDF: title block, the top-down wall
//  diagram, overall dimension lines, floor area and a scale bar. Print-styled
//  (dark ink on white) regardless of the app theme.
//

import UIKit

enum FloorPlanPDFExporter {
    enum ExportError: LocalizedError {
        case writeFailed
        var errorDescription: String? { "Couldn't write the floor-plan PDF." }
    }

    // A4 portrait at 72 dpi.
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 56
    /// Extra room left around the diagram for the dimension lines + labels.
    private static let dimensionGutter: CGFloat = 36

    private static let ink = UIColor(white: 0.12, alpha: 1)
    private static let faint = UIColor(white: 0.62, alpha: 1)
    private static let accent = UIColor(red: 0.20, green: 0.42, blue: 0.86, alpha: 1)

    /// Writes the PDF into a temporary file and returns its URL.
    static func write(_ plan: FloorPlan) throws -> URL {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            draw(plan, in: bounds, cg: context.cgContext)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagicCamera-floorplan.pdf")
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url, options: .atomic) } catch { throw ExportError.writeFailed }
        return url
    }

    // MARK: - Page layout

    private static func draw(_ plan: FloorPlan, in page: CGRect, cg: CGContext) {
        // Title block.
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        drawText("Floor Plan", at: CGPoint(x: margin, y: margin - 14),
                 font: .systemFont(ofSize: 22, weight: .bold), color: ink)
        drawText("Magic Camera · \(dateFormatter.string(from: Date()))",
                 at: CGPoint(x: margin, y: margin + 14),
                 font: .systemFont(ofSize: 10, weight: .medium), color: faint)

        let stats = "Width \(MeasurementFormat.distance(plan.size.x))"
            + " · Depth \(MeasurementFormat.distance(plan.size.y))"
            + " · Floor area \(MeasurementFormat.area(plan.floorArea))"
        drawText(stats, at: CGPoint(x: margin, y: margin + 28),
                 font: .systemFont(ofSize: 10, weight: .medium), color: ink)

        // Diagram area: below the header, above the footer, inset for labels.
        let headerBottom = margin + 52
        let footerTop = page.height - margin - 28
        let area = CGRect(x: margin, y: headerBottom,
                          width: page.width - margin * 2 - dimensionGutter,
                          height: footerTop - headerBottom - dimensionGutter)

        let worldW = CGFloat(max(plan.size.x, 0.001))
        let worldH = CGFloat(max(plan.size.y, 0.001))
        let scale = min(area.width / worldW, area.height / worldH)
        let drawW = worldW * scale, drawH = worldH * scale
        let origin = CGPoint(x: area.midX - drawW / 2, y: area.midY - drawH / 2)
        let planRect = CGRect(origin: origin, size: CGSize(width: drawW, height: drawH))

        func map(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(p.x - plan.min.x) * scale,
                    y: origin.y + CGFloat(plan.max.y - p.y) * scale)   // top-down
        }

        // Bounding box (faint, dashed).
        cg.saveGState()
        cg.setStrokeColor(faint.withAlphaComponent(0.7).cgColor)
        cg.setLineWidth(0.7)
        cg.setLineDash(phase: 0, lengths: [4, 3])
        cg.stroke(planRect)
        cg.restoreGState()

        // Walls.
        cg.saveGState()
        cg.setStrokeColor(ink.cgColor)
        cg.setLineWidth(1.3)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for (start, end) in plan.wallSegments {
            cg.move(to: map(start))
            cg.addLine(to: map(end))
        }
        cg.strokePath()
        cg.restoreGState()

        // Overall dimensions: width below the plan, depth to its right.
        drawDimensionLine(cg,
                          from: CGPoint(x: planRect.minX, y: planRect.maxY + 18),
                          to: CGPoint(x: planRect.maxX, y: planRect.maxY + 18),
                          label: MeasurementFormat.distance(plan.size.x),
                          rotated: false)
        drawDimensionLine(cg,
                          from: CGPoint(x: planRect.maxX + 18, y: planRect.minY),
                          to: CGPoint(x: planRect.maxX + 18, y: planRect.maxY),
                          label: MeasurementFormat.distance(plan.size.y),
                          rotated: true)

        drawScaleBar(cg, scale: scale,
                     at: CGPoint(x: margin, y: page.height - margin - 6))
    }

    // MARK: - Drawing helpers

    /// Dimension line with end ticks and a centred label (rotated for vertical).
    private static func drawDimensionLine(_ cg: CGContext, from: CGPoint, to: CGPoint,
                                          label: String, rotated: Bool) {
        cg.saveGState()
        cg.setStrokeColor(accent.cgColor)
        cg.setLineWidth(0.9)
        cg.move(to: from); cg.addLine(to: to)
        let tick: CGFloat = 4
        if rotated {
            cg.move(to: CGPoint(x: from.x - tick, y: from.y)); cg.addLine(to: CGPoint(x: from.x + tick, y: from.y))
            cg.move(to: CGPoint(x: to.x - tick, y: to.y));     cg.addLine(to: CGPoint(x: to.x + tick, y: to.y))
        } else {
            cg.move(to: CGPoint(x: from.x, y: from.y - tick)); cg.addLine(to: CGPoint(x: from.x, y: from.y + tick))
            cg.move(to: CGPoint(x: to.x, y: to.y - tick));     cg.addLine(to: CGPoint(x: to.x, y: to.y + tick))
        }
        cg.strokePath()
        cg.restoreGState()

        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        if rotated {
            cg.saveGState()
            cg.translateBy(x: mid.x, y: mid.y)
            cg.rotate(by: -.pi / 2)
            drawText(label, centredAt: CGPoint(x: 0, y: -9), font: font, color: accent)
            cg.restoreGState()
        } else {
            drawText(label, centredAt: CGPoint(x: mid.x, y: mid.y + 9), font: font, color: accent)
        }
    }

    /// 1 / 2 / 5 m scale bar sized to the current drawing scale.
    private static func drawScaleBar(_ cg: CGContext, scale: CGFloat, at origin: CGPoint) {
        let candidates: [Float] = [0.5, 1, 2, 5, 10]
        let metres = candidates.last { CGFloat($0) * scale <= 140 } ?? 0.5
        let length = CGFloat(metres) * scale

        cg.saveGState()
        cg.setStrokeColor(ink.cgColor)
        cg.setLineWidth(1.1)
        cg.move(to: origin); cg.addLine(to: CGPoint(x: origin.x + length, y: origin.y))
        cg.move(to: CGPoint(x: origin.x, y: origin.y - 4)); cg.addLine(to: CGPoint(x: origin.x, y: origin.y + 4))
        cg.move(to: CGPoint(x: origin.x + length, y: origin.y - 4))
        cg.addLine(to: CGPoint(x: origin.x + length, y: origin.y + 4))
        cg.strokePath()
        cg.restoreGState()

        drawText(MeasurementFormat.distance(metres),
                 at: CGPoint(x: origin.x + length + 8, y: origin.y - 6),
                 font: .monospacedDigitSystemFont(ofSize: 9, weight: .semibold), color: ink)
    }

    private static func drawText(_ string: String, at point: CGPoint,
                                 font: UIFont, color: UIColor) {
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func drawText(_ string: String, centredAt point: CGPoint,
                                 font: UIFont, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                                  withAttributes: attributes)
    }
}
