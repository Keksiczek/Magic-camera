//
//  LiveDepthCameraViewModel.swift
//  Magic Camera
//
//  Drives Mode 1: owns the AR depth engine, the Metal renderer and (when
//  active) the video recorder, exposes effect settings + status, and runs the
//  tap-to-measure tool.
//

import Observation
import SwiftUI
import simd

@MainActor
@Observable
final class LiveDepthCameraViewModel {
    var settings = EffectSettings()
    var status: DepthSessionStatus = .initializing
    var isRecording = false
    var toast: String?

    // Measure tool
    var measureEnabled = false
    var measureScreenPoints: [CGPoint] = []
    var measureDistance: Float?

    @ObservationIgnored let engine = DepthEngine()
    @ObservationIgnored let renderer: EffectRenderer?
    @ObservationIgnored var recorder: VideoRecorder?
    @ObservationIgnored var drawablePixelSize: CGSize = .zero
    @ObservationIgnored private var measurePoints: [SIMD3<Float>] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    var isSupported: Bool { engine.isSupported && renderer != nil }

    init() {
        renderer = EffectRenderer()
        engine.statusHandler = { [weak self] status in
            self?.status = status
        }
    }

    // MARK: - Session lifecycle

    func start() {
        guard isSupported else { status = .unsupported; return }
        engine.start()
    }

    func stop() {
        if isRecording { stopRecording() }
        engine.pause()
    }

    func select(_ kind: DepthEffectKind) { settings.kind = kind }

    // MARK: - Photo

    func capturePhoto() {
        guard let renderer, let frame = engine.currentFrame else {
            showToast("No frame yet"); return
        }
        let size = drawablePixelSize == .zero ? CGSize(width: 1170, height: 2532) : drawablePixelSize
        guard let image = renderer.snapshot(frame: frame, settings: settings, size: size) else {
            showToast("Capture failed"); return
        }
        MediaSaver.savePhoto(image) { [weak self] ok in
            self?.showToast(ok ? "Photo saved" : "Save failed — check Photos permission")
        }
    }

    // MARK: - Video

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    private func startRecording() {
        let size = drawablePixelSize == .zero ? CGSize(width: 1170, height: 2532) : drawablePixelSize
        guard let recorder = VideoRecorder(size: size) else {
            showToast("Recorder unavailable"); return
        }
        recorder.start()
        self.recorder = recorder
        isRecording = true
        showToast("Recording…")
    }

    private func stopRecording() {
        guard let recorder else { return }
        isRecording = false
        recorder.finish { [weak self] url in
            self?.recorder = nil
            guard let url else { self?.showToast("Recording failed"); return }
            MediaSaver.saveVideo(url) { ok in
                self?.showToast(ok ? "Video saved" : "Save failed — check Photos permission")
            }
        }
    }

    // MARK: - Measure

    func toggleMeasure() {
        measureEnabled.toggle()
        if !measureEnabled { clearMeasure() }
    }

    func clearMeasure() {
        measurePoints = []
        measureScreenPoints = []
        measureDistance = nil
    }

    func handleTap(at point: CGPoint, viewSize: CGSize) {
        guard measureEnabled, let frame = engine.currentFrame else { return }
        guard let world = DepthSampler.worldPoint(frame: frame, viewPoint: point, viewSize: viewSize) else {
            showToast("No depth at that point"); return
        }
        if measurePoints.count >= 2 { clearMeasure() }
        measurePoints.append(world)
        measureScreenPoints.append(point)
        if measurePoints.count == 2 {
            measureDistance = simd_distance(measurePoints[0], measurePoints[1])
        }
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
