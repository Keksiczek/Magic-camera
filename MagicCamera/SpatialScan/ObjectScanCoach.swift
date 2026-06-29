//
//  ObjectScanCoach.swift
//  Magic Camera
//
//  Apple-Object-Capture-style coaching for object scans: one adaptive prompt
//  that walks the user from "move around your object" → live progress → "every
//  angle captured", with a low-light nudge. The stage is derived purely from the
//  live orbit coverage and capture confidence, so it stays in lock-step with the
//  orbit-coverage ring. Presentational only.
//

import SwiftUI

struct ObjectScanCoach: View {
    /// Fraction of the 360° orbit covered so far, [0, 1].
    let orbitFraction: Float
    /// Live capture confidence, 0 = unknown, else 0…1.
    let confidence: Float
    /// Elevation bands seen so far (bit 0 = level/side, bit 1 = angled, bit 2 =
    /// top-down). A sweep that circles but never drops to the side reconstructs
    /// flat — the coach catches that before the user taps Finish.
    let elevationBands: UInt8

    private enum Stage { case lowLight, start, needsSides, around, almost, done }

    private var hasSideViews: Bool { elevationBands & 1 != 0 }

    private var stage: Stage {
        if confidence > 0, confidence < 0.34 { return .lowLight }
        // Circling but only from above → the object has no captured sides and
        // will reconstruct as a flat disc. Once there's some orbit, send the user
        // to eye level before anything else.
        if orbitFraction > 0.25, !hasSideViews { return .needsSides }
        switch orbitFraction {
        case ..<0.12: return .start
        case ..<0.6:  return .around
        case ..<0.85: return .almost
        default:      return .done
        }
    }

    private var percent: Int { Int((orbitFraction * 100).rounded()) }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: stage == .start || stage == .around
                                  || stage == .almost || stage == .needsSides)
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
        case .lowLight:   return "sun.max.fill"
        case .needsSides: return "arrow.down"
        case .start, .around, .almost: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch stage {
        case .lowLight, .needsSides: return Color(red: 1, green: 0.75, blue: 0)   // amber
        case .done:     return .green
        default:        return Theme.accent
        }
    }

    private var title: String {
        switch stage {
        case .lowLight:   return "More light helps"
        case .start:      return "Move around your object"
        case .needsSides: return "Scan the sides too"
        case .around:     return "Keep going — \(percent)%"
        case .almost:     return "Almost there — \(percent)%"
        case .done:       return "Every angle captured"
        }
    }

    private var subtitle: String {
        switch stage {
        case .lowLight:   return "Brighten the scene or move a little closer"
        case .start:      return "Walk a slow circle to capture every side"
        case .needsSides: return "Lower to the object's level — top-down alone comes out flat"
        case .around:     return "Keep circling — cover the whole subject"
        case .almost:     return "Fill the last gaps in the ring"
        case .done:       return "Tap Finish — or tilt for the top and bottom too"
        }
    }
}
