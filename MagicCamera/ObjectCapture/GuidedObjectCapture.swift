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
    var resultURL: URL?

    let session = ObjectCaptureSession()

    @ObservationIgnored private let imagesDirectory: URL
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
        modelURL = work.appendingPathComponent("model.usdz")
    }

    // MARK: - Capture controls

    /// Starts the capture session exactly once, on first appearance.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        var configuration = ObjectCaptureSession.Configuration()
        configuration.isOverCaptureEnabled = true
        session.start(imagesDirectory: imagesDirectory, configuration: configuration)
    }

    /// Advances ready → detecting → capturing as the user taps through.
    func advance() {
        switch session.state {
        case .ready:     _ = session.startDetecting()
        case .detecting: session.startCapturing()
        default:         break
        }
    }

    func beginNewPass() { session.beginNewScanPass() }
    func finishCapture() { session.finish() }

    var userCompletedPass: Bool { session.userCompletedScanPass }

    // MARK: - Session state

    func observeState() async {
        for await state in session.stateUpdates {
            apply(state)
        }
    }

    private func apply(_ state: ObjectCaptureSession.CaptureState) {
        switch state {
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
        do {
            let photogrammetry = try PhotogrammetrySession(input: imagesDirectory)
            self.photogrammetry = photogrammetry
            try photogrammetry.process(requests: [.modelFile(url: modelURL, detail: .reduced)])
            for try await output in photogrammetry.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    reconstructProgress = fraction
                case .processingComplete:
                    resultURL = modelURL
                    phase = .done
                case .requestError(_, let error):
                    phase = .failed(error.localizedDescription)
                default:
                    break
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
        .fullScreenCover(isPresented: $showAR) {
            if let url = model.resultURL { ARQuickLookView(url: url).ignoresSafeArea() }
        }
    }

    // MARK: - Capture

    private var captureSurface: some View {
        ZStack {
            ObjectCaptureView(session: model.session).ignoresSafeArea()
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
