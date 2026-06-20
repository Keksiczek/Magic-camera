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
    /// Keep at most this many MetricKit payload files (most recent wins).
    private let maxStoredPayloads = 40

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
            report += String(repeating: "─", count: 40) + "\n"
            report += "METRICKIT PAYLOADS (\(payloads.count))\n"
            if payloads.isEmpty {
                report += "(none yet — the system delivers crash / CPU / hang reports "
                report += "at most once a day, usually at the next launch after the event)\n"
            }
            for url in payloads {
                report += "\n• \(url.lastPathComponent)\n"
                if let json = try? String(contentsOf: url, encoding: .utf8) {
                    report += json + "\n"
                }
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
            // Prune to the most recent N.
            let all = storedPayloadFiles()
            if all.count > maxStoredPayloads {
                for url in all.dropFirst(maxStoredPayloads) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
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
