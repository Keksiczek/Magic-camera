//
//  SpatialScanView.swift
//  Magic Camera
//
//  Mode 2 UI: choose point-cloud or mesh scanning (+ quality), scan with a live
//  overlay, then review the result with camera presets, colour modes, point
//  size, save and export. Saved scans are reachable from the toolbar.
//

import SwiftUI

/// Tabs of the review-tools drawer: processing actions vs display options.
enum ReviewToolTab: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case view = "View"
    var id: String { rawValue }
}

struct SpatialScanView: View {
    @State private var viewModel = SpatialScanViewModel()
    @State private var autoOrbit = false
    @State private var pendingPreset: CameraPreset?
    @State private var showExport = false
    @State private var showGallery = false
    @State private var showMergeGallery = false
    @State private var showMeshMergeGallery = false
    @State private var autoTargetRequest = false
    @State private var meshCameraMode: MeshCameraMode = .orbit
    @State private var rulerEnabled = false
    @State private var rulerDistance: Float?
    @State private var showFloorPlan = false
    @State private var clipEnabled = false
    @State private var clipHeight: Float = .greatestFiniteMagnitude
    @State private var showReviewTools = false
    @State private var reviewTab: ReviewToolTab = .edit

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
                            onSelectMesh: { viewModel.loadSavedMesh($0, textured: $1) })
        }
        .alert("Recover unsaved scan?", isPresented: Binding(
            get: { viewModel.pendingRecovery != nil },
            set: { if !$0 { viewModel.pendingRecovery = nil } })) {
            Button("Restore") { viewModel.restoreAutosave() }
            Button("Delete", role: .destructive) { viewModel.discardAutosave() }
        } message: {
            Text("A scan from a previous session wasn't saved — it was recovered automatically.")
        }
        .sheet(isPresented: $showMergeGallery) {
            ScanGalleryView(onSelectCloud: { viewModel.mergeSavedCloud($0) },
                            onSelectMesh: { _, _ in }, mergeKind: .points)
        }
        .sheet(isPresented: $showMeshMergeGallery) {
            ScanGalleryView(onSelectCloud: { _ in },
                            onSelectMesh: { mesh, _ in viewModel.mergeSavedMesh(mesh) },
                            mergeKind: .mesh)
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
        case .idle, .scanning, .finishing: scanningSurface
        case .reviewing:                   reviewSurface
        }
    }

    // MARK: - Scanning

    private var scanningSurface: some View {
        ZStack {
            ScanARView(viewModel: viewModel, autoTargetRequest: $autoTargetRequest)
                .ignoresSafeArea()

            if viewModel.isScanning && viewModel.hasScanTarget && viewModel.scanKind == .points {
                ROIFocusOverlay(clearFraction: roiClearFraction,
                                circle: viewModel.roiScreenCircle)
                    .transition(.opacity)
                    .animation(.linear(duration: 0.1), value: viewModel.roiScreenCircle)
            }

            VStack {
                // Compact, stable-width badges: the texts are short and digits
                // monospaced so the row never overflows and re-wraps as the
                // live counters tick up (which used to read as flicker).
                HStack(spacing: 8) {
                    StatusBadge(text: scanStatusText,
                                systemImage: viewModel.scanKind.systemImage,
                                tint: Theme.accent)
                    if viewModel.isScanning && viewModel.scanKind == .points {
                        if viewModel.scanConfidence > 0 {
                            StatusBadge(text: scanQualityLabel,
                                        systemImage: "waveform",
                                        tint: scanQualityColor)
                        }
                        if viewModel.scanCoverage > 0 {
                            StatusBadge(text: "\(Int(viewModel.scanCoverage * 100))%",
                                        systemImage: "circle.dashed.inset.filled",
                                        tint: scanCoverageColor)
                        }
                    }
                    Spacer()
                    if viewModel.isScanning { RecordingDot() }
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
            if viewModel.phase == .idle {
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

            if viewModel.isFinishing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.black)
                    Text("Finishing scan…").font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent,
                            in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
            } else {
                HStack(spacing: 10) {
                    if viewModel.isScanning {
                        Button {
                            Haptics.impact(.light); viewModel.restartScan()
                        } label: {
                            Label("Start over", systemImage: "arrow.counterclockwise")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.surface,
                                            in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .buttonStyle(.plain)
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
                }
                .padding(.horizontal, 16)
            }
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

    /// World-Y extent of the current mesh, for the cross-section slider.
    private var meshYRange: ClosedRange<Float>? {
        guard let box = viewModel.effectiveMesh?.boundingBox() else { return nil }
        return box.max.y > box.min.y ? box.min.y...box.max.y : nil
    }

    /// Enabling the cross-section starts with the cut at the top (nothing hidden).
    private var clipToggleBinding: Binding<Bool> {
        Binding(get: { clipEnabled }, set: { on in
            clipEnabled = on
            if on, let range = meshYRange { clipHeight = range.upperBound }
        })
    }

    private var availableKinds: [ScanKind] {
        viewModel.supportsMesh ? ScanKind.allCases : [.points]
    }

    private var scanStatusText: String {
        if viewModel.scanKind == .mesh {
            return viewModel.isScanning || viewModel.isFinishing
                ? "\(MeasurementFormat.count(viewModel.pointCount)) tris"
                : "Mesh"
        }
        return "\(MeasurementFormat.count(viewModel.pointCount)) pts"
    }

    private var scanQualityLabel: String {
        switch viewModel.scanConfidence {
        case 0.66...: return "Strong"
        case 0.33...: return "Fair"
        default:      return "Weak"
        }
    }

    private var scanQualityColor: Color {
        switch viewModel.scanConfidence {
        case 0.66...: return .green
        case 0.33...: return Color(red: 1, green: 0.75, blue: 0)
        default:      return .orange
        }
    }

    /// Green once the visible area is largely captured, easing through amber as it
    /// fills in — a cue that it's time to move on or finish.
    private var scanCoverageColor: Color {
        switch viewModel.scanCoverage {
        case 0.75...: return .green
        case 0.4...:  return Color(red: 1, green: 0.75, blue: 0)
        default:      return Theme.accent
        }
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
                        .disabled(viewModel.isBusy)
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
                if viewModel.texturedMesh != nil {
                    ForEach(TexturedMeshExporter.Format.allCases) { format in
                        Button(format.rawValue) { viewModel.exportTextured(format: format) }
                    }
                }
                ForEach(MeshExporter.Format.allCases) { format in
                    Button(format.rawValue) { viewModel.exportMesh(format: format) }
                }
            } else {
                ForEach(PointCloudExporter.Format.allCases) { format in
                    Button(format.rawValue) { viewModel.exportPointCloud(format: format) }
                }
                Button("USDZ (points)") { viewModel.exportPointCloudUSDZ() }
            }
            Button("Web viewer (HTML)") { viewModel.exportWebViewer() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var reviewViewer: some View {
        if viewModel.capturedMesh != nil, let mesh = viewModel.effectiveMesh {
            MeshViewer(mesh: mesh,
                       textured: viewModel.removeStructure ? nil : viewModel.texturedMesh,
                       colorMode: viewModel.meshColorMode,
                       cameraMode: meshCameraMode, rulerEnabled: rulerEnabled,
                       clipEnabled: clipEnabled, clipHeight: clipHeight,
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
        VStack(spacing: 10) {
            presetRow

            if showReviewTools {
                ScrollView {
                    reviewTools
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                }
                .frame(maxHeight: 300)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            toolsToggle
            actionRow
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// The collapsible drawer of review controls, split into Edit (processing
    /// actions) and View (display & camera) tabs so the drawer stays short.
    /// Scrolls when it overflows.
    @ViewBuilder
    private var reviewTools: some View {
        VStack(spacing: 12) {
            Picker("Tools", selection: $reviewTab) {
                ForEach(ReviewToolTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if viewModel.capturedMesh == nil {
                if reviewTab == .edit { cloudEditTools } else { cloudViewTools }
            } else {
                if reviewTab == .edit { meshEditTools } else { meshViewTools }
            }
        }
    }

    // MARK: Cloud tabs

    @ViewBuilder
    private var cloudEditTools: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 12) {
            Button {
                Haptics.impact(.medium); viewModel.makeQuickModel()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isRunning(.makingModel) {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(viewModel.isRunning(.makingModel) ? "Making model…" : "Make 3D model")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .padding(.horizontal, 16)

            Text("Isolates the subject, builds a smooth surface and bakes the texture in one go.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Picker("Method", selection: $vm.reconstructMethod) {
                ForEach(ReconstructionMethod.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            Text(viewModel.reconstructMethod.hint)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)

            if viewModel.reconstructMethod != .ballPivot {
                Picker("Detail", selection: $vm.reconstructDetail) {
                    ForEach(MeshDetail.allCases) { d in Text(d.rawValue).tag(d) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }

            Button {
                Haptics.impact(.medium); viewModel.reconstructMesh()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isRunning(.reconstructing) {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "square.stack.3d.up.fill")
                    }
                    Text(viewModel.isRunning(.reconstructing) ? "Reconstructing…" : "Reconstruct surface")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.accentWarm, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .padding(.horizontal, 16)

            cloudToolButton("Merge a scan", busyTitle: "Merging…",
                            icon: "square.stack.3d.down.right",
                            busy: viewModel.isRunning(.merging)) { showMergeGallery = true }
            cloudToolButton("Clean up (remove strays)", busyTitle: "Cleaning…",
                            icon: "sparkles",
                            busy: viewModel.isRunning(.cleaning)) { viewModel.cleanUpCloud() }
            cloudToolButton("Isolate object (cut floor)", busyTitle: "Isolating…",
                            icon: "person.crop.square.filled.and.at.rectangle",
                            busy: viewModel.isRunning(.isolating)) { viewModel.isolateSubject() }

            Button { Haptics.impact(.light); viewModel.estimateCloudNormals() } label: {
                let hasNormals = viewModel.capturedCloudNormals != nil
                HStack(spacing: 8) {
                    if viewModel.isRunning(.estimatingNormals) {
                        ProgressView().controlSize(.small).tint(Theme.textPrimary)
                    } else {
                        Image(systemName: hasNormals ? "checkmark.circle.fill" : "line.3.crossed.swirl.circle")
                    }
                    Text(viewModel.isRunning(.estimatingNormals) ? "Estimating normals…"
                         : hasNormals ? "Normals ready (PLY)" : "Estimate normals")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy || viewModel.capturedCloudNormals != nil)
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var cloudViewTools: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 12) {
            Picker("Colour", selection: $vm.colorMode) {
                ForEach(PointColorMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            LabeledSlider(title: "Point size", value: pointSizeBinding, range: 2...16, format: "%.0f")
                .padding(.horizontal, 18)
        }
    }

    // MARK: Mesh tabs

    @ViewBuilder
    private var meshEditTools: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 12) {
            if viewModel.canRemoveStructure {
                Toggle(isOn: $vm.removeStructure) {
                    Label("Hide walls & floor", systemImage: "scissors")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .padding(.horizontal, 18)
            }
            meshToolsRow
        }
    }

    @ViewBuilder
    private var meshViewTools: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 12) {
            Picker("Shading", selection: $vm.meshColorMode) {
                ForEach(MeshColorMode.available(classified: viewModel.meshIsClassified)) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if viewModel.meshColorMode == .classification {
                classificationLegend
            }

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

            Toggle(isOn: clipToggleBinding) {
                Label("Cross-section", systemImage: "scissors.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 18)

            if clipEnabled, let range = meshYRange {
                LabeledSlider(title: "Cut height", value: $clipHeight,
                              range: range, format: "%.2f", unit: " m")
                    .padding(.horizontal, 18)
            }
        }
    }

    /// Full-width secondary action button with a busy spinner.
    private func cloudToolButton(_ title: String, busyTitle: String, icon: String,
                                 busy: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                } else {
                    Image(systemName: icon)
                }
                Text(busy ? busyTitle : title)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
        .padding(.horizontal, 16)
    }

    /// Chevron handle that opens / closes the edit-tools drawer.
    private var toolsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { showReviewTools.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                Text(showReviewTools ? "Hide tools" : toolsLabel)
                Spacer()
                Image(systemName: showReviewTools ? "chevron.down" : "chevron.up")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var toolsLabel: String {
        viewModel.capturedMesh != nil ? "Edit & view mesh" : "Edit & view cloud"
    }

    private var meshToolsRow: some View {
        HStack(spacing: 10) {
            meshToolButton("Optimize", "wand.and.stars", busy: viewModel.isRunning(.optimizing)) {
                viewModel.optimizeMesh()
            }
            meshToolButton("Fill holes", "bandage", busy: viewModel.isRunning(.fillingHoles)) {
                viewModel.fillHoles()
            }
            meshToolButton("Merge", "square.stack.3d.down.right", busy: viewModel.isRunning(.merging)) {
                showMeshMergeGallery = true
            }
            meshToolButton("Reduce", "arrow.down.right.and.arrow.up.left", busy: viewModel.isRunning(.decimating)) {
                viewModel.decimateMesh()
            }
            meshToolButton("Spin clip", "arrow.triangle.2.circlepath.camera", busy: viewModel.isRunning(.exportingVideo)) {
                viewModel.exportTurntable()
            }
            if viewModel.canBakeTexture {
                meshToolButton(viewModel.texturedMesh != nil ? "Textured ✓" : "Texture",
                               "paintpalette", busy: viewModel.isRunning(.bakingTexture)) {
                    viewModel.bakeTexture()
                }
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
        .disabled(viewModel.isBusy)
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
