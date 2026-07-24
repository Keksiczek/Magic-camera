//
//  MagicCameraWidget.swift
//  Magic Camera — Widget Extension
//
//  Home-screen widget showing the most recent 3D scans, with a shortcut to start
//  a new scan. Data comes from the snapshot the app publishes into the shared App
//  Group container (see WidgetShared / RecentScansPublisher); the widget never
//  touches the app's own storage. Deep links route through the app's custom URL
//  scheme, handled in RootView.
//

import WidgetKit
import SwiftUI
import UIKit

// MARK: - Palette (the widget target has no access to the app's Theme)

private enum WidgetTheme {
    static let accent = Color(red: 0.30, green: 0.60, blue: 0.95)
    static let warm = Color(red: 0.95, green: 0.48, blue: 0.30)
}

private extension URL {
    static let gallery = URL(string: "\(WidgetSharing.urlScheme)://gallery")!
    static let newScan = URL(string: "\(WidgetSharing.urlScheme)://scan")!
}

// MARK: - Timeline

struct RecentScansEntry: TimelineEntry {
    let date: Date
    let snapshot: RecentScansSnapshot?
}

struct RecentScansProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentScansEntry {
        RecentScansEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentScansEntry) -> Void) {
        completion(RecentScansEntry(date: Date(), snapshot: WidgetSharing.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentScansEntry>) -> Void) {
        // The app pushes reloads whenever the library changes, so a single entry
        // with no refresh policy is enough.
        let entry = RecentScansEntry(date: Date(), snapshot: WidgetSharing.loadSnapshot())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - Widget

struct MagicCameraWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MagicCameraRecentScans", provider: RecentScansProvider()) { entry in
            RecentScansWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recent Scans")
        .description("Your latest 3D scans, and a shortcut to start a new one.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MagicCameraWidgetBundle: WidgetBundle {
    var body: some Widget {
        MagicCameraWidget()
    }
}

// MARK: - Views

struct RecentScansWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentScansEntry

    private var scans: [RecentScan] { entry.snapshot?.scans ?? [] }

    var body: some View {
        if scans.isEmpty {
            EmptyStateView()
        } else if family == .systemSmall {
            SmallView(latest: scans[0], total: entry.snapshot?.totalCount ?? scans.count)
        } else {
            MediumView(scans: Array(scans.prefix(4)),
                       total: entry.snapshot?.totalCount ?? scans.count)
        }
    }
}

private struct SmallView: View {
    let latest: RecentScan
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailTile(scan: latest)
                .frame(maxWidth: .infinity)
                .frame(height: 78)
            VStack(alignment: .leading, spacing: 1) {
                Text(latest.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(total) scan\(total == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(.gallery)
    }
}

private struct MediumView: View {
    let scans: [RecentScan]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Recent scans", systemImage: "cube.transparent")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WidgetTheme.accent)
                Spacer()
                Link(destination: .newScan) {
                    Label("New", systemImage: "plus.circle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(WidgetTheme.accent, in: Capsule())
                }
            }
            HStack(spacing: 8) {
                ForEach(scans) { scan in
                    VStack(spacing: 3) {
                        ThumbnailTile(scan: scan)
                            .frame(height: 62)
                        Text(scan.name)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .widgetURL(.gallery)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(WidgetTheme.accent)
            Text("No scans yet")
                .font(.caption.weight(.semibold))
            Text("Tap to start scanning")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(.newScan)
    }
}

/// A rounded thumbnail with a kind badge, falling back to an icon.
private struct ThumbnailTile: View {
    let scan: RecentScan

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: scan.isMesh ? "grid" : "circle.grid.3x3.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Circle()
                .fill(scan.isMesh ? WidgetTheme.warm : WidgetTheme.accent)
                .frame(width: 8, height: 8)
                .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var thumbnail: UIImage? {
        guard let file = scan.thumbnailFile,
              let url = WidgetSharing.thumbnailURL(file) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
