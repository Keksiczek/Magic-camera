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

/// Horizontal, scrollable row of one-tap photographic looks (tone-grade presets).
struct LookPicker: View {
    let selection: PhotoLook?
    let onSelect: (PhotoLook) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoLook.allCases) { look in
                    let isActive = look == selection
                    Button { onSelect(look) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: look.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                            Text(look.title)
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .foregroundStyle(isActive ? Color.black : Theme.textSecondary)
                        .background(
                            Capsule().fill(isActive ? AnyShapeStyle(Theme.accentWarm)
                                                    : AnyShapeStyle(Theme.surface))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: format, value) + unit)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            // Larger thumb + extra vertical padding so the handle is easy to grab.
            Slider(value: $value, in: range)
                .tint(Theme.accent)
                .controlSize(.large)
                .padding(.vertical, 6)
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

/// Small status pill (tracking state, point count, …). Single-line with
/// monospaced digits so live counters tick without making the badge wobble.
struct StatusBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.accent
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }
}

/// Pulsing red dot — a compact "recording / scanning" indicator that replaces
/// a full text badge where horizontal space is tight.
struct RecordingDot: View {
    @State private var pulsing = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .padding(8)
            .background(.ultraThinMaterial, in: Circle())
            .onAppear { pulsing = true }
            .accessibilityLabel("Scanning")
    }
}

/// Dims the screen outside a central circle to focus attention on the scan
/// subject when a region-of-interest target is active. Non-interactive, so taps
/// still reach the AR view beneath it.
struct ROIFocusOverlay: View {
    /// Clear-circle radius as a fraction of the smaller screen dimension —
    /// fallback when no live screen-space projection is available.
    var clearFraction: CGFloat = 0.4
    /// Live projection of the ROI sphere; when set, the clear circle tracks
    /// the actual subject instead of sitting in the screen centre.
    var circle: ROIScreenCircle? = nil

    var body: some View {
        GeometryReader { geo in
            let fallbackRadius = min(geo.size.width, geo.size.height) * clearFraction
            let radius = circle.map {
                min(max($0.radius, 40), max(geo.size.width, geo.size.height))
            } ?? fallbackRadius
            let center = circle?.center
                ?? CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.44)
            let circleRect = CGRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)
            Canvas { context, size in
                var dim = Path(CGRect(origin: .zero, size: size))
                dim.addEllipse(in: circleRect)
                context.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

                var ring = Path()
                ring.addEllipse(in: circleRect)
                context.stroke(ring, with: .color(Theme.accent.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
