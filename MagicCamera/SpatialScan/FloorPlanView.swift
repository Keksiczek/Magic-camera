//
//  FloorPlanView.swift
//  Magic Camera
//
//  Draws a FloorPlan as a top-down 2D diagram (Canvas) with overall dimensions
//  and floor area, in the user's chosen units.
//

import SwiftUI

struct FloorPlanView: View {
    let plan: FloorPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Canvas { context, size in draw(context, size: size) }
                    .background(Theme.background)
                statsBar
            }
            .navigationTitle("Floor Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func draw(_ context: GraphicsContext, size: CGSize) {
        let span = plan.size
        let worldW = max(span.x, 0.001), worldH = max(span.y, 0.001)
        let padding: CGFloat = 32
        let scale = min((size.width - padding * 2) / CGFloat(worldW),
                        (size.height - padding * 2) / CGFloat(worldH))
        let drawW = CGFloat(worldW) * scale, drawH = CGFloat(worldH) * scale
        let originX = (size.width - drawW) / 2
        let originY = (size.height - drawH) / 2

        func map(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: originX + CGFloat(p.x - plan.min.x) * scale,
                    y: originY + CGFloat(plan.max.y - p.y) * scale)   // flip so it reads top-down
        }

        var bounds = Path()
        bounds.addRect(CGRect(x: originX, y: originY, width: drawW, height: drawH))
        context.stroke(bounds, with: .color(Theme.surfaceStroke), lineWidth: 1)

        var walls = Path()
        for (start, end) in plan.wallSegments {
            walls.move(to: map(start))
            walls.addLine(to: map(end))
        }
        context.stroke(walls, with: .color(Theme.accent),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private var statsBar: some View {
        HStack(spacing: 14) {
            stat("Width", MeasurementFormat.distance(plan.size.x))
            stat("Depth", MeasurementFormat.distance(plan.size.y))
            stat("Floor area", MeasurementFormat.area(plan.floorArea))
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
