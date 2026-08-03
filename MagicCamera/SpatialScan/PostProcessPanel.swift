//
//  PostProcessPanel.swift
//  Magic Camera
//
//  What the review screen asks once a scan is captured: do you want a 3-D model
//  or a surface — and, if you care, with which steps.
//
//  A scan now always lands on its points. The app no longer decides for you and
//  then leaves you to undo a rebuild. The two buttons are pre-filled with exactly
//  what it would have done (`ScanRecipe.standard`), and the disclosure under them
//  shows that plan step by step, each one labelled with what it is for, each one
//  switchable. Pressing a button runs what the disclosure is showing — there is no
//  second, hidden path.
//
//  A nominal `View` struct, like every other piece of this screen: it is a
//  truncation boundary for SwiftUI's mangled type tree, which has overflowed the
//  runtime demangler's stack here before.
//

import SwiftUI

struct PostProcessPanel: View {
    let viewModel: SpatialScanViewModel

    /// Recipes the user has edited, per kind. Absent means "still the standard
    /// one", so the panel keeps tracking the scan as it changes rather than
    /// freezing a plan made before the first step ran.
    @State private var edited: [ScanRecipe.Kind: ScanRecipe] = [:]
    @State private var expanded = false
    @State private var editingKind: ScanRecipe.Kind = .model

    private func recipe(_ kind: ScanRecipe.Kind) -> ScanRecipe {
        edited[kind] ?? viewModel.standardRecipe(kind)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(ScanRecipe.Kind.allCases) { kind in
                    recipeButton(kind)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text(expanded ? "Hide steps" : "Steps & settings")
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded { editor }
        }
        .padding(.horizontal, 16)
        .disabled(viewModel.isBusy || viewModel.isAutoFixing)
    }

    // MARK: - Buttons

    private func recipeButton(_ kind: ScanRecipe.Kind) -> some View {
        let plan = recipe(kind)
        return Button {
            Haptics.impact(.medium)
            viewModel.runRecipe(plan)
        } label: {
            VStack(spacing: 4) {
                Label(kind.rawValue, systemImage: kind.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(plan.steps.isEmpty ? "Nothing to do" : "\(plan.steps.count) steps")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(kind == .model ? Theme.accent.opacity(0.22) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(plan.steps.isEmpty)
        .accessibilityHint(kind.detailLine)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Recipe", selection: $editingKind) {
                ForEach(ScanRecipe.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(editingKind.detailLine)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)

            let plan = recipe(editingKind)

            ForEach(AutoFixStep.canonicalOrder, id: \.self) { step in
                stepRow(step, in: plan)
            }

            Divider().overlay(Theme.textTertiary.opacity(0.3))

            Picker("Method", selection: Binding(
                get: { plan.method },
                set: { edited[editingKind] = plan.with(method: $0) })) {
                ForEach(ReconstructionMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Detail", selection: Binding(
                get: { plan.detail },
                set: { edited[editingKind] = plan.with(detail: $0) })) {
                ForEach(MeshDetail.allCases) { Text($0.rawValue).tag($0) }
            }

            if !plan.isStandard {
                Button {
                    edited[editingKind] = nil
                } label: {
                    Label("Back to the standard recipe", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func stepRow(_ step: AutoFixStep, in plan: ScanRecipe) -> some View {
        Toggle(isOn: Binding(
            get: { plan.steps.contains(step) },
            set: { edited[editingKind] = plan.setting(step, enabled: $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(.subheadline)
                Text(step.purpose)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .tint(Theme.accent)
    }
}
