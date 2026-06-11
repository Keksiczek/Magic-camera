//
//  RoomPlanScan.swift
//  Magic Camera
//
//  Room scanning via Apple's RoomPlan: RoomCaptureView drives the guided scan
//  UI itself; when the user finishes, the processed CapturedRoom is exported
//  to USDZ (parametric walls/doors/openings, mesh fallback) for AR Quick Look
//  and sharing, and can be saved into the shared scan library as a classified
//  mesh. The AR session is app-owned, which enables two extras:
//    · multi-room — consecutive rooms share one coordinate space, so
//      StructureBuilder can merge them into a single structure;
//    · hybrid capture — LiDAR depth frames are fed to a ScanRecorder while
//      RoomPlan scans, yielding a colour point cloud of the same walkthrough.
//  Requires a LiDAR device; the simulator and non-LiDAR devices get an
//  explanatory placeholder.
//

import SwiftUI

#if canImport(RoomPlan)
import ARKit
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

/// Mutable timestamp the point-feed timer uses to skip already-processed
/// frames. Confined to the timer's serial queue; the compiler can't see that.
private final class FrameGate: @unchecked Sendable {
    var lastTimestamp: TimeInterval = 0
}

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
    /// The processed room (or merged structure) converted to the app's
    /// classified mesh — what "Save to scan library" persists.
    var libraryMesh: MeshData?
    /// "4 walls · 6 objects · 1.2k tris" line for the done panel.
    var roomSummary: String?
    var savedToLibrary = false
    var saveNote: String?

    /// Rooms completed in this session. They share the app-owned AR session's
    /// coordinate space, which is what StructureBuilder needs to merge them.
    var completedRooms: [CapturedRoom] = []
    var isBuildingStructure = false

    /// Live count of LiDAR points fused by the hybrid recorder while scanning.
    var hybridPointCount = 0
    var savedCloud = false
    var isSavingCloud = false

    /// App-owned AR session handed to RoomCaptureView, so it survives across
    /// rooms (multi-room merge) and can feed the point recorder.
    @ObservationIgnored let arSession = ARSession()
    @ObservationIgnored let recorder = ScanRecorder()
    @ObservationIgnored private var pointFeedTimer: DispatchSourceTimer?
    @ObservationIgnored weak var captureView: RoomCaptureView?

    override init() {
        super.init()
        recorder.onProgress = { [weak self] count in
            self?.hybridPointCount = count
        }
    }

    func attach(_ view: RoomCaptureView) {
        captureView = view
        view.delegate = self
        // One configure only: it resets accumulation, and the cloud should
        // keep growing across consecutive rooms (one walkthrough, one cloud).
        recorder.configure(ScanQuality.balanced.config)
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        startPointFeed()
    }

    /// Stops the session; RoomCaptureView then processes the captured data and
    /// calls back through the delegate with the final room. The AR session
    /// keeps running so a follow-up room shares this one's coordinate space.
    func finish() {
        phase = .processing
        stopPointFeed()
        captureView?.captureSession.stop(pauseARSession: false)
    }

    func cancel() {
        stopPointFeed()
        captureView?.captureSession.stop(pauseARSession: true)
    }

    /// Continues scanning the next room in the same AR world.
    func scanNextRoom() {
        guard phase == .done else { return }
        phase = .scanning
        exportURL = nil
        libraryMesh = nil
        roomSummary = nil
        savedToLibrary = false
        saveNote = nil
        captureView?.captureSession.run(configuration: RoomCaptureSession.Configuration())
        startPointFeed()
    }

    // MARK: - Hybrid point capture

    /// RoomPlan owns the frame pipeline, so depth frames are *polled* (~8 Hz)
    /// off the session instead of competing for its delegate. The recorder
    /// no-ops gracefully when RoomPlan's configuration provides no scene depth.
    private func startPointFeed() {
        guard pointFeedTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.keks.MagicCamera.roomPoints", qos: .utility))
        let sessionBox = UncheckedSendableBox(arSession)
        let recorder = recorder
        let gate = FrameGate()
        timer.setEventHandler {
            guard let frame = sessionBox.value.currentFrame,
                  frame.timestamp > gate.lastTimestamp else { return }
            gate.lastTimestamp = frame.timestamp
            recorder.process(frame: frame)
        }
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(125))
        timer.resume()
        pointFeedTimer = timer
    }

    private func stopPointFeed() {
        pointFeedTimer?.cancel()
        pointFeedTimer = nil
    }

    /// Denoises and saves the walkthrough point cloud into the scan library.
    func savePointCloud() {
        guard hybridPointCount > 0, !savedCloud, !isSavingCloud else { return }
        isSavingCloud = true
        let recorder = recorder
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                recorder.snapshotDenoised(minNeighbors: 2)
            }.value
            guard let self else { return }
            self.isSavingCloud = false
            let cloud = result.cloud
            guard !cloud.isEmpty else {
                self.saveNote = "No usable depth points were captured."
                return
            }
            do {
                let url = try ScanStore.save(cloud, name: "Room points \(Self.dateStamp())")
                if let png = ThumbnailRenderer.png(for: cloud) { Thumbnails.write(png, for: url) }
                self.savedCloud = true
                self.saveNote = "Point cloud saved · \(MeasurementFormat.count(cloud.count)) pts — find it in Spatial Scan ▸ gallery."
            } catch {
                self.saveNote = "Point cloud save failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Processing results

    fileprivate func handleProcessed(_ room: CapturedRoom?, error: Error?) {
        if let error {
            phase = .failed(error.localizedDescription)
            return
        }
        guard let room else {
            phase = .failed("Room processing produced no result.")
            return
        }
        completedRooms.append(room)
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

    // MARK: - Multi-room structure

    /// Merges every room captured this session into one CapturedStructure —
    /// they share the AR session's world space, so they land correctly placed.
    func buildStructure() {
        guard completedRooms.count >= 2, !isBuildingStructure else { return }
        isBuildingStructure = true
        saveNote = nil
        let rooms = completedRooms
        Task { [weak self] in
            do {
                let structure = try await StructureBuilder(options: [.beautifyObjects])
                    .capturedStructure(from: rooms)
                guard let self else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MagicCamera-structure.usdz")
                try? FileManager.default.removeItem(at: url)
                do { try structure.export(to: url, exportOptions: .parametric) }
                catch { try structure.export(to: url, exportOptions: .mesh) }
                self.exportURL = url
                let mesh = CapturedRoomMesh.meshData(from: structure)
                if !mesh.isEmpty {
                    self.libraryMesh = mesh
                    self.savedToLibrary = false
                    self.roomSummary = "\(rooms.count) rooms · \(structure.walls.count) walls"
                        + " · \(MeasurementFormat.count(mesh.triangleCount)) tris"
                }
                self.isBuildingStructure = false
            } catch {
                guard let self else { return }
                self.isBuildingStructure = false
                self.saveNote = "Room merge failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Library save

    /// Saves the converted room mesh into the same library the spatial scans
    /// use, so it can be re-opened, measured, merged and exported from there.
    func saveToLibrary() {
        guard let mesh = libraryMesh, !savedToLibrary else { return }
        let prefix = completedRooms.count >= 2 && roomSummary?.contains("rooms") == true
            ? "Structure" : "Room"
        do {
            let url = try MeshStore.save(mesh, name: "\(prefix) \(Self.dateStamp())")
            if let png = ThumbnailRenderer.png(for: mesh) { Thumbnails.write(png, for: url) }
            savedToLibrary = true
            saveNote = "Saved — open it from Spatial Scan ▸ gallery to view, measure or export."
        } catch {
            saveNote = "Save failed: \(error.localizedDescription)"
        }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: Date())
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
            // only controls then are the nav-bar Finish button and a small
            // hybrid point counter tucked into the bottom-leading corner.
            if model.phase == .scanning {
                if model.hybridPointCount > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            StatusBadge(text: "\(MeasurementFormat.count(model.hybridPointCount)) pts",
                                        systemImage: "circle.grid.3x3.fill")
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
            } else {
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
                doneControls

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

    @ViewBuilder
    private var doneControls: some View {
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

        HStack(spacing: 12) {
            Button { Haptics.impact(.medium); model.scanNextRoom() } label: {
                Label("Scan next room", systemImage: "plus.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)

            if model.completedRooms.count >= 2 {
                Button { Haptics.impact(.medium); model.buildStructure() } label: {
                    HStack(spacing: 8) {
                        if model.isBuildingStructure {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "square.on.square.intersection.dashed")
                        }
                        Text(model.isBuildingStructure
                             ? "Merging…" : "Merge \(model.completedRooms.count) rooms")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentWarm, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(model.isBuildingStructure)
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

        if model.hybridPointCount > 0 {
            Button { Haptics.impact(.light); model.savePointCloud() } label: {
                HStack(spacing: 8) {
                    if model.isSavingCloud {
                        ProgressView().controlSize(.small).tint(Theme.textPrimary)
                    } else {
                        Image(systemName: model.savedCloud ? "checkmark" : "circle.grid.3x3.fill")
                    }
                    Text(model.savedCloud
                         ? "Point cloud saved"
                         : "Save point cloud · \(MeasurementFormat.count(model.hybridPointCount)) pts")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(model.savedCloud || model.isSavingCloud)
            .padding(.horizontal, 16)
        }

        if let note = model.saveNote {
            Text(note)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}

private struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let model: RoomPlanModel

    func makeUIView(context: Context) -> RoomCaptureView {
        // The app-owned session keeps one world space across rooms and lets
        // the hybrid point feed read frames.
        let view = RoomCaptureView(frame: .zero, arSession: model.arSession)
        model.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

#endif
