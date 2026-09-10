//
//  ExportSheet.swift
//  Magic Camera
//
//  The export picker. Presents the intent-grouped options from ExportCatalogue —
//  what you want to do with the file, the format that serves it, and an estimated
//  size — instead of the flat extension list this replaces.
//

import SwiftUI

struct ExportSheet: View {
    let groups: [ExportGroup]
    let onPick: (ExportAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.options) { option in
                            Button {
                                Haptics.impact(.light)
                                onPick(option.action)
                                dismiss()
                            } label: {
                                ExportOptionRow(option: option)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if groups.isEmpty {
                    Text("Nothing to export yet — capture or build a model first.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ExportOptionRow: View {
    let option: ExportOption

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: option.systemImage)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.title)
                        .font(.body.weight(.semibold))
                    Text(option.formatLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(option.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let sizeText = option.sizeText {
                Text(sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        // The estimate is a hint; say so to VoiceOver rather than reading "≈".
        .accessibilityHint(option.sizeText.map { "Estimated size \($0.dropFirst(2))" } ?? "")
    }
}
