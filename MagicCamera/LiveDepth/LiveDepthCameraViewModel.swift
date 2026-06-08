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
import UIKit
import simd

@MainActor
@Observable
final class LiveDepthCameraViewModel {
    var settings = EffectSettings()
    var status: DepthSessionStatus = .initializing
    var isRecording = false
    var toast: String?

    // Measure tool — a polyline of tap points with per-segment + total distance.
    var measureEnabled = false
    var measureScreenPoints: [CGPoint] = []
    var measureSegments: [Float] = []
    var measureTotal: Float?

    static let maxMeasurePoints = 12

    // Object detection + dimension scanner (Vision).
    var detectEnabled = false
    var detections: [DetectedObject] = []
    var measuredObjects: [MeasuredObject] = []
    var dimensionsExportURL: URL?

    static let detectionInterval: Duration = .milliseconds(280)

    @ObservationIgnored let engine = DepthEngine()
    @ObservationIgnored let renderer: EffectRenderer?
    @ObservationIgnored let detector = ObjectDetector()
    @ObservationIgnored var recorder: VideoRecorder?
    @ObservationIgnored var drawablePixelSize: CGSize = .zero
    @ObservationIgnored var measureViewSize: CGSize = .zero
    @ObservationIgnored var detectViewSize: CGSize = .zero
    @ObservationIgnored private var measurePoints: [SIMD3<Float>] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var detectionTask: Task<Void, Never>?

    var canUndoMeasure: Bool { !measurePoints.isEmpty }
    var hasMeasuredObjects: Bool { !measuredObjects.isEmpty }

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
        detectionTask?.cancel()
        detectionTask = nil
        engine.pause()
    }

    func select(_ kind: DepthEffectKind) { settings.kind = kind }

    // MARK: - Photo

    func capturePhoto() {
        guard let renderer, let frame = engine.currentFrame else {
            showToast("No frame yet"); return
        }
        let size = drawablePixelSize == .zero ? CGSize(width: 1170, height: 2532) : drawablePixelSize
        guard var image = renderer.snapshot(frame: frame, settings: settings, size: size) else {
            showToast("Capture failed"); return
        }
        // Bake the measurement polyline into the saved photo when measuring.
        if measureEnabled, measureScreenPoints.count >= 2, measureViewSize != .zero,
           let annotated = MeasureOverlayRenderer.compose(
            base: image, screenPoints: measureScreenPoints, segments: measureSegments,
            total: measureTotal, viewSize: measureViewSize) {
            image = annotated
        }
        let finalImage = image
        Task { [weak self] in
            let ok = await MediaSaver.savePhoto(finalImage)
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
        Task { [weak self] in
            let url = await recorder.finish()
            self?.recorder = nil
            guard let url else { self?.showToast("Recording failed"); return }
            let ok = await MediaSaver.saveVideo(url)
            self?.showToast(ok ? "Video saved" : "Save failed — check Photos permission")
        }
    }

    // MARK: - Measure

    func toggleMeasure() {
        measureEnabled.toggle()
        if measureEnabled { setDetect(false) }
        if !measureEnabled { clearMeasure() }
    }

    func clearMeasure() {
        measurePoints = []
        measureScreenPoints = []
        measureSegments = []
        measureTotal = nil
    }

    func undoMeasure() {
        guard !measurePoints.isEmpty else { return }
        measurePoints.removeLast()
        measureScreenPoints.removeLast()
        recomputeMeasure()
    }

    func handleTap(at point: CGPoint, viewSize: CGSize) {
        guard measureEnabled, let frame = engine.currentFrame else { return }
        measureViewSize = viewSize
        guard let world = DepthSampler.worldPoint(frame: frame, viewPoint: point, viewSize: viewSize) else {
            showToast("No depth at that point"); return
        }
        if measurePoints.count >= Self.maxMeasurePoints { clearMeasure() }
        measurePoints.append(world)
        measureScreenPoints.append(point)
        recomputeMeasure()
    }

    private func recomputeMeasure() {
        guard measurePoints.count >= 2 else {
            measureSegments = []
            measureTotal = nil
            return
        }
        var segments: [Float] = []
        segments.reserveCapacity(measurePoints.count - 1)
        for i in 1..<measurePoints.count {
            segments.append(simd_distance(measurePoints[i - 1], measurePoints[i]))
        }
        measureSegments = segments
        measureTotal = segments.reduce(0, +)
    }

    // MARK: - Object detection (Vision)

    func toggleDetect() { setDetect(!detectEnabled) }

    private func setDetect(_ enabled: Bool) {
        guard enabled != detectEnabled else { return }
        detectEnabled = enabled
        if enabled {
            measureEnabled = false
            clearMeasure()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            startDetectionLoop()
        } else {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            detectionTask?.cancel()
            detectionTask = nil
            detections = []
        }
    }

    private func startDetectionLoop() {
        detectionTask?.cancel()
        detectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.runDetectionPass()
                try? await Task.sleep(for: Self.detectionInterval)
            }
        }
    }

    private func runDetectionPass() async {
        guard detectEnabled, detectViewSize != .zero, let frame = engine.currentFrame else { return }
        let size = detectViewSize
        let orientation = CameraImageOrientation.current
        let bufferBox = UncheckedSendableBox(frame.capturedImage)
        let frameBox = UncheckedSendableBox(frame)
        let detector = self.detector

        let raws = await Task.detached(priority: .userInitiated) {
            detector.detect(pixelBuffer: bufferBox.value, orientation: orientation)
        }.value

        guard detectEnabled else { return }
        let mappedFrame = frameBox.value
        detections = raws.compactMap { raw -> DetectedObject? in
            // Vision boxes come back in oriented space; convert to native, then to view.
            let nativeBox = VisionGeometry.nativeNormalizedRect(raw.boundingBox, orientation: orientation)
            guard let rect = DepthSampler.viewRect(forImageBox: nativeBox,
                                                   frame: mappedFrame, viewSize: size) else { return nil }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let distance = DepthSampler.distance(frame: mappedFrame, viewPoint: center, viewSize: size)
            let key = "\(raw.label)-\(Int(rect.midX / 24))-\(Int(rect.midY / 24))"
            return DetectedObject(id: key, label: raw.label, confidence: raw.confidence,
                                  screenRect: rect, distance: distance)
        }
    }

    /// Dimension Scanner: capture the real-world size of a detected object.
    func measureObject(_ object: DetectedObject) {
        guard let frame = engine.currentFrame else { return }
        guard let measured = DepthSampler.measureRegion(
            frame: frame, viewRect: object.screenRect, viewSize: detectViewSize) else {
            showToast("No depth on \(object.label.lowercased())"); return
        }
        let item = MeasuredObject(label: object.label, distance: measured.distance,
                                  size: measured.size, date: Date())
        measuredObjects.append(item)
        showToast("\(object.label): \(item.sizeText)")
    }

    func clearMeasuredObjects() { measuredObjects = [] }

    func exportDimensions() {
        do { dimensionsExportURL = try DimensionExporter.write(measuredObjects) }
        catch { showToast("Nothing to export yet") }
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
