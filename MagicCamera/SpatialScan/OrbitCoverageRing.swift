//
//  OrbitCoverageRing.swift
//  Magic Camera
//
//  Apple-style orbit-coverage ring for object / targeted point scans: arc
//  segments around a circle that fill in as the user walks around the subject,
//  with the covered fraction in the centre. The segment bitmask + fraction come
//  live from the recorder's OrbitCoverageTracker. Purely presentational.
//

import SwiftUI

struct OrbitCoverageRing: View {
    /// Covered fraction of the orbit, [0, 1].
    let fraction: Float
    /// Bitmask of covered azimuth sectors (bit i = sector i).
    let sectors: UInt32
    /// Must match the recorder's OrbitCoverageTracker sector count.
    var sectorCount: Int = 24

    /// Full enough orbit reached — flip the ring green as the "you can finish" cue.
    private var complete: Bool { fraction >= 0.85 }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 5
                let sweep = 360.0 / Double(sectorCount)
                let gap = sweep * 0.18                       // small gap between segments
                let coveredColor = complete ? Color.green : Theme.accent
                let emptyColor = Color.white.opacity(0.16)
                for i in 0..<sectorCount {
                    let on = sectors & (UInt32(1) << UInt32(i)) != 0
                    // 0° at the top (−90°), clockwise — as if looking down on the orbit.
                    let start = Double(i) * sweep - 90 + gap / 2
                    let end = Double(i + 1) * sweep - 90 - gap / 2
                    var path = Path()
                    path.addArc(center: center, radius: radius,
                                startAngle: .degrees(start), endAngle: .degrees(end),
                                clockwise: false)
                    context.stroke(path, with: .color(on ? coveredColor : emptyColor),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
            }
            VStack(spacing: 0) {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text("orbit")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 92, height: 92)
        .padding(6)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Orbit coverage")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent of the way around")
    }
}
