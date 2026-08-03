//
//  CaptureProfilePicker.swift
//  Magic Camera
//
//  The scan setup's two questions, as two controls.
//
//  What this replaces: one five-segment picker holding Draft, Balanced, Max,
//  Object and Room together. Five segments is already past what reads on a phone,
//  and worse, the five were two different questions — so choosing "Max" silently
//  answered "what am I scanning" too. `CaptureProfile` carries the reasoning.
//
//  A nominal `View` struct, like every other piece of this screen's tools: it is a
//  truncation boundary for SwiftUI's mangled type tree, which has already
//  overflowed the runtime demangler's stack here once.
//

import SwiftUI

struct CaptureProfilePicker: View {
    @Binding var subject: CaptureSubject
    @Binding var detail: CaptureDetail
    /// Passed in rather than recomputed so the summary line always describes the
    /// pair the view model actually holds.
    let profile: CaptureProfile

    var body: some View {
        VStack(spacing: 10) {
            labelled("What are you scanning") {
                Picker("Subject", selection: $subject) {
                    ForEach(CaptureSubject.allCases) { subject in
                        Label(subject.rawValue, systemImage: subject.systemImage)
                            .tag(subject)
                    }
                }
            }

            labelled("How much detail") {
                Picker("Detail", selection: $detail) {
                    ForEach(CaptureDetail.allCases) { detail in
                        Text(detail.rawValue).tag(detail)
                    }
                }
            }

            Text(profile.detailLine)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.horizontal, 16)
    }

    /// A quiet caption above each segment. Without them the two rows read as one
    /// undifferentiated stack of options — which is the problem being fixed, not a
    /// smaller version of it.
    private func labelled(_ title: String,
                          @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)   // the Picker carries its own label
            content()
                .pickerStyle(.segmented)
        }
    }
}
