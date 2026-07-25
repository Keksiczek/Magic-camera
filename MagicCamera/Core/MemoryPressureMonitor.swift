//
//  MemoryPressureMonitor.swift
//  Magic Camera
//
//  Watches the system memory-pressure signal and broadcasts it so the review
//  screen can shed recoverable memory (the undo history — each snapshot can hold
//  a multi-million-point cloud) and, at CRITICAL pressure, stop the in-flight
//  reconstruction / texture bake before the system jetsams the app.
//
//  Processing was previously open-loop: a 2–3 M-point scan that approached the
//  memory limit was killed with no chance to react (a real device kill mid-bake
//  on a 2.26 M-point room). This turns that silent jetsam into a graceful,
//  recoverable stop — the "Recover unsaved scan?" path already exists on
//  relaunch, and the last checkpoint is autosaved.
//
//  App-lifetime, started once from RootView. Purely advisory: it never blocks a
//  running operation, only requests cancellation and sheds caches.
//

import Foundation

extension Notification.Name {
    /// Posted on the main thread when the system reports memory pressure.
    /// `userInfo[MemoryPressureMonitor.levelKey]` carries a `MemoryPressureLevel`.
    static let memoryPressure = Notification.Name("com.keks.MagicCamera.memoryPressure")
}

/// Severity of a system memory-pressure event.
enum MemoryPressureLevel: String, Sendable {
    /// Shed recoverable memory (caches, most of the undo history).
    case warning
    /// Stop in-flight heavy work before the system jetsams us.
    case critical
}

@MainActor
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()
    static let levelKey = "level"

    private var source: DispatchSourceMemoryPressure?

    private init() {}

    /// Begins watching. Idempotent — a second call is a no-op.
    func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        // `setEventHandler`'s block is NOT declared `@Sendable`, so a plain
        // closure formed here would inherit this type's main-actor isolation and
        // SIGTRAP under Swift 6's dynamic isolation checks (see the project's
        // GCD/MainActor trap). Write it `@Sendable` with Sendable captures
        // (`src` is a Sendable dispatch type; the monitor is main-actor, hence
        // Sendable); the source is scheduled on `.main`, so hopping back with
        // `assumeIsolated` is sound.
        src.setEventHandler { @Sendable [weak self] in
            let event = src.data
            MainActor.assumeIsolated { self?.broadcast(Self.level(for: event)) }
        }
        source = src
        src.activate()
    }

    /// `.critical` wins when both bits are set — respond to the worse pressure.
    /// Pure, so `nonisolated`: callable off the main actor (and from tests).
    nonisolated static func level(for event: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        event.contains(.critical) ? .critical : .warning
    }

    /// Test/diagnostic hook: drive the same broadcast without a real system event.
    func simulate(_ level: MemoryPressureLevel) {
        broadcast(level, simulated: true)
    }

    private func broadcast(_ level: MemoryPressureLevel, simulated: Bool = false) {
        Diagnostics.shared.log("memory pressure",
                               level.rawValue + (simulated ? " (simulated)" : ""))
        // Cheap app-global shed, safe at either level.
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: .memoryPressure, object: nil,
                                        userInfo: [Self.levelKey: level])
    }
}
