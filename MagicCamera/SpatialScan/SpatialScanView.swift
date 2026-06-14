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
    @State private var showPlaceGallery = false
    @State private var autoTargetRequest = false
    @State private var meshCameraMode: MeshCameraMode = .orbit
    @State private var walkVector: CGSize = .zero
    @State private var walkThumb: CGSize = .zero
    @State private var walkSensitivity: Float = 1.2
    @State private var rulerEnabled = false
    @State private var rulerDistance: Float?
    @State private var showFloorPlan = false
    @State private var clipEnabled = false
    @State private var clipHeight: Float = .greatestFiniteMagnitude
    @State private var showReviewTools = false
    @State private var reviewTab: ReviewToolTab = .edit
    @State private var studioInput = ""
    @FocusState private var studioFieldFocused: Bool
    /// Drives the blocking processing overlay. Set on a short delay after an
    /// operation starts so quick edits don't flash a full-screen modal.
    @State private var showProcessingOverlay = false
    /// Expert reconstruction knobs (method/detail/prepass) stay tucked away by
    /// default so the review screen leads with the one-tap actions.
    @State private var showReconstructOptions = false

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
        .onAppear {
            // Home-screen gallery handoff: the pick is stashed on the router
            // because this view (and its model) didn't exist to receive it.
            if let pick = AppRouter.shared.consumeGalleryPick() {
                switch pick {
                case .cloud(let cloud):          viewModel.loadSaved(cloud)
                case .mesh(let mesh, let texed): viewModel.loadSavedMesh(mesh, textured: texed)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // The processing overlay sits on `content`, below the nav bar —
                // gate the gallery here so a saved scan can't be loaded over a
                // running operation.
                Button { showGallery = true } label: { Image(systemName: "folder") }
                    .disabled(viewModel.isBusy)
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
        .sheet(isPresented: $showPlaceGallery) {
            ScanGalleryView(onSelectCloud: { _ in },
                            onSelectMesh: { mesh, _ in viewModel.beginPlacement(mesh) },
                            mergeKind: .mesh)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.sceneReport != nil },
            set: { if !$0 { viewModel.sceneReport = nil } })) {
            if let report = viewModel.sceneReport {
                NavigationStack {
                    ScrollView {
                        Text(report)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                    .background(Theme.background)
                    .navigationTitle("Scan report")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { ShareLink(item: report) }
                    }
                }
                .presentationDetents([.medium, .large])
            }
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

    private var content: some View {
        Group {
            switch viewModel.phase {
            case .idle, .scanning, .finishing: scanningSurface
            case .reviewing:                   reviewSurface
            }
        }
        .overlay { processingOverlay }
        .onChange(of: viewModel.isBusy) { _, busy in
            guard busy else { showProcessingOverlay = false; return }
            // Only reveal the modal if the op is still running after a grace
            // period — sub-second edits never flash it. The delayed task only
            // re-checks `isBusy`, not which op: if a *different* op is running
            // by the time it fires, that's fine — the overlay reads the live
            // `activeOperation`/`operationStartedAt`, so it shows the current one.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if viewModel.isBusy { showProcessingOverlay = true }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showProcessingOverlay)
    }

    /// Blocking overlay for a running background operation: its name, a live
    /// elapsed-time readout (proof it isn't frozen) and a Cancel button wired to
    /// `cancelHeavyWork()` — every review op is cancellable now.
    @ViewBuilder
    private var processingOverlay: some View {
        if showProcessingOverlay, let op = viewModel.activeOperation {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(Theme.textPrimary)
                    Text(op.label)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if let started = viewModel.operationStartedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(Self.elapsedText(since: started, now: context.date))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Button {
                        Haptics.impact(.medium)
                        viewModel.cancelHeavyWork()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 28).padding(.vertical, 11)
                            .background(Theme.surface, in: Capsule())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityLabel("Cancel \(op.label)")
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(40)
            }
            .transition(.opacity)
        }
    }

    private static func elapsedText(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Scanning

    private var scanningSurface: some View {
        ZStack {
            ScanARView(viewModel: viewModel, autoTargetRequest: $autoTargetRequest)
                .ignoresSafeArea()

            if viewModel.isScanning && viewModel.hasScanTarget && viewModel.scanKind == .points
                && !viewModel.subjectMaskActive {
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
                    Picker("Quality", selection: $vm.captureQuality) {
                        ForEach(CaptureQuality.allCases) { q in Text(q.rawValue).tag(q) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    Text(viewModel.captureQuality.detailLine)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Text(viewModel.captureEstimateText)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)

                    if viewModel.captureQuality == .object {
                        objectModeControls
                    }
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

    /// Extra Object-mode controls (shown only when Object quality is selected):
    /// the Object+ fineness toggle and the capture-range slider.
    private var objectModeControls: some View {
        @Bindable var vm = viewModel
        return VStack(spacing: 8) {
            Toggle(isOn: $vm.objectFine) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Object+ (2 mm voxels)").font(.caption.weight(.semibold))
                    Text("Finest detail for coins & jewellery — more memory.")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
            LabeledSlider(title: "Range", value: $vm.objectRange,
                          range: 1.0...2.5, format: "%.1f", unit: " m")
        }
        .padding(.horizontal, 16)
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
                if viewModel.isPlacing {
                    placementControls
                } else if viewModel.isStudioActive {
                    studioControls
                } else {
                    reviewControls
                }
            }
            .padding(.vertical, 10)

            if viewModel.capturedMesh != nil && meshCameraMode == .walk && !viewModel.isPlacing {
                HStack {
                    walkJoystick.padding(.leading, 18)
                    Spacer()
                }
            }

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
                       autoOrbit: autoOrbit,
                       walkVector: walkVector,
                       walkSensitivity: walkSensitivity,
                       placementMesh: viewModel.placementMesh,
                       placementRotation: viewModel.placementRotation,
                       preset: $pendingPreset, rulerDistance: $rulerDistance,
                       placementPosition: Binding(
                           get: { viewModel.placementPosition },
                           set: { viewModel.placementPosition = $0 }))
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

    /// On-screen thumbstick for Walk mode: drag to move, release to stop.
    /// Sits at the screen's left edge so it never collides with the drawer.
    private var walkJoystick: some View {
        let radius: CGFloat = 44
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 110, height: 110)
            Circle()
                .fill(Theme.accent.opacity(0.85))
                .frame(width: 46, height: 46)
                .offset(walkThumb)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var dx = value.translation.width
                    var dy = value.translation.height
                    let length = max(hypot(dx, dy), 1)
                    if length > radius { dx *= radius / length; dy *= radius / length }
                    walkThumb = CGSize(width: dx, height: dy)
                    // Up on the stick = forward.
                    walkVector = CGSize(width: dx / radius, height: -dy / radius)
                }
                .onEnded { _ in
                    walkThumb = .zero
                    walkVector = .zero
                })
        .accessibilityLabel("Walk joystick")
    }

    /// Compact panel shown instead of the review tools while a scan is being
    /// placed: hint, rotation, and Place/Cancel.
    private var placementControls: some View {
        VStack(spacing: 12) {
            Text(viewModel.placementPosition == nil
                 ? "Tap the room where the scan should stand"
                 : "Tap again to move it · rotate below")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if viewModel.placementPosition != nil {
                LabeledSlider(title: "Rotation",
                              value: Binding(
                                get: { viewModel.placementRotation * 180 / .pi },
                                set: { viewModel.placementRotation = $0 * .pi / 180 }),
                              range: 0...360, format: "%.0f", unit: "°")
                    .padding(.horizontal, 18)
            }

            HStack(spacing: 12) {
                Button(role: .cancel) { viewModel.cancelPlacement() } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)

                Button { Haptics.impact(.medium); viewModel.applyPlacement() } label: {
                    HStack(spacing: 8) {
                        if viewModel.isRunning(.placing) {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "checkmark")
                        }
                        Text("Place")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.placementPosition == nil || viewModel.isBusy)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
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

            HStack(spacing: 0) {
                toolsToggle
                studioButton
            }
            actionRow
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Entry into Studio mode — swaps the review panel for the chat panel.
    private var studioButton: some View {
        Button {
            Haptics.impact(.light)
            viewModel.isStudioActive = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Studio")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.accent.opacity(0.18), in: Capsule())
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .accessibilityLabel("Open Studio")
    }

    // MARK: - Studio panel

    /// Chat panel shown instead of the review tools: transcript, input and a
    /// one-tap undo of the last command. When the on-device model is not
    /// available the panel explains itself instead of showing the input.
    private var studioControls: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Studio", systemImage: "sparkles")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if viewModel.hasAutoFixBackup {
                    Button { Haptics.impact(.light); viewModel.undoAutoFix() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surface, in: Capsule())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy || viewModel.isStudioBusy)
                }
                Button { viewModel.closeStudio() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Studio")
            }
            .padding(.horizontal, 16)

            if StudioEngine.isAvailable {
                if viewModel.studioTranscript.isEmpty {
                    Text("Describe an edit in one sentence — Studio runs the right tools.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                } else {
                    studioTranscriptView
                }

                if viewModel.isStudioBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Theme.textPrimary)
                        Text(viewModel.isBusy ? "Running tools…" : "Thinking…")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                HStack(spacing: 8) {
                    TextField("e.g. isolate the mug, smooth it and texture it",
                              text: $studioInput, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.subheadline)
                        .focused($studioFieldFocused)
                        .onSubmit(sendStudioCommand)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                        .foregroundStyle(Theme.textPrimary)
                    Button(action: sendStudioCommand) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSendStudio ? Theme.accent : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSendStudio)
                    .accessibilityLabel("Send to Studio")
                }
                .padding(.horizontal, 16)
            } else {
                Text(StudioEngine.unavailableMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var canSendStudio: Bool {
        !studioInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isStudioBusy && !viewModel.isBusy && !viewModel.isAutoFixing
    }

    private func sendStudioCommand() {
        guard canSendStudio else { return }
        Haptics.impact(.light)
        viewModel.runStudioCommand(studioInput)
        studioInput = ""
    }

    private var studioTranscriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(viewModel.studioTranscript) { line in
                        HStack {
                            if line.role == .user { Spacer(minLength: 40) }
                            Text(line.text)
                                .font(.footnote)
                                .foregroundStyle(line.role == .user ? AnyShapeStyle(Color.black)
                                                                    : AnyShapeStyle(Theme.textPrimary))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(line.role == .user ? AnyShapeStyle(Theme.accent)
                                                               : AnyShapeStyle(Theme.surface),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .textSelection(.enabled)
                            if line.role == .assistant { Spacer(minLength: 40) }
                        }
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 220)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: viewModel.studioTranscript) { _, lines in
                guard let last = lines.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
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

    /// The reconstruction cluster (one-tap model, an options disclosure, manual
    /// reconstruct), extracted into its own `View`. The review-tools tree builds
    /// one enormous nested generic type; inlining this much here (with nested
    /// `if`s) pushed the Swift runtime's type-metadata instantiation into a stack
    /// overflow on the Edit tab. A nominal sub-view truncates that type tree.
    private struct ReconstructionControls: View {
        @Bindable var viewModel: SpatialScanViewModel
        @Binding var showOptions: Bool

        var body: some View {
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

                Button {
                    Haptics.impact(.light)
                    withAnimation(.easeInOut(duration: 0.2)) { showOptions.toggle() }
                } label: {
                    HStack {
                        Text("Reconstruction options")
                        Spacer()
                        Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showOptions ? "Hide reconstruction options" : "Show reconstruction options")

                if showOptions { reconstructionOptions }

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
            }
        }

        @ViewBuilder
        private var reconstructionOptions: some View {
            Picker("Method", selection: $viewModel.reconstructMethod) {
                ForEach(ReconstructionMethod.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            Text(viewModel.reconstructMethod.hint)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)

            if viewModel.reconstructMethod != .ballPivot {
                Picker("Detail", selection: $viewModel.reconstructDetail) {
                    ForEach(MeshDetail.allCases) { d in Text(d.rawValue).tag(d) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }

            if let estimate = viewModel.reconstructionEstimateText {
                Text(estimate)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
            }

            Toggle(isOn: $viewModel.adaptiveDensityPrepass) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adaptive density").font(.subheadline.weight(.semibold))
                    Text("Thin flat areas first — more detail per triangle.")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var cloudEditTools: some View {
        VStack(spacing: 12) {
            ReconstructionControls(viewModel: viewModel, showOptions: $showReconstructOptions)

            cloudToolButton("Merge a scan", busyTitle: "Merging…",
                            icon: "square.stack.3d.down.right",
                            busy: viewModel.isRunning(.merging)) { showMergeGallery = true }
            cloudToolButton("Clean up (remove strays)", busyTitle: "Cleaning…",
                            icon: "sparkles",
                            busy: viewModel.isRunning(.cleaning)) { viewModel.cleanUpCloud() }
            cloudToolButton("Matte filter (cut reflections)", busyTitle: "Filtering…",
                            icon: "rays",
                            busy: viewModel.isRunning(.cleaning)) { viewModel.removeUnreliablePoints() }
            cloudToolButton("Adaptive density (thin flat areas)", busyTitle: "Thinning…",
                            icon: "circle.grid.cross",
                            busy: viewModel.isRunning(.cleaning)) { viewModel.adaptiveDownsampleCloud() }
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

            cloudToolButton("Auto-fix (plans the steps)", busyTitle: "Auto-fixing…",
                            icon: "wand.and.sparkles",
                            busy: viewModel.isAutoFixing) { viewModel.autoFix() }
            cloudToolButton("Describe scan", busyTitle: "Describing…",
                            icon: "text.bubble",
                            busy: viewModel.isDescribing) { viewModel.describeScan() }
            if viewModel.hasAutoFixBackup {
                cloudToolButton("Undo auto-fix", busyTitle: "…",
                                icon: "arrow.uturn.backward",
                                busy: false) { viewModel.undoAutoFix() }
            }
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

            if meshCameraMode == .walk {
                Text("Joystick moves you · drag the view to look around")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                LabeledSlider(title: "Sensitivity", value: $walkSensitivity,
                              range: 0.3...3.5, format: "%.1f", unit: "×")
                    .padding(.horizontal, 18)
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
        .disabled(viewModel.isBusy || (viewModel.isAutoFixing && !busy))
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
        // Adaptive grid instead of one cramped row: with up to eight tools the
        // single HStack squeezed every button to sliver width on phones.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            meshToolButton("Optimize", "wand.and.stars", busy: viewModel.isRunning(.optimizing)) {
                viewModel.optimizeMesh()
            }
            meshToolButton("Fill holes", "bandage", busy: viewModel.isRunning(.fillingHoles)) {
                viewModel.fillHoles()
            }
            meshToolButton("Close base", "square.bottomhalf.filled", busy: viewModel.isRunning(.fillingHoles)) {
                viewModel.closeBase()
            }
            meshToolButton("Merge", "square.stack.3d.down.right", busy: viewModel.isRunning(.merging)) {
                showMeshMergeGallery = true
            }
            meshToolButton("Place", "plus.square.on.square", busy: viewModel.isRunning(.placing)) {
                showPlaceGallery = true
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
            meshToolButton("Auto-fix", "wand.and.sparkles", busy: viewModel.isAutoFixing) {
                viewModel.autoFix()
            }
            meshToolButton("Describe", "text.bubble", busy: viewModel.isDescribing) {
                viewModel.describeScan()
            }
            if viewModel.hasAutoFixBackup {
                meshToolButton("Undo fix", "arrow.uturn.backward", busy: false) {
                    viewModel.undoAutoFix()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func meshToolButton(_ title: String, _ icon: String, busy: Bool,
                                action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            VStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                } else {
                    Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy || (viewModel.isAutoFixing && !busy))
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
