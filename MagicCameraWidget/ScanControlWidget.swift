//
//  ScanControlWidget.swift
//  Magic Camera — Widget Extension
//
//  Control Center / Lock Screen / Action-button controls (iOS 18+). A scanner is
//  a "the moment is now" app — by the time you have unlocked, found the icon and
//  waited for ARKit, the thing you wanted to capture has moved. These put the two
//  capture entry points one press from anywhere.
//
//  Both use the system `OpenURLIntent` against the app's existing deep links
//  (handled in RootView.handleDeepLink), so there is no custom intent to keep in
//  sync across the target boundary — the URL contract in `WidgetSharing` is the
//  single source of truth.
//

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct StartScanControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.keks.MagicCamera.control.startScan") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "\(WidgetSharing.urlScheme)://scan")!)) {
                Label("Start Scan", systemImage: "cube.transparent")
            }
        }
        .displayName("Start Scan")
        .description("Opens Magic Camera ready to scan.")
    }
}

@available(iOS 18.0, *)
struct OpenGalleryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.keks.MagicCamera.control.gallery") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "\(WidgetSharing.urlScheme)://gallery")!)) {
                Label("Scan Gallery", systemImage: "square.grid.2x2.fill")
            }
        }
        .displayName("Scan Gallery")
        .description("Opens your saved 3D scans.")
    }
}
