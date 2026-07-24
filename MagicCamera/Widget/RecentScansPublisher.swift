//
//  RecentScansPublisher.swift
//  Magic Camera
//
//  App-side half of the widget bridge: writes a snapshot of the most recent
//  scans (and copies their thumbnails) into the shared App Group container, then
//  asks WidgetKit to refresh. Called after the library changes (save, delete,
//  rename, iCloud update) and at launch. App target only.
//

import Foundation
import WidgetKit

enum RecentScansPublisher {
    /// Regenerates the widget snapshot off the main thread. Cheap and safe to
    /// call often; WidgetKit coalesces the reload requests.
    static func publish() {
        Task.detached(priority: .utility) {
            let items = ScanLibrary.allItems()
            let recent = Array(items.prefix(WidgetSharing.maxScans))
            let fm = FileManager.default

            // Refresh the thumbnail cache: clear, then copy the current set.
            if let thumbsDir = WidgetSharing.thumbnailsDirectory {
                if let existing = try? fm.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil) {
                    for file in existing { try? fm.removeItem(at: file) }
                }
            }

            var scans: [RecentScan] = []
            for item in recent {
                var thumbnailFile: String?
                if let thumbsDir = WidgetSharing.thumbnailsDirectory {
                    let source = item.url.appendingPathExtension("png") // Thumbnails.url(for:)
                    if fm.fileExists(atPath: source.path) {
                        let name = item.url.lastPathComponent + ".png"
                        let dest = thumbsDir.appendingPathComponent(name)
                        try? fm.removeItem(at: dest)
                        if (try? fm.copyItem(at: source, to: dest)) != nil {
                            thumbnailFile = name
                        }
                    }
                }
                scans.append(RecentScan(
                    id: item.url.lastPathComponent,
                    name: item.name,
                    date: item.date,
                    kind: item.kind == .mesh ? "mesh" : "points",
                    count: item.count,
                    thumbnailFile: thumbnailFile))
            }

            let snapshot = RecentScansSnapshot(
                scans: scans, totalCount: items.count, generatedAt: Date())
            if let url = WidgetSharing.snapshotURL,
               let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
