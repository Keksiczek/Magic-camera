//
//  Controls.swift
//  Magic Camera
//
//  Reusable SwiftUI controls for the camera surfaces: effect picker, labelled
//  parameter slider, shutter/record buttons, status badge and a toast.
//

import SwiftUI

/// Horizontal, scrollable row of effect chips.
struct EffectPicker: View {
    let selection: DepthEffectKind
    let onSelect: (DepthEffectKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(DepthEffectKind.allCases) { kind in
                    Button { onSelect(kind) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 18, weight: .semibold))
                            Text(kind.title)
                                .font(.caption2.weight(.medium))
                        }
                        .frame(width: 66, height: 56)
                        .foregroundStyle(kind == selection ? Color.black : Theme.textPrimary)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                                .fill(kind == selection ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

/// A labelled slider with a trailing value read-out.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: String = "%.2f"
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: format, value) + unit)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(value: $value, in: range)
                .tint(Theme.accent)
        }
    }
}

/// Circular shutter button.
struct ShutterButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white).frame(width: 66, height: 66)
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 76, height: 76)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Take photo")
    }
}

/// Record toggle (dot -> square).
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.8), lineWidth: 3).frame(width: 52, height: 52)
                RoundedRectangle(cornerRadius: isRecording ? 5 : 14, style: .continuous)
                    .fill(Color.red)
                    .frame(width: isRecording ? 22 : 32, height: isRecording ? 22 : 32)
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// Small status pill (tracking state, point count, …).
struct StatusBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.accent
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }
}

/// Transient toast message.
struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassPanel(corner: Theme.cornerMedium)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
