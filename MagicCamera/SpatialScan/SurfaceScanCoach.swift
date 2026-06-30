//
//  SurfaceScanCoach.swift
//  Magic Camera
//
//  Coaching pill for room / area / surface point scans — the counterpart to
//  ObjectScanCoach, but without an orbit target (there's no single subject to
//  walk around). The stage is derived from the live area-coverage estimate and
//  capture confidence, so it walks the user from "sweep the area" → live
//  progress → "area captured", with a low-light nudge. Presentational only.
//

import SwiftUI

struct SurfaceScanCoach: View {
    /// Live area-coverage estimate, [0, 1] — 0 = still revealing fresh surface,
    /// 1 = the visible area is largely captured.
    let coverage: Float
    /// Live capture confidence, 0 = unknown, else 0…1.
    let confidence: Float

    private enum Stage { case lowLight, start, sweeping, almost, done }

    private var stage: Stage {
        if confidence > 0, confidence < 0.34 { return .lowLight }
        switch coverage {
        case ..<0.15: return .start
        case ..<0.7:  return .sweeping
        case ..<0.9:  return .almost
        default:      return .done
        }
    }

    private var percent: Int { Int((coverage * 100).rounded()) }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: stage == .start || stage == .sweeping || stage == .almost)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.25), value: title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }

    private var symbol: String {
        switch stage {
        case .lowLight: return "sun.max.fill"
        case .start, .sweeping, .almost: return "circle.dashed"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch stage {
        case .lowLight: return Color(red: 1, green: 0.75, blue: 0)   // amber
        case .done:     return .green
        default:        return Theme.accent
        }
    }

    private var title: String {
        switch stage {
        case .lowLight: return "More light helps"
        case .start:    return "Sweep across the area"
        case .sweeping: return "Keep sweeping — \(percent)%"
        case .almost:   return "Almost there — \(percent)%"
        case .done:     return "Area captured"
        }
    }

    private var subtitle: String {
        switch stage {
        case .lowLight: return "Brighten the area or move a little closer"
        case .start:    return "Pan slowly and evenly — keep the surface in view"
        case .sweeping: return "Cover the whole area, no rushing — overlap your passes"
        case .almost:   return "Fill the last gaps in the coverage"
        case .done:     return "Tap Finish — or keep panning to extend the area"
        }
    }
}
