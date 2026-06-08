//
//  LiveDepthCameraView.swift
//  Magic Camera
//
//  Mode 1 UI: fullscreen Metal depth preview with effect picker, per-effect
//  parameter controls, tap-to-measure, and photo/video capture.
//

import SwiftUI

struct LiveDepthCameraView: View {
    @State private var viewModel = LiveDepthCameraViewModel()
    @State private var showAdjust = false

    var body: some View {
        Group {
            if viewModel.isSupported {
                cameraSurface
            } else {
                UnsupportedView(
                    title: "LiDAR required",
                    message: "Live Depth Camera needs a LiDAR-equipped device (iPhone/iPad Pro) for scene depth. This device doesn't expose ARKit scene depth.")
            }
        }
        .navigationTitle("Live Depth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var cameraSurface: some View {
        ZStack {
            MetalDepthView(viewModel: viewModel)
                .ignoresSafeArea()

            measureLayer
            detectionLayer

            VStack {
                topBar
                if viewModel.detectEnabled { detectBar }
                Spacer()
                controlStack
            }
            .padding(.vertical, 8)

            if let toast = viewModel.toast {
                VStack {
                    ToastView(message: toast).padding(.top, 60)
                    Spacer()
                }
                .animation(.spring(duration: 0.3), value: viewModel.toast)
            }
        }
        .background(Theme.background)
        .sheet(isPresented: Binding(
            get: { viewModel.dimensionsExportURL != nil },
            set: { if !$0 { viewModel.dimensionsExportURL = nil } })) {
            if let url = viewModel.dimensionsExportURL { ShareSheet(items: [url]) }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            StatusBadge(text: statusText, systemImage: statusIcon, tint: statusTint)
            Spacer()
            if let total = viewModel.measureTotal {
                StatusBadge(text: distanceString(total), systemImage: "ruler", tint: Theme.accentWarm)
            }
            if viewModel.measureEnabled && viewModel.canUndoMeasure {
                Button { Haptics.impact(.light); viewModel.undoMeasure() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            Button { Haptics.impact(.light); viewModel.toggleDetect() } label: {
                Image(systemName: "viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(viewModel.detectEnabled ? Color.black : Theme.textPrimary)
                    .padding(8)
                    .background(viewModel.detectEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial),
                                in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Detect objects")
            Button { viewModel.toggleMeasure() } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(viewModel.measureEnabled ? Color.black : Theme.textPrimary)
                    .padding(8)
                    .background(viewModel.measureEnabled ? AnyShapeStyle(Theme.accentWarm) : AnyShapeStyle(.ultraThinMaterial),
                                in: Circle())
            }
            .buttonStyle(.plain)
            if viewModel.isRecording {
                StatusBadge(text: "REC", systemImage: "record.circle", tint: .red)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Measure overlay

    @ViewBuilder
    private var measureLayer: some View {
        if viewModel.measureEnabled {
            GeometryReader { geo in
                let points = viewModel.measureScreenPoints
                let segments = viewModel.measureSegments
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            Haptics.impact(.light); viewModel.handleTap(at: value.location, viewSize: geo.size)
                        })

                    if points.count >= 2 {
                        Path { path in
                            path.move(to: points[0])
                            for p in points.dropFirst() { path.addLine(to: p) }
                        }
                        .stroke(Theme.accentWarm, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                                     lineJoin: .round, dash: [6, 4]))
                    }

                    // Per-segment distance labels at midpoints.
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                        let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                                          y: (points[i].y + points[i + 1].y) / 2)
                        Text(distanceString(seg))
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .position(mid)
                    }

                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .strokeBorder(Theme.accentWarm, lineWidth: 3)
                            .background(Circle().fill(Color.black.opacity(0.4)))
                            .frame(width: 18, height: 18)
                            .position(point)
                    }

                    if points.isEmpty {
                        Text("Tap points to chart a distance — each tap extends the line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .position(x: geo.size.width / 2, y: geo.size.height * 0.35)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Detection overlay

    @ViewBuilder
    private var detectionLayer: some View {
        if viewModel.detectEnabled {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .onAppear { viewModel.detectViewSize = geo.size }
                        .onChange(of: geo.size) { _, newValue in viewModel.detectViewSize = newValue }
                    ForEach(viewModel.detections) { object in
                        detectionBox(object)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    private func detectionBox(_ object: DetectedObject) -> some View {
        let rect = object.screenRect
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.95), lineWidth: 2)
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .topLeading) {
                Text(detectionLabel(object))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
                    .fixedSize()
                    .padding(4)
            }
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { Haptics.impact(.light); viewModel.measureObject(object) }
    }

    private func detectionLabel(_ object: DetectedObject) -> String {
        if let distance = object.distanceText { return "\(object.label) · \(distance)" }
        return object.label
    }

    private var detectBar: some View {
        HStack(spacing: 10) {
            if viewModel.hasMeasuredObjects {
                StatusBadge(text: "\(viewModel.measuredObjects.count) measured",
                            systemImage: "ruler.fill", tint: Theme.accent)
                Button { Haptics.impact(.light); viewModel.exportDimensions() } label: {
                    Label("CSV", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                Button(role: .destructive) { viewModel.clearMeasuredObjects() } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(8).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            } else {
                Text("Tap a detected object to measure its size")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 6)
    }

    // MARK: - Controls

    private var controlStack: some View {
        VStack(spacing: 14) {
            parameterControls()
            if showAdjust { toneControls }
            adjustToggle
            EffectPicker(selection: viewModel.settings.kind) { viewModel.select($0) }
            captureRow
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var adjustToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showAdjust.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Adjust")
                if viewModel.settings.hasToneGrade {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
                Spacer()
                Image(systemName: showAdjust ? "chevron.up" : "chevron.down")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 18)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var toneControls: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 10) {
            LabeledSlider(title: "Saturation", value: $vm.settings.saturation, range: 0...2)
            LabeledSlider(title: "Contrast", value: $vm.settings.contrast, range: 0.5...1.8)
            LabeledSlider(title: "Vignette", value: $vm.settings.vignette, range: 0...1)
            LabeledSlider(title: "Grain", value: $vm.settings.grain, range: 0...0.3)
            Button { vm.settings.saturation = 1; vm.settings.contrast = 1
                     vm.settings.vignette = 0; vm.settings.grain = 0 } label: {
                Text("Reset adjustments")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func parameterControls() -> some View {
        @Bindable var vm = viewModel
        let kind = viewModel.settings.kind
        VStack(spacing: 10) {
            if kind.usesIntensity {
                LabeledSlider(title: "Intensity", value: $vm.settings.intensity, range: 0...1)
            }
            if kind.usesFocusDistance {
                LabeledSlider(title: "Focus distance", value: $vm.settings.focusDistance,
                              range: 0.1...5.0, format: "%.2f", unit: " m")
                LabeledSlider(title: "Focus range", value: $vm.settings.focusRange,
                              range: 0.05...2.0, format: "%.2f", unit: " m")
            }
            if kind.usesFogDensity {
                LabeledSlider(title: "Fog density", value: $vm.settings.fogDensity, range: 0.05...2.0)
            }
            if kind.usesDepthRange {
                LabeledSlider(title: "Max distance", value: $vm.settings.depthMax,
                              range: 0.5...8.0, format: "%.1f", unit: " m")
            }
            if kind.usesLightAzimuth {
                LabeledSlider(title: "Light angle", value: $vm.settings.lightAzimuth,
                              range: 0...6.2831853, format: "%.2f", unit: " rad")
            }
        }
        .padding(.horizontal, 18)
    }

    private var captureRow: some View {
        HStack {
            Spacer()
            RecordButton(isRecording: viewModel.isRecording) { Haptics.impact(.heavy); viewModel.toggleRecording() }
            Spacer()
            ShutterButton { Haptics.impact(.medium); viewModel.capturePhoto() }
            Spacer()
            Color.clear.frame(width: 52, height: 52)
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Helpers

    private func distanceString(_ meters: Float) -> String {
        meters < 1 ? String(format: "%.0f cm", meters * 100) : String(format: "%.2f m", meters)
    }

    private var statusText: String {
        switch viewModel.status {
        case .unsupported:    return "Unsupported"
        case .initializing:   return "Starting…"
        case .running:        return "Live"
        case .limited(let r): return r
        case .interrupted:    return "Interrupted"
        case .failed(let m):  return m
        }
    }

    private var statusIcon: String {
        switch viewModel.status {
        case .running: return "dot.radiowaves.left.and.right"
        case .failed:  return "exclamationmark.triangle"
        default:       return "hourglass"
        }
    }

    private var statusTint: Color {
        switch viewModel.status {
        case .running:              return Theme.accent
        case .failed, .unsupported: return .red
        default:                    return Theme.accentWarm
        }
    }
}
