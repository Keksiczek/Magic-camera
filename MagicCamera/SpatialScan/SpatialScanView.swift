//
//  SpatialScanView.swift
//  Magic Camera
//
//  Mode 2 UI: choose point-cloud or mesh scanning (+ quality), scan with a live
//  overlay, then review the result with camera presets, colour modes, point
//  size, save and export. Saved scans are reachable from the toolbar.
//

import SwiftUI

struct SpatialScanView: View {
    @State private var viewModel = SpatialScanViewModel()
    @State private var autoOrbit = false
    @State private var pendingPreset: CameraPreset?
    @State private var showExport = false
    @State private var showGallery = false

    var body: some View {
        Group {
            if viewModel.isSupported {
                content
            } else {
                UnsupportedView(
                    title: "LiDAR required",
                    message: "Spatial Scan builds a 3D point cloud or mesh from LiDAR depth. This device doesn't expose ARKit scene depth.")
            }
        }
        .navigationTitle("Spatial Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showGallery = true } label: { Image(systemName: "folder") }
            }
        }
        .sheet(isPresented: $showGallery) {
            ScanGalleryView { cloud in viewModel.loadSaved(cloud) }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.exportURL != nil },
            set: { if !$0 { viewModel.exportURL = nil } })) {
            if let url = viewModel.exportURL { ShareSheet(items: [url]) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .scanning: scanningSurface
        case .reviewing:       reviewSurface
        }
    }

    // MARK: - Scanning

    private var scanningSurface: some View {
        ZStack {
            ScanARView(viewModel: viewModel).ignoresSafeArea()

            VStack {
                HStack {
                    StatusBadge(text: scanStatusText,
                                systemImage: viewModel.scanKind.systemImage,
                                tint: Theme.accent)
                    Spacer()
                    if viewModel.isScanning {
                        StatusBadge(text: "Scanning", systemImage: "dot.radiowaves.left.and.right", tint: .red)
                    }
                }
                .padding(.horizontal, 14)
                Spacer()
                scanControls
            }
            .padding(.vertical, 10)

            toastOverlay
        }
        .background(Theme.background)
    }

    private var scanControls: some View {
        @Bindable var vm = viewModel
        return VStack(spacing: 12) {
            if !viewModel.isScanning {
                Picker("Type", selection: $vm.scanKind) {
                    ForEach(availableKinds) { kind in Text(kind.rawValue).tag(kind) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if viewModel.scanKind == .points {
                    Picker("Quality", selection: $vm.quality) {
                        ForEach(ScanQuality.allCases) { q in Text(q.rawValue).tag(q) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                }

                Text(viewModel.scanKind == .mesh
                     ? "Sweep the space slowly to build a surface mesh."
                     : "Point at a textured surface and move slowly around it.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                viewModel.isScanning ? viewModel.stopScan() : viewModel.startScan()
            } label: {
                Label(viewModel.isScanning ? "Stop Scan" : "Start Scan",
                      systemImage: viewModel.isScanning ? "stop.circle.fill" : "play.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(viewModel.isScanning ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accent),
                                in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                    .foregroundStyle(viewModel.isScanning ? Color.white : Color.black)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var availableKinds: [ScanKind] {
        viewModel.supportsMesh ? ScanKind.allCases : [.points]
    }

    private var scanStatusText: String {
        if viewModel.scanKind == .mesh {
            return viewModel.isScanning ? "Meshing…" : "Mesh"
        }
        return "\(viewModel.pointCount) pts"
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewSurface: some View {
        ZStack {
            reviewViewer

            VStack {
                HStack {
                    StatusBadge(text: resultCountText, systemImage: resultIcon)
                    Spacer()
                    Button(role: .destructive) { viewModel.discard() } label: {
                        Label("New", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .tint(.red)
                }
                .padding(.horizontal, 14)
                Spacer()
                reviewControls
            }
            .padding(.vertical, 10)

            toastOverlay
        }
        .background(Theme.background)
        .confirmationDialog("Export", isPresented: $showExport, titleVisibility: .visible) {
            if viewModel.capturedMesh != nil {
                ForEach(MeshExporter.Format.allCases) { format in
                    Button(format.rawValue) { viewModel.exportMesh(format: format) }
                }
            } else {
                ForEach(PointCloudExporter.Format.allCases) { format in
                    Button(format.rawValue) { viewModel.exportPointCloud(format: format) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var reviewViewer: some View {
        if let mesh = viewModel.capturedMesh {
            MeshViewer(mesh: mesh, autoOrbit: autoOrbit, preset: $pendingPreset)
                .ignoresSafeArea()
        } else if let cloud = viewModel.capturedCloud {
            PointCloudViewer(cloud: cloud,
                             colorMode: viewModel.colorMode,
                             pointSize: viewModel.pointSize,
                             autoOrbit: autoOrbit,
                             preset: $pendingPreset)
                .ignoresSafeArea()
        }
    }

    private var reviewControls: some View {
        @Bindable var vm = viewModel
        return VStack(spacing: 12) {
            presetRow

            if viewModel.capturedMesh == nil {
                Picker("Colour", selection: $vm.colorMode) {
                    ForEach(PointColorMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                LabeledSlider(title: "Point size", value: pointSizeBinding, range: 2...16, format: "%.0f")
                    .padding(.horizontal, 18)
            }

            actionRow
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(CameraPreset.allCases) { preset in
                Button { pendingPreset = preset } label: {
                    Label(preset.title, systemImage: preset.systemImage)
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $autoOrbit) {
                Label("Orbit", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.button)
            .tint(Theme.accent)

            if viewModel.capturedMesh == nil {
                Button { viewModel.savePointCloud() } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }

            Button { showExport = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var resultCountText: String {
        if viewModel.capturedMesh != nil { return "\(viewModel.pointCount) tris" }
        return "\(viewModel.pointCount) pts"
    }

    private var resultIcon: String {
        viewModel.capturedMesh != nil ? "grid" : "circle.grid.3x3.fill"
    }

    private var pointSizeBinding: Binding<Float> {
        Binding(get: { Float(viewModel.pointSize) },
                set: { viewModel.pointSize = CGFloat($0) })
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = viewModel.toast {
            VStack {
                ToastView(message: toast).padding(.top, 60)
                Spacer()
            }
            .animation(.spring(duration: 0.3), value: viewModel.toast)
        }
    }
}
