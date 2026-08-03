//
//  CaptureOptionsPanel.swift
//  Magic Camera
//
//  The scan options, where they are actually decided: on the setup screen, folded
//  away until asked for.
//
//  Two rules, both from the user. **Only things that do something appear here** —
//  a menu entry that changes nothing is worse than no entry, because it costs a
//  decision and returns nothing. That is why the variable-resolution / octree
//  reconstruction is NOT offered: `AdaptiveOctree` and
//  `AdaptiveSurfaceReconstructor` are built but were never wired into the shipping
//  pipeline, so choosing them would change no pixel. (They are also two of the
//  three permanently failing tests — see docs/analysis/HANDOFF.)
//
//  And **every option says what it is for**. Each row carries a plain line
//  explaining what turning it off would do, because a switch called "Sample
//  confidence" tells a user nothing.
//
//  A nominal `View` struct: it is a truncation boundary for SwiftUI's mangled type
//  tree, which has overflowed the runtime demangler's stack on this screen before.
//

import SwiftUI

struct CaptureOptionsPanel: View {
    let viewModel: SpatialScanViewModel
    @Bindable private var settings = AppSettings.shared
    @State private var expanded = false

    init(viewModel: SpatialScanViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text(expanded ? "Hide scan options" : "Scan options")
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded { options }
        }
        .padding(.horizontal, 16)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Point budget")
                    .font(.subheadline.weight(.semibold))
                Picker("Point budget", selection: $settings.pointBudget) {
                    ForEach(CaptureBudget.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("\(settings.pointBudget.detailLine) A ceiling so the phone stays alive — detail is set by the density above, not by this.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            optionRow("Steady-hand filtering", isOn: $settings.sampleConfidence,
                      detail: "Weighs every depth sample by how trustworthy it looks — angle, edges, distance, how fast you were moving. Turn it off if a scan comes back with holes.")

            optionRow("Live alignment", isOn: $settings.frameAlignment,
                      detail: "Corrects the phone's tracking against the scan as it grows, so a long sweep doesn't drift. Turn it off if a scan comes back doubled.")

            optionRow("Round off known shapes", isOn: $settings.shapeSnapping,
                      detail: "Straightens scanned cylinders and spheres — pots, cups, balls — onto their true shape, keeping any decoration on them.")

            optionRow("Photo texture on the GPU", isOn: $settings.gpuTextureBake,
                      detail: "Bakes the photo texture on the graphics chip. Turn it off if a textured model looks wrong; it will be slower but identical.")

            if viewModel.captureSubject == .room {
                optionRow("Finer room detail", isOn: $settings.fineRoomLattice,
                          detail: "Builds rooms on a 20 mm grid instead of 28 mm — about twice the triangles. Experimental: the extra detail may be sensor noise, and a finer grid has torn holes in walls before.")
            }

            if viewModel.captureSubject == .object {
                objectOptions
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Object's own two extras, which used to appear on the capture screen only
    /// when Object was selected, detached from every other option.
    private var objectOptions: some View {
        @Bindable var vm = viewModel
        return VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $vm.objectFine) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Extra-fine density").font(.subheadline)
                    Text("For coins, jewellery and small intricate things. Much more memory.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                LabeledSlider(title: "Range", value: $vm.objectRange,
                              range: 1.0...2.5, format: "%.1f", unit: " m")
                Text("How far from the phone to keep points. Tighter keeps the room behind the subject out.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func optionRow(_ title: String, isOn: Binding<Bool>,
                           detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .tint(Theme.accent)
    }
}
