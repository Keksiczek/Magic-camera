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
    var resultURL: URL?

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
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        var configuration = ObjectCaptureSession.Configuration()
        configuration.isOverCaptureEnabled = true
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

    // MARK: - Keep-alive during reconstruction

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Keeps the screen awake and buys background time so a reconstruction
    /// survives the user briefly leaving the app or the screen dimming.
    private func beginBackgroundWork() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Photogrammetry") { [weak self] in
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

    private func reconstruct() async {
        phase = .reconstructing
        reconstructProgress = 0
        estimatedRemaining = nil
        // Release the capture session BEFORE photogrammetry starts. Both compete
        // for the GPU/ANE and memory; keeping the capture session alive is what
        // made reconstruction stall at a fixed percentage and never finish.
        session = nil
        beginBackgroundWork()
        defer { endBackgroundWork() }
        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpointDirectory
            let photogrammetry = try PhotogrammetrySession(input: imagesDirectory,
                                                           configuration: configuration)
            self.photogrammetry = photogrammetry
            // Grab the outputs stream before `process` so early messages (errors,
            // first progress) can't be published before anyone is listening.
            let outputs = photogrammetry.outputs
            // NOTE: the iOS SDK exposes only `.reduced` detail (checked in the
            // RealityFoundation swiftinterface); higher levels are Mac-only.
            try photogrammetry.process(requests: [.modelFile(url: modelURL, detail: .reduced)])
            for try await output in outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    reconstructProgress = fraction
                case .requestProgressInfo(_, let info):
                    estimatedRemaining = info.estimatedRemainingTime
                case .requestComplete(_, let result):
                    // The model-file request finished — capture the URL it wrote.
                    if case .modelFile(let url) = result { resultURL = url }
                case .processingComplete:
                    // All requests done. Succeed only if a model was actually written,
                    // otherwise report it instead of showing an empty "done".
                    if resultURL != nil || FileManager.default.fileExists(atPath: modelURL.path) {
                        resultURL = resultURL ?? modelURL
                        phase = .done
                    } else {
                        phase = .failed("Reconstruction finished but produced no model.")
                    }
                case .requestError(_, let error):
                    phase = .failed(error.localizedDescription)
                case .processingCancelled:
                    phase = .failed("Reconstruction was cancelled.")
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
        photogrammetry = nil
    }
}

@available(iOS 17.0, *)
struct GuidedObjectCaptureView: View {
    @State private var model = ObjectCaptureModel()
    @State private var showAR = false

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
        .task {
            model.start()
            await model.observeState()
        }
        .onDisappear { model.cancel() }
        .fullScreenCover(isPresented: $showAR) {
            if let url = model.resultURL { ARQuickLookView(url: url).ignoresSafeArea() }
        }
    }

    // MARK: - Capture

    private var captureSurface: some View {
        ZStack {
            if let session = model.session {
                ObjectCaptureView(session: session).ignoresSafeArea()
            }
            VStack {
                Spacer()
                captureControls
            }
            .padding(.bottom, 8)
        }
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
                case .capturing:
                    secondaryButton("New pass", systemImage: "arrow.triangle.2.circlepath",
                                    action: model.beginNewPass)
                    primaryButton("Finish", systemImage: "checkmark", action: model.finishCapture)
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
        case .capturing:  return "Slowly orbit the object. Finish when you've covered all sides."
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
                if let remaining = model.estimatedRemaining, remaining > 1 {
                    Text("≈ \(Self.remainingText(remaining)) left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("Photogrammetry runs on-device and can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

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

            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func secondaryButton(_ title: String, systemImage: String,
                                 action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

#endif
