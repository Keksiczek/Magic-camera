//
//  ARViewerView.swift
//  Magic Camera
//
//  Standalone AR viewer reachable straight from the home menu: pick any saved
//  scan or room and place it in your space with AR Quick Look — no need to
//  reopen it in the Spatial Scan editor first. Reuses the gallery as the picker
//  and the same USDZ exporters the in-scan "View in AR" uses.
//

import SwiftUI

/// Exports a gallery-picked model to a temporary USDZ for AR Quick Look. Mirrors
/// `SpatialScanViewModel.presentARQuickLook` so the standalone viewer shows
/// identical geometry: a textured mesh when baked, a plain mesh otherwise, or
/// placeable point geometry for a cloud.
enum ARQuickLookExport {
    static func usdz(for pick: GalleryPick) throws -> URL {
        switch pick {
        case .cloud(let cloud, _):   // AR export only needs the geometry, not the rays
            return try PointCloudUSDZExporter.write(cloud, filename: "MagicCamera-arview")
        case .mesh(let mesh, let textured):
            if let textured {
                return try TexturedMeshExporter.write(textured, format: .usdz,
                                                      filename: "MagicCamera-arview")
            }
            return try MeshExporter.write(mesh, format: .usdz, filename: "MagicCamera-arview")
        }
    }
}

struct ARViewerView: View {
    @State private var arURL: URL?
    @State private var preparing = false
    @State private var errorMessage: String?

    var body: some View {
        ScanGalleryView(
            onSelectCloud: { prepare(.cloud($0, $1)) },
            onSelectMesh: { prepare(.mesh($0, $1)) },
            dismissOnSelect: false,
            title: "View in AR")
        .overlay {
            if preparing {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    ProgressView("Preparing AR…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding(22)
                        .glassPanel(corner: 16, elevated: true)
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { arURL != nil },
            set: { if !$0 { arURL = nil } })) {
            if let arURL { ARQuickLookView(url: arURL).ignoresSafeArea() }
        }
        .alert("AR preview failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    /// Exports the picked model off the main thread (USDZ writing routes through
    /// ModelIO — wrapped in an autorelease pool so its temporaries are reclaimed
    /// on the background thread), then presents AR Quick Look.
    private func prepare(_ pick: GalleryPick) {
        preparing = true
        let box = UncheckedSendableBox(pick)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                autoreleasepool {
                    do { return .ready(try ARQuickLookExport.usdz(for: box.value)) }
                    catch { return .failed(error.localizedDescription) }
                }
            }.value
            preparing = false
            switch outcome {
            case .ready(let url): arURL = url
            case .failed(let message): errorMessage = message
            }
        }
    }

    /// `Result` needs a `Failure: Error`; this carries a plain Sendable message.
    private enum Outcome: Sendable {
        case ready(URL)
        case failed(String)
    }
}
