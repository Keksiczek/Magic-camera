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
