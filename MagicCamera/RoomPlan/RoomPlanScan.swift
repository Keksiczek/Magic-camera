//
//  RoomPlanScan.swift
//  Magic Camera
//
//  Room scanning via Apple's RoomPlan: RoomCaptureView drives the guided scan
//  UI itself; when the user finishes, the processed CapturedRoom is exported
//  to USDZ (parametric walls/doors/openings, mesh fallback) for AR Quick Look
//  and sharing. Requires a LiDAR device; the simulator and non-LiDAR devices
//  get an explanatory placeholder.
//

import SwiftUI

#if canImport(RoomPlan)
import RoomPlan
#endif

struct RoomPlanEntry: View {
    var body: some View {
        Group {
            #if canImport(RoomPlan)
            if RoomCaptureSession.isSupported {
                RoomPlanScanView()
            } else {
                UnsupportedView(
                    title: "Room Plan unavailable",
                    message: "Room scanning needs a LiDAR iPhone or iPad Pro. This device (or the simulator) doesn't support RoomPlan.")
            }
            #else
            UnsupportedView(
                title: "Room Plan unavailable",
                message: "RoomPlan isn't available in this build environment.")
            #endif
        }
        .navigationTitle("Room Plan")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if canImport(RoomPlan)

@MainActor
@Observable
final class RoomPlanModel: NSObject {
    enum Phase: Equatable {
        case scanning
        case processing
        case done
        case failed(String)
    }

    var phase: Phase = .scanning
    var exportURL: URL?
    /// The processed room converted to the app's classified mesh — what "Save
    /// to scan library" persists so the room joins the other scan modes.
    var libraryMesh: MeshData?
    /// "4 walls · 6 objects · 1.2k tris" line for the done panel.
    var roomSummary: String?
    var savedToLibrary = false
    var saveNote: String?

    @ObservationIgnored weak var captureView: RoomCaptureView?

    func attach(_ view: RoomCaptureView) {
        captureView = view
        view.delegate = self
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Stops the session; RoomCaptureView then processes the captured data and
    /// calls back through the delegate with the final room.
    func finish() {
        phase = .processing
        captureView?.captureSession.stop()
    }

    func cancel() {
        captureView?.captureSession.stop(pauseARSession: true)
    }

    fileprivate func handleProcessed(_ room: CapturedRoom?, error: Error?) {
        if let error {
            phase = .failed(error.localizedDescription)
            return
        }
        guard let room else {
            phase = .failed("Room processing produced no result.")
            return
        }
        // Bridge into the spatial-scan world: a classified box mesh built from
        // the parametric elements, ready to save into the shared scan library.
        let mesh = CapturedRoomMesh.meshData(from: room)
        if !mesh.isEmpty {
            libraryMesh = mesh
            roomSummary = "\(room.walls.count) walls · \(room.objects.count) objects"
                + " · \(MeasurementFormat.count(mesh.triangleCount)) tris"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagicCamera-room.usdz")
        try? FileManager.default.removeItem(at: url)
        do {
            // Parametric gives clean walls/doors/windows; fall back to the raw
            // mesh when the scan has too little structure for parametrisation.
            do { try room.export(to: url, exportOptions: .parametric) }
            catch { try room.export(to: url, exportOptions: .mesh) }
            exportURL = url
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Saves the converted room mesh into the same library the spatial scans
    /// use, so it can be re-opened, measured, merged and exported from there.
    func saveToLibrary() {
        guard let mesh = libraryMesh, !savedToLibrary else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        do {
            let url = try MeshStore.save(mesh, name: "Room \(formatter.string(from: Date()))")
            if let png = ThumbnailRenderer.png(for: mesh) { Thumbnails.write(png, for: url) }
            savedToLibrary = true
            saveNote = "Saved — open it from Spatial Scan ▸ gallery to view, measure or export."
        } catch {
            saveNote = "Save failed: \(error.localizedDescription)"
        }
    }
}

/// RoomCaptureViewDelegate inherits NSCoding (the view can be state-restored),
/// hence the stub coder conformances.
extension RoomPlanModel: RoomCaptureViewDelegate {
    nonisolated func encode(with coder: NSCoder) {}
    nonisolated convenience init?(coder: NSCoder) { nil }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData,
                                 error: (any Error)?) -> Bool {
        true   // let RoomCaptureView run its built-in processing + presentation
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom,
                                 error: (any Error)?) {
        let roomBox = UncheckedSendableBox(processedResult)
        let errorBox = UncheckedSendableBox(error)
        Task { @MainActor in
            self.handleProcessed(roomBox.value, error: errorBox.value)
        }
    }
}

struct RoomPlanScanView: View {
    @State private var model = RoomPlanModel()
    @State private var showAR = false

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(model: model).ignoresSafeArea()
            // While scanning, RoomCaptureView draws its own coaching text and a
            // growing room miniature along the bottom — keep that visible. Our
            // only control then is the Finish button up in the nav bar.
            if model.phase != .scanning {
                VStack {
                    Spacer()
                    controls
                }
                .padding(.bottom, 8)
            }
        }
        .background(Theme.background)
        .toolbar {
            if model.phase == .scanning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.impact(.medium); model.finish() } label: {
                        Label("Finish", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                }
            }
        }
        .onDisappear { model.cancel() }
        .fullScreenCover(isPresented: $showAR) {
            if let url = model.exportURL { ARQuickLookView(url: url).ignoresSafeArea() }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .scanning:
                EmptyView()

            case .processing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                    Text("Processing room…").font(.headline).foregroundStyle(Theme.textPrimary)
                }
                .padding(.vertical, 14)

            case .done:
                if let summary = model.roomSummary {
                    StatusBadge(text: summary, systemImage: "house")
                }
                HStack(spacing: 12) {
                    Button { showAR = true } label: {
                        Label("View in AR", systemImage: "arkit")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    if let url = model.exportURL {
                        ShareLink(item: url) {
                            Label("Share USDZ", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .padding(.horizontal, 16)

                if model.libraryMesh != nil {
                    Button { Haptics.impact(.light); model.saveToLibrary() } label: {
                        Label(model.savedToLibrary ? "Saved to scan library" : "Save to scan library",
                              systemImage: model.savedToLibrary ? "checkmark" : "tray.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.savedToLibrary)
                    .padding(.horizontal, 16)
                }
                if let note = model.saveNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

            case .failed(let message):
                Text("Room scan failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

private struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let model: RoomPlanModel

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        model.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

#endif
