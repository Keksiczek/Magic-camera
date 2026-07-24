//
//  MagicCameraApp.swift
//  Magic Camera
//
//  App entry point. Forces a dark, camera-style appearance throughout.
//

import SwiftUI

@main
struct MagicCameraApp: App {
    init() {
        // Register MetricKit + start the breadcrumb trail as early as possible
        // so a crash or watchdog kill still leaves an exportable record.
        Diagnostics.shared.start()
        Self.sweepStaleExports()
    }

    /// Every export / AR Quick Look / turntable / diagnostics path writes a
    /// "MagicCamera-…" file into the temp directory and only ever replaces its
    /// own exact filename — distinct-named ones (timestamps, dates) accumulated
    /// forever. Sweep anything older than a day on launch; fresh files stay so
    /// a share started just before a relaunch isn't pulled out from under.
    private static func sweepStaleExports() {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            guard let files = try? fm.contentsOfDirectory(
                at: fm.temporaryDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles) else { return }
            for url in files where url.lastPathComponent.hasPrefix("MagicCamera-") {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff { try? fm.removeItem(at: url) }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
