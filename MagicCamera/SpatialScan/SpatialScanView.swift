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
    @State private var showMergeGallery = false
    @State private var autoTargetRequest = false
    @State private var meshCameraMode: MeshCameraMode = .orbit
    @State private var rulerEnabled = false
    @State private var rulerDistance: Float?
    @State private var showFloorPlan = false

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
            ScanGalleryView(onSelectCloud: { viewModel.loadSaved($0) },
                            onSelectMesh: { viewModel.loadSavedMesh($0) })
        }
        .sheet(isPresented: $showMergeGallery) {
            ScanGalleryView(onSelectCloud: { viewModel.mergeSavedCloud($0) },
                            onSelectMesh: { _ in }, mergeMode: true)
        }
        .sheet(isPresented: $showFloorPlan) {
            if let mesh = viewModel.effectiveMesh, let plan = FloorPlanBuilder.build(from: mesh) {
                FloorPlanView(plan: plan)
            } else {
                ContentUnavailableView("No walls detected", systemImage: "map",
                                       description: Text("A floor plan needs a classified mesh scan with walls."))
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.exportURL != nil },
            set: { if !$0 { viewModel.exportURL = nil } })) {
            if let url = viewModel.exportURL { ShareSheet(items: [url]) }
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.arQuickLookURL != nil },
            set: { if !$0 { viewModel.arQuickLookURL = nil } })) {
            if let url = viewModel.arQuickLookURL {
                ARQuickLookView(url: url).ignoresSafeArea()
            }
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
            ScanARView(viewModel: viewModel, autoTargetRequest: $autoTargetRequest)
                .ignoresSafeArea()

            if viewModel.isScanning && viewModel.hasScanTarget && viewModel.scanKind == .points {
                ROIFocusOverlay(clearFraction: roiClearFraction)
                    .transition(.opacity)
            }

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

            if viewModel.isScanning && viewModel.scanKind == .points {
                scanTargetControls
            }

            Button {
                Haptics.impact(.medium); viewModel.isScanning ? viewModel.stopScan() : viewModel.startScan()
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

    private var scanTargetControls: some View {
        VStack(spacing: 8) {
            if viewModel.hasScanTarget {
                HStack {
                    StatusBadge(text: String(format: "Target · %.1f m", viewModel.scanTargetRadius),
                                systemImage: "scope", tint: Theme.accent)
                    Spacer()
                    Button { Haptics.impact(.light); viewModel.clearScanTarget() } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                LabeledSlider(title: "Target radius", value: targetRadiusBinding,
                              range: 0.1...2.0, format: "%.1f", unit: " m")
            } else {
                Text("Tap your subject to scan just it — keeps the surroundings out.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button { Haptics.impact(.light); autoTargetRequest = true } label: {
                    Label("Auto-detect subject", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Theme.surface, in: Capsule())
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
        }
        .padding(.horizontal, 16)
    }

    private var targetRadiusBinding: Binding<Float> {
        Binding(get: { viewModel.scanTargetRadius },
                set: { viewModel.updateScanTargetRadius($0) })
    }

    /// Larger ROI radius → a larger clear focus circle (0.30…0.48 of the screen).
    private var roiClearFraction: CGFloat {
        let t = min(max(viewModel.scanTargetRadius / 2.0, 0), 1)
        return 0.30 + 0.18 * CGFloat(t)
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        StatusBadge(text: resultCountText, systemImage: resultIcon)
                        if let rd = rulerDistance {
                            StatusBadge(text: MeasurementFormat.distance(rd),
                                        systemImage: "ruler", tint: Theme.accent)
                        }
                        Spacer()
                        Button(role: .destructive) { viewModel.discard() } label: {
                            Label("New", systemImage: "arrow.counterclockwise")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .tint(.red)
                    }
                    HStack(spacing: 8) {
                        if let dims = viewModel.dimensionsText {
                            StatusBadge(text: dims, systemImage: "ruler", tint: Theme.accentWarm)
                        }
                        if let vol = viewModel.volumeText {
                            StatusBadge(text: vol, systemImage: "shippingbox", tint: Theme.accentWarm)
                        }
                    }
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
                Button("USDZ (points)") { viewModel.exportPointCloudUSDZ() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var reviewViewer: some View {
        if viewModel.capturedMesh != nil, let mesh = viewModel.effectiveMesh {
            MeshViewer(mesh: mesh, colorMode: viewModel.meshColorMode,
                       cameraMode: meshCameraMode, rulerEnabled: rulerEnabled,
                       autoOrbit: autoOrbit, preset: $pendingPreset, rulerDistance: $rulerDistance)
                .ignoresSafeArea()
        } else if let cloud = viewModel.capturedCloud {
            MetalPointCloudView(cloud: cloud,
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
                Button {
                    Haptics.impact(.medium); viewModel.reconstructMesh()
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isReconstructing {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "square.stack.3d.up.fill")
                        }
                        Text(viewModel.isReconstructing ? "Reconstructing…" : "Reconstruct surface")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.accentWarm, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isReconstructing)
                .padding(.horizontal, 16)

                Button {
                    Haptics.impact(.light); showMergeGallery = true
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isMergingBusy {
                            ProgressView().controlSize(.small).tint(Theme.textPrimary)
                        } else {
                            Image(systemName: "square.stack.3d.down.right")
                        }
                        Text(viewModel.isMergingBusy ? "Merging…" : "Merge a scan")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isMergingBusy)
                .padding(.horizontal, 16)

                Button { Haptics.impact(.light); viewModel.cleanUpCloud() } label: {
                    HStack(spacing: 8) {
                        if viewModel.isCleaning {
                            ProgressView().controlSize(.small).tint(Theme.textPrimary)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(viewModel.isCleaning ? "Cleaning…" : "Clean up (remove strays)")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCleaning)
                .padding(.horizontal, 16)

                Picker("Colour", selection: $vm.colorMode) {
                    ForEach(PointColorMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                LabeledSlider(title: "Point size", value: pointSizeBinding, range: 2...16, format: "%.0f")
                    .padding(.horizontal, 18)
            } else if viewModel.meshIsClassified {
                Picker("Shading", selection: $vm.meshColorMode) {
                    ForEach(MeshColorMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if viewModel.meshColorMode == .classification {
                    classificationLegend
                }
            }

            if viewModel.canRemoveStructure {
                Toggle(isOn: $vm.removeStructure) {
                    Label("Hide walls & floor", systemImage: "scissors")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .padding(.horizontal, 18)
            }

            if viewModel.capturedMesh != nil {
                Picker("Camera", selection: $meshCameraMode) {
                    ForEach(MeshCameraMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if meshCameraMode == .inside {
                    Text("Drag to look around · two-finger drag to move through the scan")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                Toggle(isOn: $rulerEnabled) {
                    Label(rulerEnabled ? "Tap two points to measure" : "3D ruler",
                          systemImage: "ruler")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .padding(.horizontal, 18)

                meshToolsRow
            }

            actionRow
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var meshToolsRow: some View {
        HStack(spacing: 10) {
            meshToolButton("Optimize", "wand.and.stars", busy: viewModel.isOptimizing) {
                viewModel.optimizeMesh()
            }
            meshToolButton("Reduce", "arrow.down.right.and.arrow.up.left", busy: viewModel.isDecimating) {
                viewModel.decimateMesh()
            }
            meshToolButton("Spin clip", "arrow.triangle.2.circlepath.camera", busy: viewModel.isExportingVideo) {
                viewModel.exportTurntable()
            }
            if viewModel.meshIsClassified {
                meshToolButton("Plan", "map", busy: false) { showFloorPlan = true }
            }
        }
        .padding(.horizontal, 16)
    }

    private func meshToolButton(_ title: String, _ icon: String, busy: Bool,
                                action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            VStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                } else {
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                }
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var classificationLegend: some View {
        let classes: [MeshClassification] = [.wall, .floor, .ceiling, .table, .seat, .window, .door]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(classes) { c in
                    HStack(spacing: 5) {
                        Circle().fill(Color(c.uiColor)).frame(width: 9, height: 9)
                        Text(c.label).font(.caption2.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
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
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .toggleStyle(.button)
            .tint(Theme.accent)

            if viewModel.hasResult {
                Button { Haptics.impact(.medium); viewModel.presentARQuickLook() } label: {
                    Image(systemName: "arkit")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View in AR")
            }

            Button { Haptics.impact(.light); viewModel.save() } label: {
                Label("Save", systemImage: "tray.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)

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
        if viewModel.capturedMesh != nil {
            return "\(viewModel.effectiveMesh?.triangleCount ?? viewModel.pointCount) tris"
        }
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
