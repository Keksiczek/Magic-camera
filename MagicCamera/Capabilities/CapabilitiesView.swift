//
//  CapabilitiesView.swift
//  Magic Camera
//
//  Read-only report of the device's depth / spatial / motion sensors so the
//  user can see exactly what Magic Camera can use on this hardware.
//

import SwiftUI

struct CapabilitiesView: View {
    private let sections = SensorInfo.sections()

    var body: some View {
        List {
            Section {
                summaryBanner
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        SensorRow(item: item)
                    }
                } header: {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
        }
        .navigationTitle("Sensors")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryBanner: some View {
        let lidar = DeviceCapabilities.hasLiDAR
        return HStack(spacing: 14) {
            Image(systemName: lidar ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(lidar ? Color.green : Theme.accentWarm)
            VStack(alignment: .leading, spacing: 3) {
                Text(lidar ? "LiDAR ready" : "No LiDAR")
                    .font(.headline)
                Text(lidar ? "Depth effects and spatial scanning are available."
                           : "Depth features are unavailable on this device.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .glassPanel()
        .padding(.vertical, 4)
    }
}

private struct SensorRow: View {
    let item: SensorItem
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Image(systemName: item.available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(item.available ? Color.green : Color.secondary)
        }
    }
}
