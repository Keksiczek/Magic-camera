//
//  Diagnostics.swift
//  Magic Camera
//
//  App-owned diagnostics that can be exported from Settings as a single file:
//
//    • A rolling breadcrumb log of notable events (scan start/stop, a
//      reconstruction's start + elapsed time + result, failures). A heavy op
//      that "never finishes" shows up as a `begin` with no matching `end`.
//    • Any MetricKit crash / CPU-exception / hang / disk-write diagnostic
//      payloads the system delivers — the same `.ips`-style reports Xcode
//      shows, captured in the field so they can be shared after the fact.
//
//  Everything persists under Application Support so a watchdog kill or crash
//  leaves a trail, and `exportArchive()` bundles it into one shareable `.txt`.
//

import Foundation
import os
#if canImport(Metal)
import Metal
#endif
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(UIKit)
import UIKit
#endif

final class Diagnostics: NSObject, @unchecked Sendable {
    static let shared = Diagnostics()

    private let logger = Logger(subsystem: "com.keks.MagicCamera", category: "diagnostics")
    /// Serialises all file IO so breadcrumb appends and payload writes never race.
    private let ioQueue = DispatchQueue(label: "com.keks.MagicCamera.diagnostics")

    private let directory: URL
    private let breadcrumbsURL: URL
    private let payloadsDirectory: URL

    /// Trim the breadcrumb file once it passes this; keeps the tail.
    private let maxBreadcrumbBytes = 256 * 1024
    /// Keep at most this many MetricKit *diagnostic* payloads (crash / CPU / hang);
    /// most recent wins. Metric payloads are capped separately (and lower) so they
    /// can't crowd the diagnostics out.
    private let maxStoredPayloads = 40
    /// Daily metric payloads are bulky context — keep only a few of the newest.
    private let maxStoredMetrics = 8

    private let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private override init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
        breadcrumbsURL = directory.appendingPathComponent("breadcrumbs.log")
        payloadsDirectory = directory.appendingPathComponent("payloads", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: payloadsDirectory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    /// Registers for MetricKit payloads and records a launch breadcrumb. Call
    /// once, early, from the app entry point.
    func start() {
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
        log("app launch", Self.deviceLine())
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            log("metal device", device.name)
        } else {
            log("metal device", "unavailable — all GPU paths use the CPU fallback")
        }
        #endif
    }

    /// Records whether a heavy subsystem ran on the GPU or fell back to the CPU,
    /// so the exported report shows — in the field — what actually executed on
    /// the GPU. Look for "⚡︎ GPU" vs "○ CPU" lines.
    func gpu(_ label: String, used: Bool, _ detail: String = "") {
        log(used ? "⚡︎ GPU · \(label)" : "○ CPU · \(label)", detail)
    }

    // MARK: - Memory

    /// Footprint and remaining headroom, e.g. `used 1420 MB · headroom 780 MB`.
    ///
    /// `os_proc_available_memory` is the number that actually matters: it is what
    /// the app has left before iOS jetsams it, already accounting for the device,
    /// the memory limit and what else is running. Absolute footprint alone can't
    /// answer "was this close?".
    ///
    /// Added because the 2026-07-28 room died to memory pressure during a bake and
    /// the export could say only that `.critical` fired four times — not how much
    /// was in use, not how much was left, and not whether the capture or the bake
    /// was holding it. The same bake then completed in a fresh process, which is
    /// the whole clue, and there was no number anywhere to confirm it.
    static func memoryUsage() -> (usedMB: Int, headroomMB: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let used = result == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : 0
        return (used, os_proc_available_memory() / 1_048_576)
    }

    /// Logs `memoryUsage()` against a stage name. Call at the boundaries that
    /// matter (scan finish, heavy-op start/end, memory pressure) — cheap enough
    /// that placing it liberally costs nothing.
    func memory(_ stage: String) {
        let m = Self.memoryUsage()
        log("memory", "\(stage) · used \(m.usedMB) MB · headroom \(m.headroomMB) MB")
    }

    // MARK: - Breadcrumbs

    /// Appends a timestamped line. `detail` is optional context appended after
    /// the event. Cheap and fire-and-forget — safe to call from any thread.
    func log(_ event: String, _ detail: String = "") {
        let now = Date()
        logger.log("\(event, privacy: .public) \(detail, privacy: .public)")
        ioQueue.async { [self] in
            // Format on the serial queue: ISO8601DateFormatter isn't safe to
            // share across the threads `log` may be called from.
            let stamp = timestampFormatter.string(from: now)
            let line = detail.isEmpty ? "\(stamp)  \(event)\n" : "\(stamp)  \(event) — \(detail)\n"
            append(line)
            trimBreadcrumbsIfNeeded()
        }
    }

    /// Times a span of work. Returns a token to hand to `end`; the elapsed time
    /// and outcome land in the log, so a hang is visible as a `begin` with no
    /// `end`.
    struct Span { let label: String; let started: Date }

    func begin(_ label: String, _ detail: String = "") -> Span {
        log("▶ \(label)", detail)
        return Span(label: label, started: Date())
    }

    func end(_ span: Span, _ outcome: String = "ok") {
        let ms = Int(Date().timeIntervalSince(span.started) * 1000)
        log("■ \(span.label)", "\(outcome) · \(ms) ms")
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: breadcrumbsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: breadcrumbsURL, options: .atomic)
        }
    }

    private func trimBreadcrumbsIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(
            atPath: breadcrumbsURL.path)[.size] as? Int, size > maxBreadcrumbBytes,
            let content = try? String(contentsOf: breadcrumbsURL, encoding: .utf8) else { return }
        // Keep the most recent half-budget worth of lines.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(1500).joined(separator: "\n")
        try? kept.data(using: .utf8)?.write(to: breadcrumbsURL, options: .atomic)
    }

    // MARK: - Export

    /// Bundles device info, breadcrumbs and every stored MetricKit payload into
    /// one `.txt` in a temp directory, returning its URL for sharing.
    func exportArchive() -> URL? {
        ioQueue.sync {
            var report = "Magic Camera diagnostics\n"
            report += "Generated: \(timestampFormatter.string(from: Date()))\n"
            report += Self.deviceLine() + "\n"
            report += String(repeating: "─", count: 40) + "\n\n"

            report += "EVENTS\n"
            if let crumbs = try? String(contentsOf: breadcrumbsURL, encoding: .utf8), !crumbs.isEmpty {
                report += crumbs
            } else {
                report += "(none recorded yet)\n"
            }
            report += "\n"

            let payloads = storedPayloadFiles()
            let diagnostics = payloads.filter { $0.lastPathComponent.hasPrefix("diagnostic-") }
            let metrics = payloads.filter { $0.lastPathComponent.hasPrefix("metric-") }

            // Diagnostics (crashes / CPU exceptions / hangs / disk-writes) are the
            // actionable signal — dump them in full.
            report += String(repeating: "─", count: 40) + "\n"
            report += "METRICKIT DIAGNOSTICS (\(diagnostics.count)) — crashes · CPU exceptions · hangs · disk-writes\n"
            if diagnostics.isEmpty {
                report += "(none yet — the system delivers crash / CPU / hang reports "
                report += "at most once a day, usually at the next launch after the event)\n"
            }
            for url in diagnostics {
                report += "\n• \(url.lastPathComponent)\n"
                if let json = try? String(contentsOf: url, encoding: .utf8) {
                    report += json + "\n"
                }
            }

            // Daily metric payloads (battery / CPU / disk-usage summaries) are
            // bulky and rarely tied to a specific bug — they were most of the
            // export's volume. List them by name; the full JSON stays on device.
            if !metrics.isEmpty {
                report += "\n" + String(repeating: "─", count: 40) + "\n"
                report += "METRICKIT METRICS (\(metrics.count)) — daily summaries, names only; full JSON kept on device\n"
                for url in metrics { report += "• \(url.lastPathComponent)\n" }
            }

            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MagicCamera-Diagnostics-\(fileStamp()).txt")
            guard (try? report.data(using: .utf8)?.write(to: outURL, options: .atomic)) != nil else {
                return nil
            }
            return outURL
        }
    }

    /// Counts for the Settings UI: (#breadcrumb lines, #stored payload files).
    func counts() -> (events: Int, reports: Int) {
        ioQueue.sync {
            let events = (try? String(contentsOf: breadcrumbsURL, encoding: .utf8))?
                .split(separator: "\n").count ?? 0
            return (events, storedPayloadFiles().count)
        }
    }

    /// Clears breadcrumbs and stored payloads. Used by the Settings "clear" action.
    func clear() {
        ioQueue.async { [self] in
            try? FileManager.default.removeItem(at: breadcrumbsURL)
            for url in storedPayloadFiles() { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func storedPayloadFiles() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: payloadsDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
    }

    private func store(payloadJSON data: Data, kind: String) {
        ioQueue.async { [self] in
            let url = payloadsDirectory
                .appendingPathComponent("\(kind)-\(fileStamp()).json")
            try? data.write(to: url, options: .atomic)
            // Prune per kind so a burst of daily `metric` payloads can never evict
            // the far more valuable crash / CPU `diagnostic` reports — they share a
            // directory and "metric-" sorts ahead of "diagnostic-", so a single
            // combined cap dropped the diagnostics first.
            prunePayloads(prefix: "diagnostic-", keep: maxStoredPayloads)
            prunePayloads(prefix: "metric-", keep: maxStoredMetrics)
        }
    }

    /// Removes all but the newest `keep` payloads whose name starts with `prefix`.
    /// `storedPayloadFiles()` is newest-first, so the dropped tail is the oldest.
    private func prunePayloads(prefix: String, keep: Int) {
        let matching = storedPayloadFiles().filter { $0.lastPathComponent.hasPrefix(prefix) }
        for url in matching.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Helpers

    private func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    private static func deviceLine() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        var model = "unknown"
        var sys = utsname()
        uname(&sys)
        model = withUnsafeBytes(of: &sys.machine) { raw in
            raw.prefix { $0 != 0 }.map { Character(UnicodeScalar(UInt8($0))) }
        }.map(String.init).joined()
        // ProcessInfo is nonisolated; UIDevice.current is @MainActor in Swift 6
        // and deviceLine() runs off-main from the breadcrumb logger.
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let os = "iOS \(osv.majorVersion).\(osv.minorVersion)"
            + (osv.patchVersion > 0 ? ".\(osv.patchVersion)" : "")
        let lidar = DeviceCapabilities.hasLiDAR ? "LiDAR" : "no-LiDAR"
        return "App \(v) (\(b)) · \(model) · \(os) · \(lidar)"
    }
}

#if canImport(MetricKit)
extension Diagnostics: MXMetricManagerSubscriber {
    /// Diagnostic payloads (iOS 14+): crashes, CPU exceptions, hangs, disk
    /// writes — the field equivalent of the `.ips` reports.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            store(payloadJSON: payload.jsonRepresentation(), kind: "diagnostic")
        }
        log("received \(payloads.count) MetricKit diagnostic payload(s)")
    }

    /// Daily metric payloads (battery, CPU, launch time, …). Useful context
    /// alongside the diagnostics.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            store(payloadJSON: payload.jsonRepresentation(), kind: "metric")
        }
    }
}
#endif
