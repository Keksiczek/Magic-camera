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

            VStack {
                topBar
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
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            StatusBadge(text: statusText, systemImage: statusIcon, tint: statusTint)
            Spacer()
            if let distance = viewModel.measureDistance {
                StatusBadge(text: distanceString(distance), systemImage: "ruler", tint: Theme.accentWarm)
            }
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
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            viewModel.handleTap(at: value.location, viewSize: geo.size)
                        })

                    if viewModel.measureScreenPoints.count == 2 {
                        Path { path in
                            path.move(to: viewModel.measureScreenPoints[0])
                            path.addLine(to: viewModel.measureScreenPoints[1])
                        }
                        .stroke(Theme.accentWarm, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }

                    ForEach(Array(viewModel.measureScreenPoints.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .strokeBorder(Theme.accentWarm, lineWidth: 3)
                            .background(Circle().fill(Color.black.opacity(0.4)))
                            .frame(width: 20, height: 20)
                            .position(point)
                    }

                    if viewModel.measureScreenPoints.isEmpty {
                        Text("Tap two points to measure")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .position(x: geo.size.width / 2, y: geo.size.height * 0.35)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Controls

    private var controlStack: some View {
        VStack(spacing: 14) {
            parameterControls()
            EffectPicker(selection: viewModel.settings.kind) { viewModel.select($0) }
            captureRow
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
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
            RecordButton(isRecording: viewModel.isRecording) { viewModel.toggleRecording() }
            Spacer()
            ShutterButton { viewModel.capturePhoto() }
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
