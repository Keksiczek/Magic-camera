//
//  ScanLiveActivity.swift
//  Magic Camera — Widget Extension
//
//  The in-progress-scan Live Activity: a lock-screen / banner card and the
//  Dynamic Island in all three presentations (compact, minimal, expanded). The
//  app drives the content via ScanActivityAttributes (see
//  ScanLiveActivityController); this file only renders whatever state it is
//  handed. Registered in the widget bundle alongside the Recent-Scans widget.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct ScanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScanActivityAttributes.self) { context in
            ScanActivityLockScreen(context: context)
                .padding(16)
                .activityBackgroundTint(WidgetTheme.activityBackground)
                .activitySystemActionForegroundColor(WidgetTheme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.subject, systemImage: context.attributes.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetTheme.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.phase)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ScanActivityProgress(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol)
                    .foregroundStyle(WidgetTheme.accent)
            } compactTrailing: {
                Text(ScanActivityFormat.compactCount(context.state.count))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            } minimal: {
                Image(systemName: context.attributes.symbol)
                    .foregroundStyle(WidgetTheme.accent)
            }
            .widgetURL(URL(string: "\(WidgetSharing.urlScheme)://scan"))
        }
    }
}

// MARK: - Lock screen / banner

private struct ScanActivityLockScreen: View {
    let context: ActivityViewContext<ScanActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.attributes.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(WidgetTheme.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(context.attributes.subject) scan")
                        .font(.headline)
                    Spacer()
                    Text(context.state.phase)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                ScanActivityProgress(state: context.state)
            }
        }
    }
}

// MARK: - Shared progress row

private struct ScanActivityProgress: View {
    let state: ScanActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = state.progress {
                ProgressView(value: progress)
                    .tint(WidgetTheme.accent)
            }
            Text("\(ScanActivityFormat.count(state.count)) \(state.unit)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Formatting (widget has no access to the app's MeasurementFormat)

enum ScanActivityFormat {
    /// Grouped count, e.g. "1,234,567".
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Space-tight count for the Dynamic Island compact trailing slot: "1.2M".
    static func compactCount(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1))))M"
        case 1_000...:
            return "\(value / 1_000)k"
        default:
            return "\(value)"
        }
    }
}
