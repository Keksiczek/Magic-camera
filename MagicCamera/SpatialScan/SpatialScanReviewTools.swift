//
//  SpatialScanReviewTools.swift
//  Magic Camera
//
//  The review-tools drawer, split into nominal `View` structs.
//
//  Why this is its own file of structs rather than computed `some View`
//  properties on `SpatialScanView`: SwiftUI composes computed `some View`
//  properties into one giant opaque type. Once the cloud/mesh × edit/view tool
//  tree (plus crop, mirror, lasso, reconstruction) all expanded inline, the
//  combined mangled type name grew deep enough that the Swift runtime's
//  type-metadata demangler overflowed its stack while instantiating
//  `reviewControls` — the app crashed the moment you entered scan review.
//
//  A nominal `struct ... : View` is a truncation boundary: its body is a
//  separate, shallower mangled name resolved on demand, so the parent's type
//  tree stays shallow. Every heavy sub-tree below lives in its own struct for
//  exactly that reason. See commit 12320b4 (ReconstructionControls) for the
//  first instance of this fix.
//

import SwiftUI

// MARK: - Drawer

/// The collapsible drawer of review controls, split into Edit (processing
/// actions) and View (display & camera) tabs so the drawer stays short. The
/// tab bodies are nominal structs to keep the type tree shallow.
struct ReviewToolsDrawer: View {
    let viewModel: SpatialScanViewModel
    @Binding var reviewTab: ReviewToolTab
    @Binding var showReconstructOptions: Bool
    @Binding var showMergeGallery: Bool
    @Binding var showMeshMergeGallery: Bool
    @Binding var showPlaceGallery: Bool
    @Binding var showFloorPlan: Bool
    @Binding var cropEnabled: Bool
    @Binding var cropTrim: [Float]
    @Binding var lassoEnabled: Bool
    @Binding var lassoKeepInside: Bool
    @Binding var meshCameraMode: MeshCameraMode
    @Binding var walkSensitivity: Float
    @Binding var rulerEnabled: Bool
    @Binding var clipEnabled: Bool
    @Binding var clipHeight: Float

    var body: some View {
        VStack(spacing: 12) {
            Picker("Tools", selection: $reviewTab) {
                ForEach(ReviewToolTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if viewModel.capturedMesh == nil {
                if reviewTab == .edit {
                    CloudEditTools(viewModel: viewModel,
                                   showReconstructOptions: $showReconstructOptions,
                                   showMergeGallery: $showMergeGallery,
                                   cropEnabled: $cropEnabled, cropTrim: $cropTrim)
                } else {
                    CloudViewTools(viewModel: viewModel,
                                   lassoEnabled: $lassoEnabled,
                                   lassoKeepInside: $lassoKeepInside)
                }
            } else {
                if reviewTab == .edit {
                    MeshEditTools(viewModel: viewModel,
                                  showMeshMergeGallery: $showMeshMergeGallery,
                                  showPlaceGallery: $showPlaceGallery,
                                  showFloorPlan: $showFloorPlan,
                                  cropEnabled: $cropEnabled, cropTrim: $cropTrim)
                } else {
                    MeshViewTools(viewModel: viewModel,
                                  meshCameraMode: $meshCameraMode,
                                  walkSensitivity: $walkSensitivity,
                                  rulerEnabled: $rulerEnabled,
                                  clipEnabled: $clipEnabled,
                                  clipHeight: $clipHeight)
                }
            }
        }
    }
}

/// Small uppercase section label that groups the review tools by workflow stage,
/// so the drawer reads as Clean up → Assemble → Assist instead of one
/// undifferentiated stack — directly addressing "the buttons don't make sense".
struct ToolSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.7)
            Spacer()
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }
}

/// Collapsed-by-default gateway to the manual tweak tools. The primary actions
/// answer most sessions; the grid of fifteen manual buttons was the main source
/// of "too many knobs" — present but quiet until asked for.
struct ManualToolsToggle: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack {
                Label("Manual tools", systemImage: "slider.horizontal.3")
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide manual tools" : "Show manual tools")
    }
}

// MARK: - Reconstruction

/// The reconstruction cluster (one-tap model, an options disclosure, manual
/// reconstruct). A nominal sub-view truncates the otherwise huge nested generic
/// type built by the Edit tab.
struct ReconstructionControls: View {
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
                Haptics.impact(.medium); viewModel.makeQuickModel(surface: true)
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isRunning(.makingSurface) {
                        ProgressView().controlSize(.small).tint(Theme.textPrimary)
                    } else {
                        Image(systemName: "paintpalette")
                    }
                    Text(viewModel.isRunning(.makingSurface) ? "Building surface…" : "Textured surface")
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

            Text("Open textured surface, kept as-is — no isolating or closing. For rooms, walls, façades, outdoors.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            // Two primary paths above (object model / textured surface) map to the
            // two scan profiles; the method pickers and manual reconstruct live
            // behind one disclosure so the first screen asks ONE question, not five.
            Button {
                Haptics.impact(.light)
                withAnimation(.easeInOut(duration: 0.2)) { showOptions.toggle() }
            } label: {
                HStack {
                    Text("Advanced reconstruction")
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

        }
    }

    @ViewBuilder
    private var reconstructionOptions: some View {
        Picker("Method", selection: $viewModel.reconstructMethod) {
            // `.available`, not `.allCases`: photogrammetry needs hardware
            // support and is absent from the simulator SDK, so on a device that
            // can't run it the option is not offered rather than shown failing.
            ForEach(ReconstructionMethod.available) { m in Text(m.rawValue).tag(m) }
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

            // One tap straight to a finished model: reconstruct the surface, then
            // run the same scene-aware Smart finish the mesh review offers — the
            // finish action the user wanted here too, not only after reconstructing.
            Button {
                Haptics.impact(.medium); viewModel.reconstructMesh(thenFinish: true)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Smart finish")
                        Text("Reconstruct & complete in one tap")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10).padding(.horizontal, 14)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .padding(.horizontal, 16)
    }
}

// MARK: - Cloud tabs

struct CloudEditTools: View {
    let viewModel: SpatialScanViewModel
    @Binding var showReconstructOptions: Bool
    @Binding var showMergeGallery: Bool
    @Binding var cropEnabled: Bool
    @Binding var cropTrim: [Float]
    @State private var showManualTools = false

    var body: some View {
        VStack(spacing: 12) {
            // Hero: the one-tap path most users want, plus manual reconstruct.
            ReconstructionControls(viewModel: viewModel, showOptions: $showReconstructOptions)

            ManualToolsToggle(isExpanded: $showManualTools)
            if showManualTools { manualTools }
        }
    }

    /// The full tweak surface — hidden until asked for, unchanged in content.
    @ViewBuilder
    private var manualTools: some View {
            // Clean up: refine the raw cloud (isolate the subject, drop strays /
            // reflections, thin flat areas) before a manual reconstruct.
            ToolSectionHeader("Clean up")
            cloudToolButton("Isolate object (cut floor)", busyTitle: "Isolating…",
                            icon: "person.crop.square.filled.and.at.rectangle",
                            busy: viewModel.isRunning(.isolating)) { viewModel.isolateSubject() }
            cloudToolButton("Clean up (remove strays)", busyTitle: "Cleaning…",
                            icon: "sparkles",
                            busy: viewModel.isRunning(.cleaning)) { viewModel.cleanUpCloud() }
            cloudToolButton("Matte filter (cut reflections)", busyTitle: "Filtering…",
                            icon: "rays",
                            busy: viewModel.isRunning(.filteringReflections)) { viewModel.removeUnreliablePoints() }
            cloudToolButton("Adaptive density (thin flat areas)", busyTitle: "Thinning…",
                            icon: "circle.grid.cross",
                            busy: viewModel.isRunning(.thinning)) { viewModel.adaptiveDownsampleCloud() }

            // Assemble: combine, crop or mirror the cloud.
            ToolSectionHeader("Assemble")
            cloudToolButton("Merge a scan", busyTitle: "Merging…",
                            icon: "square.stack.3d.down.right",
                            busy: viewModel.isRunning(.merging)) { showMergeGallery = true }
            CropToolsView(viewModel: viewModel, cropEnabled: $cropEnabled, cropTrim: $cropTrim)
            MirrorControlsView(viewModel: viewModel)

            // Assist: AI helpers and the PLY-export normals step.
            ToolSectionHeader("Assist")
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
            normalsButton
    }

    private var normalsButton: some View {
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

    private func cloudToolButton(_ title: String, busyTitle: String, icon: String,
                                 busy: Bool, action: @escaping () -> Void) -> CloudToolButton {
        CloudToolButton(viewModel: viewModel, title: title, busyTitle: busyTitle,
                        icon: icon, busy: busy, action: action)
    }
}

struct CloudViewTools: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var lassoEnabled: Bool
    @Binding var lassoKeepInside: Bool

    var body: some View {
        VStack(spacing: 12) {
            Picker("Colour", selection: $viewModel.colorMode) {
                ForEach(PointColorMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            LabeledSlider(title: "Point size", value: pointSizeBinding, range: 2...16, format: "%.0f")
                .padding(.horizontal, 18)

            lassoTools
        }
    }

    private var pointSizeBinding: Binding<Float> {
        Binding(get: { Float(viewModel.pointSize) },
                set: { viewModel.pointSize = CGFloat($0) })
    }

    /// Freeform lasso selection over the point cloud (one finger draws the loop).
    private var lassoTools: some View {
        VStack(spacing: 8) {
            Toggle(isOn: $lassoEnabled) {
                Label("Lasso select", systemImage: "lasso")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 18)
            if lassoEnabled {
                Picker("Lasso", selection: $lassoKeepInside) {
                    Text("Keep inside").tag(true)
                    Text("Delete inside").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                Text("Draw a loop around points with one finger · two fingers still move the camera.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - Mesh tabs

struct MeshEditTools: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var showMeshMergeGallery: Bool
    @Binding var showPlaceGallery: Bool
    @Binding var showFloorPlan: Bool
    @Binding var cropEnabled: Bool
    @Binding var cropTrim: [Float]
    @State private var showManualTools = false

    var body: some View {
        VStack(spacing: 12) {
            if viewModel.canRemoveStructure {
                Toggle(isOn: $viewModel.removeStructure) {
                    Label("Hide walls & floor", systemImage: "scissors")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .padding(.horizontal, 18)
            }
            // Hero: one scene-aware tap that does the logical finish; the manual
            // grid stays a tap away so the common case reads as one decision.
            smartFinishButton
            ManualToolsToggle(isExpanded: $showManualTools)
            if showManualTools {
                MeshToolGroups(viewModel: viewModel,
                               showMeshMergeGallery: $showMeshMergeGallery,
                               showPlaceGallery: $showPlaceGallery,
                               showFloorPlan: $showFloorPlan)
                CropToolsView(viewModel: viewModel, cropEnabled: $cropEnabled, cropTrim: $cropTrim)
                MirrorControlsView(viewModel: viewModel)
            }
        }
    }

    /// Scene-aware one-tap finish — lifts an object off its support + closes +
    /// fills, or cleans an open surface (flatten walls, denoise, adaptive density),
    /// then smooths. The obvious primary action; the tools below are manual tweaks.
    private var smartFinishButton: some View {
        MeshFinishHeroButton(viewModel: viewModel)
    }

}

/// The primary call-to-action in mesh review: a full-width accent-gradient card
/// that stands out from the subtle tool tiles beneath it, so the one obvious thing
/// to press reads as exactly that. One tap auto-finishes the scan.
struct MeshFinishHeroButton: View {
    let viewModel: SpatialScanViewModel

    var body: some View {
        let busy = viewModel.isRunning(.makingPrintable)
        Button { Haptics.impact(.medium); viewModel.smartFinish() } label: {
            HStack(spacing: 13) {
                ZStack {
                    if busy { ProgressView().controlSize(.regular).tint(.white) }
                    else { Image(systemName: "sparkles").font(.title3.weight(.bold)) }
                }
                .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(busy ? "Finishing…" : "Smart finish")
                        .font(.headline.weight(.bold))
                    Text("Clean & complete the model in one tap")
                        .font(.caption)
                        // 0.82 alpha on the accent fill measured ≈3.4:1 — under
                        // WCAG AA for small text. 0.95 clears it while still
                        // reading as secondary next to the bold headline.
                        .foregroundStyle(.white.opacity(0.95))
                }
                Spacer(minLength: 0)
                if !busy {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold)).opacity(0.7)
                }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 15).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(Theme.accentGradient,
                        in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.45), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy || viewModel.isAutoFixing)
        .opacity(viewModel.isBusy && !busy ? 0.5 : 1)
        .padding(.horizontal, 16)
    }
}

/// The mesh edit actions, grouped by workflow stage into labeled mini-grids so
/// the dozen tools read as Finish / Texture & export / Assemble / Assist instead
/// of one undifferentiated grid. A nominal struct (its own truncation boundary)
/// keeps the SwiftUI type tree shallow — see this file's header note.
struct MeshToolGroups: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var showMeshMergeGallery: Bool
    @Binding var showPlaceGallery: Bool
    @Binding var showFloorPlan: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Finish: repair and tidy the surface geometry.
            ToolSectionHeader("Finish")
            grid {
                meshToolButton("Fill holes", "bandage", busy: viewModel.isRunning(.fillingHoles)) {
                    viewModel.fillHoles()
                }
                meshToolButton("Close base", "square.bottomhalf.filled", busy: viewModel.isRunning(.closingBase)) {
                    viewModel.closeBase()
                }
                meshToolButton("Remove base", "square.tophalf.filled", busy: viewModel.isRunning(.removingBase)) {
                    viewModel.removeBasePlane()
                }
                meshToolButton("Optimize", "wand.and.stars", busy: viewModel.isRunning(.optimizing)) {
                    viewModel.optimizeMesh()
                }
                meshToolButton("Reduce", "arrow.down.right.and.arrow.up.left", busy: viewModel.isRunning(.decimating)) {
                    viewModel.decimateMesh()
                }
            }

            // Texture & export: colour the mesh, render a clip, read a floor plan.
            ToolSectionHeader("Texture & export")
            grid {
                if viewModel.canBakeTexture {
                    meshToolButton(viewModel.texturedMesh != nil ? "Textured ✓" : "Texture",
                                   "paintpalette", busy: viewModel.isRunning(.bakingTexture)) {
                        viewModel.bakeTexture()
                    }
                }
                meshToolButton("Spin clip", "arrow.triangle.2.circlepath.camera", busy: viewModel.isRunning(.exportingVideo)) {
                    viewModel.exportTurntable()
                }
                if viewModel.meshIsClassified {
                    meshToolButton("Plan", "map", busy: false) { showFloorPlan = true }
                }
            }

            // Assemble: bring other scans into this one.
            ToolSectionHeader("Assemble")
            grid {
                meshToolButton("Merge", "square.stack.3d.down.right", busy: viewModel.isRunning(.merging)) {
                    showMeshMergeGallery = true
                }
                meshToolButton("Place", "plus.square.on.square", busy: viewModel.isRunning(.placing)) {
                    showPlaceGallery = true
                }
            }

            // Assist: AI helpers.
            ToolSectionHeader("Assist")
            grid {
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
        }
    }

    /// Adaptive grid wrapper — tools wrap to as many columns as fit (sliver-width
    /// buttons on phones were the reason this isn't one HStack).
    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8, content: content)
            .padding(.horizontal, 16)
    }

    private func meshToolButton(_ title: String, _ icon: String, busy: Bool,
                                action: @escaping () -> Void) -> MeshToolButton {
        MeshToolButton(viewModel: viewModel, title: title, icon: icon, busy: busy, action: action)
    }
}

struct MeshViewTools: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var meshCameraMode: MeshCameraMode
    @Binding var walkSensitivity: Float
    @Binding var rulerEnabled: Bool
    @Binding var clipEnabled: Bool
    @Binding var clipHeight: Float

    var body: some View {
        VStack(spacing: 12) {
            Picker("Shading", selection: $viewModel.meshColorMode) {
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
}

// MARK: - Shared tools

/// Reflect-and-merge across a centre plane — completes a one-sided scan.
struct MirrorControlsView: View {
    let viewModel: SpatialScanViewModel

    var body: some View {
        VStack(spacing: 6) {
            toolSectionHeader("Mirror / symmetry")
            HStack(spacing: 8) {
                mirrorButton("Left–Right", axis: 0)
                mirrorButton("Up–Down", axis: 1)
                mirrorButton("Front–Back", axis: 2)
            }
            .padding(.horizontal, 16)
            Text("Reflects across the centre and merges. Crop to the symmetry plane first to complete a one-sided scan.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    private func toolSectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.7)
            Spacer()
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 18)
    }

    private func mirrorButton(_ title: String, axis: Int) -> some View {
        Button { Haptics.impact(.medium); viewModel.mirrorModel(axis: axis) } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }
}

/// Crop-box tools: per-face trim sliders, a live size read-out, apply / reset.
struct CropToolsView: View {
    let viewModel: SpatialScanViewModel
    @Binding var cropEnabled: Bool
    @Binding var cropTrim: [Float]

    var body: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $cropEnabled) {
                Label("Crop box", systemImage: "crop")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 18)
            if cropEnabled {
                cropFaceSliders
                Text(croppedDimsText)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
                HStack(spacing: 10) {
                    Button { cropTrim = [0, 0, 0, 0, 0, 0] } label: {
                        Text("Reset")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    Button { Haptics.impact(.medium); applyCrop() } label: {
                        Text(viewModel.isRunning(.cropping) ? "Cropping…" : "Apply crop")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy || cropTrim.allSatisfy { $0 <= 0 })
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var cropFaceSliders: some View {
        VStack(spacing: 6) {
            cropSlider("Left", 0);   cropSlider("Right", 1)
            cropSlider("Bottom", 2); cropSlider("Top", 3)
            cropSlider("Front", 4);  cropSlider("Back", 5)
        }
    }

    private func cropSlider(_ title: String, _ index: Int) -> some View {
        LabeledSlider(title: title,
                      value: Binding(get: { cropTrim[index] * 100 },
                                     set: { cropTrim[index] = min(max($0 / 100, 0), 0.45) }),
                      range: 0...45, format: "%.0f", unit: "%")
            .padding(.horizontal, 18)
    }

    private func cropWorldBox() -> (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        guard let box = viewModel.effectiveMesh?.boundingBox()
                        ?? viewModel.capturedCloud?.boundingBox() else { return nil }
        let ext = box.max - box.min
        let lo = SIMD3<Float>(box.min.x + ext.x * cropTrim[0],
                              box.min.y + ext.y * cropTrim[2],
                              box.min.z + ext.z * cropTrim[4])
        let hi = SIMD3<Float>(box.max.x - ext.x * cropTrim[1],
                              box.max.y - ext.y * cropTrim[3],
                              box.max.z - ext.z * cropTrim[5])
        return (lo, hi)
    }

    private var croppedDimsText: String {
        guard let b = cropWorldBox(), b.lo.x < b.hi.x, b.lo.y < b.hi.y, b.lo.z < b.hi.z else {
            return "Crop box is empty — reduce the trims"
        }
        return "Keeps " + MeasurementFormat.dimensions(b.hi - b.lo)
    }

    private func applyCrop() {
        guard let b = cropWorldBox() else { return }
        viewModel.cropToBox(min: b.lo, max: b.hi)
        cropEnabled = false
        cropTrim = [0, 0, 0, 0, 0, 0]
    }
}

// MARK: - Tool buttons

/// Full-width secondary action button with a busy spinner.
struct CloudToolButton: View {
    let viewModel: SpatialScanViewModel
    let title: String
    let busyTitle: String
    let icon: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
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
}

/// Compact grid tile used by the mesh edit tools.
struct MeshToolButton: View {
    let viewModel: SpatialScanViewModel
    let title: String
    let icon: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button { Haptics.impact(.light); action() } label: {
            VStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                } else {
                    // Scales with the caption beneath it instead of staying a
                    // stamp beside accessibility-size text.
                    Image(systemName: icon).font(.title3.weight(.semibold))
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
}
