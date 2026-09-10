//
//  WidgetShared.swift
//  Magic Camera
//
//  Data contract shared between the app and the home-screen widget. Widgets run
//  in a separate process and cannot read the app's Documents / iCloud container,
//  so the app publishes a small snapshot of the most recent scans (plus copies of
//  their thumbnails) into the shared App Group container; the widget reads it.
//
//  This file is compiled into BOTH the app target and the widget extension —
//  keep it dependency-free (Foundation only).
//

import Foundation

/// One entry shown in the widget.
struct RecentScan: Codable, Identifiable, Hashable {
    /// The model file's `lastPathComponent` — stable id and deep-link key.
    let id: String
    let name: String
    let date: Date
    /// "mesh" or "points".
    let kind: String
    /// Triangle count (mesh) or point count (cloud).
    let count: Int
    /// Filename of the copied thumbnail within the App Group thumbnails dir.
    let thumbnailFile: String?

    var isMesh: Bool { kind == "mesh" }
}

/// The published snapshot the widget renders.
struct RecentScansSnapshot: Codable {
    let scans: [RecentScan]
    /// Total number of saved scans (may exceed `scans.count`).
    let totalCount: Int
    let generatedAt: Date
}

/// Shared App Group locations and (widget-side) reads.
enum WidgetSharing {
    static let appGroupID = "group.com.keks.MagicCamera"
    /// How many recent scans the snapshot carries (a medium widget shows up to 4).
    static let maxScans = 4
    /// Custom URL scheme the widget deep-links through; handled in RootView.
    static let urlScheme = "magiccamera"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("recent-scans.json")
    }

    static var thumbnailsDirectory: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func thumbnailURL(_ file: String) -> URL? {
        thumbnailsDirectory?.appendingPathComponent(file)
    }

    // MARK: - Deep links

    /// `magiccamera://scan/<id>` — opens one specific saved scan.
    ///
    /// Ids are file names ("Kitchen 2.mcmesh") and so can contain spaces and
    /// other characters that are illegal in a URL path; `URLComponents` does the
    /// percent-encoding, and `scanID(from:)` decodes it symmetrically. Both
    /// halves of the contract live here because this file is the one thing the
    /// app and the widget extension share.
    static func scanURL(id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "scan"
        components.path = "/" + id
        return components.url
    }

    /// The scan id carried by a deep link, or nil when it is the plain
    /// `magiccamera://scan` "start a new scan" link.
    static func scanID(from url: URL) -> String? {
        guard url.scheme == urlScheme, url.host == "scan" else { return nil }
        let id = url.pathComponents.dropFirst().joined(separator: "/")
        return id.isEmpty ? nil : id
    }

    /// The snapshot the app last published, or nil when none exists yet.
    static func loadSnapshot() -> RecentScansSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecentScansSnapshot.self, from: data)
    }
}
