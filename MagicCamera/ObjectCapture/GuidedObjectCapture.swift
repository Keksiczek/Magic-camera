//
//  GuidedObjectCapture.swift
//  Magic Camera
//
//  DEVICE-ONLY (guarded out of simulator builds): a guided RealityKit Object
//  Capture flow — frame the object, detect its bounding box, orbit to capture,
//  then run PhotogrammetrySession to reconstruct a photo-real USDZ that opens in
//  AR Quick Look or shares out.
//
//  NOTE: `ObjectCaptureSession` is absent from the simulator SDK, so this code is
//  compiled only for physical devices and could NOT be build-verified here. It
//  follows the documented iOS 17 API; verify and tune on a real iPhone/iPad Pro.
//

#if !targetEnvironment(simulator)

import QuickLook
import RealityKit
import SwiftUI
import UIKit

@available(iOS 17.0, *)
enum ObjectCaptureSupport {
    @MainActor static var isAvailable: Bool { ObjectCaptureSession.isSupported }
}

@available(iOS 17.0, *)
@MainActor
@Observable
final class ObjectCaptureModel {
    enum Phase: Equatable {
        case ready, detecting, capturing, finishing
        case reconstructing
        case done
        case failed(String)
    }

    var phase: Phase = .ready
    var reconstructProgress: Double = 0
    /// Photogrammetry's own remaining-time estimate, when it offers one.
    var estimatedRemaining: TimeInterval?
    /// Human-readable photogrammetry stage ("Aligning photos", …) — proof of
    /// life while the percentage crawls on long reconstructions.
    var processingStage: String?
    /// Reassurance shown when the pipeline has been quiet for a while but is
    /// not yet considered dead — long stages legitimately sit at one
    /// percentage for minutes on big captures.
    var stallHint: String?
    var resultURL: URL?
    /// Library import state — the USDZ is read back via ModelIO and saved as a
    /// (textured) mesh so the object joins the scan gallery.
    var isImporting = false
    var savedToLibrary = false
    var saveNote: String?

    /// Released (set to nil) the moment capture completes: `ObjectCaptureSession`
    /// keeps the camera pipeline and a large GPU/Neural-Engine footprint alive,
    /// and holding it through `PhotogrammetrySession` starves reconstruction —
    /// the progress bar then crawls and never reaches the end on device.
    private(set) var session: ObjectCaptureSession?

    @ObservationIgnored private let imagesDirectory: URL
    @ObservationIgnored private let checkpointDirectory: URL
    @ObservationIgnored private let modelURL: URL
    @ObservationIgnored private var photogrammetry: PhotogrammetrySession?
    @ObservationIgnored private var hasStarted = false
    // Stall guard bookkeeping for the reconstruction watchdog.
    @ObservationIgnored private var lastProgressDate = Date()
    @ObservationIgnored private var stallCancelled = false

    init() {
        // No side effects here. SwiftUI re-evaluates a `@State` default expression
        // every time the enclosing view's `init` runs (on each parent re-render),
        // constructing several throwaway models before keeping one. Starting the
        // capture session in `init` therefore spins up — and immediately tears down —
        // multiple `ObjectCaptureSession`s, which crashes the pipeline just as its
        // onboarding/feedback ("calibration") UI appears. The session is started once
        // from `start()` when the view actually appears.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObjectCapture-\(UUID().uuidString)", isDirectory: true)
        imagesDirectory = work.appendingPathComponent("Images", isDirectory: true)
        checkpointDirectory = work.appendingPathComponent("Checkpoints", isDirectory: true)
        modelURL = work.appendingPathComponent("model.usdz")
    }

    // MARK: - Capture controls

    /// Starts the capture session exactly once, on first appearance.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        sweepStaleWorkDirectories()
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        var configuration = ObjectCaptureSession.Configuration()
        // Over-capture shoots extra orbits' worth of images for a later
        // Mac-quality reconstruction. This flow reconstructs on the phone
        // only, where the surplus images multiply photogrammetry's work —
        // a major contributor to point-cloud stalls at a fixed percentage.
        configuration.isOverCaptureEnabled = false
        // Sharing the checkpoint directory with PhotogrammetrySession lets the
        // capture session pre-compute reconstruction data while scanning, which
        // cuts the on-device reconstruction time substantially.
        configuration.checkpointDirectory = checkpointDirectory
        let session = ObjectCaptureSession()
        self.session = session
        session.start(imagesDirectory: imagesDirectory, configuration: configuration)
    }

    /// Advances ready → detecting → capturing as the user taps through.
    func advance() {
        guard let session else { return }
        switch session.state {
        case .ready:     _ = session.startDetecting()
        case .detecting: session.startCapturing()
        default:         break
        }
    }

    func beginNewPass() { session?.beginNewScanPass() }
    func finishCapture() { session?.finish() }

    var userCompletedPass: Bool { session?.userCompletedScanPass ?? false }

    /// Tears down whatever is still running — called when the view disappears so
    /// neither the capture session nor a photogrammetry job keeps running headless.
    func cancel() {
        photogrammetry?.cancel()
        session?.cancel()
        session = nil
        endBackgroundWork()
    }

    /// User-initiated stop of a running reconstruction; the output stream then
    /// delivers `.processingCancelled`, which surfaces as a failed state.
    func cancelReconstruction() {
        photogrammetry?.cancel()
    }

    // MARK: - Temp hygiene

    /// Every capture run writes hundreds of full-resolution HEICs plus
    /// checkpoints into tmp, and abandoned runs (cancel, crash, watchdog kill)
    /// leave them behind — a few attempts add up to gigabytes. iOS only purges
    /// tmp under pressure, and a storage-starved photogrammetry run crawls or
    /// wedges mid-stage, so each new capture sweeps every other run's folder.
    private func sweepStaleWorkDirectories() {
        let own = imagesDirectory.deletingLastPathComponent().lastPathComponent
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: fm.temporaryDirectory, includingPropertiesForKeys: nil) else { return }
            for entry in entries
            where entry.lastPathComponent.hasPrefix("ObjectCapture-")
                && entry.lastPathComponent != own {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Reconstruction input

    /// On-device photogrammetry slows superlinearly with image count — the
    /// multi-pass captures (300+ shots) are the ones whose "preparing" phase
    /// sits at one percentage long enough to look dead. Above this count an
    /// evenly strided subset is fed in instead (sequential order preserved).
    private nonisolated static let maxReconstructionImages = 160

    /// Directory to feed photogrammetry: the full capture when small enough,
    /// otherwise a strided subset hardlinked into `ReconInput` inside the work
    /// folder. Returns the total image count alongside when subsetting.
    private nonisolated static func reconstructionInput(imagesDirectory: URL,
                                                        workDirectory: URL) -> (url: URL, subsetOf: Int?) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: imagesDirectory,
                                                        includingPropertiesForKeys: nil) else {
            return (imagesDirectory, nil)
        }
        let images = entries
            .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard images.count > maxReconstructionImages else { return (imagesDirectory, nil) }

        let subsetDirectory = workDirectory.appendingPathComponent("ReconInput", isDirectory: true)
        do {
            try? fm.removeItem(at: subsetDirectory)
            try fm.createDirectory(at: subsetDirectory, withIntermediateDirectories: true)
            let stride = Double(images.count) / Double(maxReconstructionImages)
            var linked = 0
            var cursor = 0.0
            while linked < maxReconstructionImages && Int(cursor) < images.count {
                let source = images[Int(cursor)]
                let destination = subsetDirectory.appendingPathComponent(source.lastPathComponent)
                do { try fm.linkItem(at: source, to: destination) }
                catch { try fm.copyItem(at: source, to: destination) }
                linked += 1
                cursor += stride
            }
            guard linked > 0 else { return (imagesDirectory, nil) }
            return (subsetDirectory, images.count)
        } catch {
            return (imagesDirectory, nil)
        }
    }

    // MARK: - Keep-alive during reconstruction

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Keeps the screen awake and buys background time so a reconstruction
    /// survives the user briefly leaving the app or the screen dimming.
    private func beginBackgroundWork() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Photogrammetry") { [weak self] in
            // Background time is up. A photogrammetry job still churning here
            // keeps the process busy past the system's 5 s exit deadline and
            // the watchdog kills the app (0x8BADF00D "failed to terminate
            // gracefully") — cancel it before giving the time back.
            self?.photogrammetry?.cancel()
            self?.endBackgroundWork()
        }
    }

    private func endBackgroundWork() {
        UIApplication.shared.isIdleTimerDisabled = false
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Session state

    func observeState() async {
        guard let session else { return }
        for await state in session.stateUpdates {
            apply(state)
            // Stop observing on terminal states so this loop does not keep the
            // session alive after it has been released for reconstruction.
            if case .completed = state { break }
            if case .failed = state { break }
        }
    }

    private func apply(_ state: ObjectCaptureSession.CaptureState) {
        switch state {
        case .initializing:      break   // session warming up; keep the initial phase
        case .ready:             phase = .ready
        case .detecting:         phase = .detecting
        case .capturing:         phase = .capturing
        case .finishing:         phase = .finishing
        case .completed:         Task { await reconstruct() }
        case .failed(let error): phase = .failed(error.localizedDescription)
        @unknown default:        break
        }
    }

    // MARK: - Photogrammetry

    private static let stallMessage = """
        Reconstruction went quiet and was stopped. Try a fresh capture with one \
        steady orbit (extra passes multiply the processing work), keep the app \
        in the foreground, and give the phone a moment to cool down or charge.
        """

    private func reconstruct() async {
        phase = .reconstructing
        reconstructProgress = 0
        estimatedRemaining = nil
        processingStage = nil
        stallHint = nil
        // Release the capture session BEFORE photogrammetry starts. Both compete
        // for the GPU/ANE and memory; keeping the capture session alive is what
        // made reconstruction stall at a fixed percentage and never finish.
        session = nil
        beginBackgroundWork()
        defer { endBackgroundWork() }
        do {
            // Cap the input set off-main (directory listing + hardlinks).
            let images = imagesDirectory
            let work = imagesDirectory.deletingLastPathComponent()
            let input = await Task.detached(priority: .userInitiated) {
                Self.reconstructionInput(imagesDirectory: images, workDirectory: work)
            }.value

            var configuration = PhotogrammetrySession.Configuration()
            if input.subsetOf == nil {
                // Capture-time checkpoints index the full image set; they only
                // apply when reconstructing from exactly that set.
                configuration.checkpointDirectory = checkpointDirectory
            }
            // ObjectCaptureSession shoots in spatial order; telling photogrammetry
            // so skips the expensive unordered image-matching pass.
            configuration.sampleOrdering = .sequential
            if let total = input.subsetOf {
                processingStage = "Using \(Self.maxReconstructionImages) of \(total) photos"
            }
            let photogrammetry = try PhotogrammetrySession(input: input.url,
                                                           configuration: configuration)
            self.photogrammetry = photogrammetry
            // Grab the outputs stream before `process` so early messages (errors,
            // first progress) can't be published before anyone is listening.
            let outputs = photogrammetry.outputs
            // Stall guard. Photogrammetry legitimately goes quiet for minutes
            // inside one stage on big captures — the old 3-minute cutoff was
            // killing healthy runs at a fixed percentage. Reassure at 2.5 min,
            // cancel only after 9 minutes of true silence, and if even the
            // cancel is ignored, force the UI out of the frozen state.
            lastProgressDate = Date()
            stallCancelled = false
            let watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, self.phase == .reconstructing else { return }
                    let quiet = Date().timeIntervalSince(self.lastProgressDate)
                    if quiet > 540 {
                        self.stallCancelled = true
                        self.photogrammetry?.cancel()
                        // A cancelled session normally ends the output stream
                        // with `.processingCancelled`; when even that never
                        // arrives, unfreeze the UI directly.
                        try? await Task.sleep(for: .seconds(60))
                        if !Task.isCancelled, self.phase == .reconstructing {
                            self.photogrammetry = nil
                            self.phase = .failed(Self.stallMessage)
                        }
                        return
                    }
                    if quiet > 150 {
                        self.stallHint = "Still working — big captures can sit at one percentage for several minutes."
                    }
                }
            }
            defer { watchdog.cancel() }
            // NOTE: the iOS SDK exposes only `.reduced` detail (checked in the
            // RealityFoundation swiftinterface); higher levels are Mac-only.
            try photogrammetry.process(requests: [.modelFile(url: modelURL, detail: .reduced)])
            for try await output in outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    reconstructProgress = fraction
                    lastProgressDate = Date()
                    stallHint = nil
                case .requestProgressInfo(_, let info):
                    estimatedRemaining = info.estimatedRemainingTime
                    processingStage = Self.stageLabel(info.processingStage) ?? processingStage
                    lastProgressDate = Date()
                    stallHint = nil
                case .requestComplete(_, let result):
                    // The model-file request finished — capture the URL it wrote.
                    if case .modelFile(let url) = result { resultURL = url }
                case .processingComplete:
                    // All requests done. Succeed only if a model was actually written,
                    // otherwise report it instead of showing an empty "done". The
                    // watchdog may already have force-failed this run — don't revive it.
                    guard phase == .reconstructing else { break }
                    if resultURL != nil || FileManager.default.fileExists(atPath: modelURL.path) {
                        resultURL = resultURL ?? modelURL
                        phase = .done
                    } else {
                        phase = .failed("Reconstruction finished but produced no model.")
                    }
                case .requestError(_, let error):
                    guard phase == .reconstructing else { break }
                    phase = .failed(error.localizedDescription)
                case .processingCancelled:
                    guard phase == .reconstructing else { break }
                    phase = .failed(stallCancelled ? Self.stallMessage : "Reconstruction was cancelled.")
                default:
                    break
                }
            }
            // The output stream ended. If no terminal state was reached the session
            // stalled — almost always too few usable images — so surface it instead of
            // leaving the UI frozen on the last progress value (e.g. stuck near 20%).
            if phase == .reconstructing {
                phase = .failed("Reconstruction stopped early. Capture more overlapping photos, all the way around the object in even lighting.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        stallHint = nil
        photogrammetry = nil
    }

    // MARK: - Library save

    /// Imports the reconstructed USDZ back as a textured mesh and saves it
    /// into the scan library, alongside spatial scans and rooms.
    func saveToLibrary() {
        guard let url = resultURL, !savedToLibrary, !isImporting else { return }
        isImporting = true
        saveNote = nil
        Task { [weak self] in
            let imported = await Task.detached(priority: .userInitiated) {
                USDZMeshImporter.importModel(from: url)
            }.value
            guard let self else { return }
            self.isImporting = false
            guard let imported, !imported.mesh.isEmpty else {
                self.saveNote = "Couldn't read the model back for the library."
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            do {
                let saved = try MeshStore.save(imported.mesh, textured: imported.textured,
                                               name: "Object \(formatter.string(from: Date()))")
                if let png = ThumbnailRenderer.png(for: imported.mesh) {
                    Thumbnails.write(png, for: saved)
                }
                self.savedToLibrary = true
                self.saveNote = "Saved — open it in Spatial Scan ▸ gallery to measure, edit or re-export."
            } catch {
                self.saveNote = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    /// Readable label for a photogrammetry processing stage.
    private static func stageLabel(_ stage: PhotogrammetrySession.Output.ProcessingStage?) -> String? {
        switch stage {
        case .preProcessing:        return "Preparing photos"
        case .imageAlignment:       return "Aligning photos"
        case .pointCloudGeneration: return "Building point cloud"
        case .meshGeneration:       return "Building mesh"
        case .textureMapping:       return "Mapping texture"
        case .optimization:         return "Optimizing model"
        default:                    return nil
        }
    }
}

@available(iOS 17.0, *)
struct GuidedObjectCaptureView: View {
    @State private var model = ObjectCaptureModel()
    @State private var showAR = false
    /// Bumped by "Scan again" — re-runs the `.task(id:)` against a fresh model.
    @State private var generation = 0

    var body: some View {
        ZStack {
            switch model.phase {
            case .reconstructing, .done, .failed:
                resultSurface
            default:
                captureSurface
            }
        }
        .background(Theme.background)
        .task(id: generation) {
            model.start()
            await model.observeState()
        }
        .onDisappear { model.cancel() }
        .fullScreenCover(isPresented: $showAR) {
            if let url = model.resultURL { ARQuickLookView(url: url).ignoresSafeArea() }
        }
    }

    /// Discards the current session/result and starts a brand-new capture.
    private func restart() {
        model.cancel()
        model = ObjectCaptureModel()
        generation += 1
    }

    // MARK: - Capture

    private var captureSurface: some View {
        ZStack {
            if let session = model.session {
                ObjectCaptureView(session: session).ignoresSafeArea()
            }
            VStack {
                Spacer()
                if model.phase == .capturing {
                    capturingControls
                } else {
                    captureControls
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// While capturing, ObjectCaptureView draws its own guidance and progress
    /// dial bottom-centre — keep that visible: just two compact pills hugging
    /// the screen edges instead of a full-width panel over the system UI.
    private var capturingControls: some View {
        HStack {
            compactPill("New pass", systemImage: "arrow.triangle.2.circlepath",
                        prominent: false, action: model.beginNewPass)
            Spacer()
            compactPill("Finish", systemImage: "checkmark",
                        prominent: true, action: model.finishCapture)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var captureControls: some View {
        VStack(spacing: 12) {
            Text(hint)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                switch model.phase {
                case .ready:
                    primaryButton("Detect object", systemImage: "viewfinder", action: model.advance)
                case .detecting:
                    primaryButton("Start capture", systemImage: "camera.aperture", action: model.advance)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var hint: String {
        switch model.phase {
        case .ready:      return "Place the object on a clear surface and frame it in view."
        case .detecting:  return "Adjust the box to enclose the object, then start the capture."
        case .finishing:  return "Finishing capture…"
        default:          return ""
        }
    }

    // MARK: - Result / reconstruction

    private var resultSurface: some View {
        VStack(spacing: 18) {
            switch model.phase {
            case .reconstructing:
                ProgressView(value: model.reconstructProgress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .padding(.horizontal, 40)
                Text("Building model… \(Int(model.reconstructProgress * 100))%")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let stage = model.processingStage {
                    Text(stage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.opacity)
                }
                if let remaining = model.estimatedRemaining, remaining > 1 {
                    Text("≈ \(Self.remainingText(remaining)) left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let hint = model.stallHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(Theme.accentWarm)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Text("Photogrammetry runs on-device and can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button(role: .destructive) { model.cancelReconstruction() } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .tint(.red)
                .padding(.top, 8)

            case .done:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Model ready").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 12) {
                    Button { showAR = true } label: {
                        Label("View in AR", systemImage: "arkit")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    if let url = model.resultURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                Button { Haptics.impact(.light); model.saveToLibrary() } label: {
                    HStack(spacing: 8) {
                        if model.isImporting {
                            ProgressView().controlSize(.small).tint(Theme.textPrimary)
                        } else {
                            Image(systemName: model.savedToLibrary ? "checkmark" : "tray.and.arrow.down")
                        }
                        Text(model.savedToLibrary ? "Saved to scan library"
                             : model.isImporting ? "Importing…" : "Save to scan library")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(model.savedToLibrary || model.isImporting)
                if let note = model.saveNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                scanAgainButton

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Theme.accentWarm)
                Text("Capture failed").font(.title3.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                scanAgainButton

            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanAgainButton: some View {
        Button { Haptics.impact(.light); restart() } label: {
            Label("Scan again", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Theme.surface, in: Capsule())
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    /// "3 min" / "40 s" from a remaining-time estimate.
    private static func remainingText(_ seconds: TimeInterval) -> String {
        seconds >= 90 ? "\(Int((seconds / 60).rounded())) min" : "\(Int(seconds.rounded())) s"
    }

    // MARK: - Buttons

    private func primaryButton(_ title: String, systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.medium); action() } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }

    /// Self-sized capsule for the capture phase — hugs a screen edge so the
    /// session's own bottom-centre progress dial stays unobstructed.
    private func compactPill(_ title: String, systemImage: String, prominent: Bool,
                             action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(prominent ? .medium : .light); action() } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule())
                .foregroundStyle(prominent ? AnyShapeStyle(Color.black) : AnyShapeStyle(Theme.textPrimary))
        }
        .buttonStyle(.plain)
    }
}

#endif
