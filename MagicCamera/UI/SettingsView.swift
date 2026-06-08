//
//  SettingsView.swift
//  Magic Camera
//
//  Global preferences: the unit system measurement read-outs use and the default
//  quality a new point-cloud scan starts at. Binds directly to AppSettings.shared,
//  which writes through to UserDefaults.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AppSettings.shared

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
                    Picker("Default quality", selection: $settings.defaultQuality) {
                        ForEach(ScanQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                } header: {
                    Text("Spatial scan")
                } footer: {
                    Text("New point-cloud scans start at this quality. Higher quality captures more detail but uses more memory.")
                }

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
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
