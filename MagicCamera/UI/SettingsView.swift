//
//  SettingsView.swift
//  Magic Camera
//
//  Global preferences: the unit system measurement read-outs use and the default
//  quality a new point-cloud scan starts at. Binds directly to AppSettings.shared,
//  which writes through to UserDefaults. Also hosts the diagnostics export — a
//  single shareable file with the breadcrumb trail and any MetricKit crash / CPU
//  reports — for troubleshooting field issues.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AppSettings.shared

    @State private var diagnosticsURL: URL?
    @State private var showDiagnosticsShare = false
    @State private var diagnosticsCounts = (events: 0, reports: 0)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $settings.units) {
                        ForEach(UnitSystem.allCases) { system in
                            Label(system.rawValue, systemImage: system.systemImage).tag(system)
                        }
                    }
                } header: {
                    Text("Measurements")
                } footer: {
                    Text("Distances and object sizes are shown in \(settings.units.detail.lowercased()). Effect-tuning sliders stay in metres.")
                }

                Section {
                    NavigationLink {
                        StorageManagerView()
                    } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    NavigationLink {
                        CapabilitiesView()
                    } label: {
                        Label("Sensor report", systemImage: "sensor.tag.radiowaves.forward")
                    }
                } footer: {
                    Text("Saved scans keep their texture photos, so the library can grow large — Storage shows and clears the heavy ones.")
                }

                Section {
                    Toggle("Variable-resolution surfaces", isOn: $settings.adaptiveReconstruction)
                        .tint(Theme.accent)
                } header: {
                    Text("Experimental")
                } footer: {
                    Text("Reconstruct “Textured surface” scans at variable resolution — fine on detailed objects, coarse on flat walls, with a matching texture atlas so large surfaces stay sharp. Off by default while it's being tuned.")
                }

                diagnosticsSection

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Device", value: DeviceCapabilities.hasLiDAR ? "LiDAR available" : "No LiDAR")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { diagnosticsCounts = Diagnostics.shared.counts() }
            .sheet(isPresented: $showDiagnosticsShare) {
                if let url = diagnosticsURL { ShareSheet(items: [url]) }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            Toggle("GPU texture bake", isOn: $settings.gpuTextureBake)
                .tint(Theme.accent)

            LabeledContent("Recorded events", value: "\(diagnosticsCounts.events)")
            LabeledContent("Crash / CPU reports", value: "\(diagnosticsCounts.reports)")

            Button {
                Haptics.impact(.light)
                if let url = Diagnostics.shared.exportArchive() {
                    diagnosticsURL = url
                    showDiagnosticsShare = true
                }
            } label: {
                Label("Export diagnostics", systemImage: "square.and.arrow.up.on.square")
            }

            Button(role: .destructive) {
                Diagnostics.shared.clear()
                diagnosticsCounts = (0, 0)
            } label: {
                Label("Clear diagnostics", systemImage: "trash")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The export bundles recent app activity (incl. ⚡︎ GPU / ○ CPU lines showing what ran on the GPU) and any crash, CPU or hang reports the system delivered — those arrive at most once a day, usually at the next launch. Turn off GPU texture bake to force the CPU path if a textured model looks wrong.")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
