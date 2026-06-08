//
//  SpatialScanViewModel.swift
//  Magic Camera
//
//  Drives Mode 2: owns the point-cloud recorder and the mesh collector, tracks
//  the scan phase + chosen scan kind / quality, and handles save, load and
//  export of results.
//

import Observation
import SwiftUI

enum ScanKind: String, CaseIterable, Identifiable {
    case points = "Point Cloud"
    case mesh = "Mesh"
    var id: String { rawValue }
    var systemImage: String { self == .points ? "circle.grid.3x3.fill" : "grid" }
}

enum ScanQuality: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case detailed = "Detailed"
    case ultra = "Ultra"
    var id: String { rawValue }

    var config: ScanConfig {
        switch self {
        case .fast:
            return ScanConfig(frameStride: 4, pixelStride: 3, minConfidence: 1,
                              voxelSize: 0.020, maxPoints: 300_000, maxDepth: 5.0)
        case .balanced:
            return ScanConfig(frameStride: 3, pixelStride: 2, minConfidence: 1,
                              voxelSize: 0.012, maxPoints: 600_000, maxDepth: 5.0)
        case .detailed:
            return ScanConfig(frameStride: 2, pixelStride: 1, minConfidence: 2,
                              voxelSize: 0.008, maxPoints: 1_200_000, maxDepth: 4.0)
        case .ultra:
            return ScanConfig(frameStride: 2, pixelStride: 1, minConfidence: 1,
                              voxelSize: 0.005, maxPoints: 2_000_000, maxDepth: 4.0)
        }
    }
}

@MainActor
@Observable
final class SpatialScanViewModel {
    enum Phase: Equatable { case idle, scanning, reviewing }

    var phase: Phase = .idle
    var scanKind: ScanKind = .points
    var quality: ScanQuality = .balanced
    var pointCount = 0
    var colorMode: PointColorMode = .rgb
    var meshColorMode: MeshColorMode = .shaded
    var pointSize: CGFloat = 6
    var capturedCloud: PointCloud?
    var capturedMesh: MeshData?
    var toast: String?
    var exportURL: URL?
    var arQuickLookURL: URL?

    // Tap-to-target: restrict a point-cloud scan to a region around a tapped point.
    var hasScanTarget = false
    var scanTargetRadius: Float = 0.6

    @ObservationIgnored let recorder = ScanRecorder()
    @ObservationIgnored let meshCollector = MeshAnchorCollector()
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    var isSupported: Bool { DeviceCapabilities.supportsSceneDepth }
    var supportsMesh: Bool { DeviceCapabilities.supportsSceneReconstruction }
    var isScanning: Bool { phase == .scanning }
    var hasResult: Bool { capturedCloud != nil || capturedMesh != nil }
    var meshIsClassified: Bool { capturedMesh?.hasClassification ?? false }

    /// Bounding-box extents of the current result, in metres (width × height × depth).
    var dimensions: SIMD3<Float>? {
        if let box = capturedMesh?.boundingBox() ?? capturedCloud?.boundingBox() {
            return box.max - box.min
        }
        return nil
    }

    var dimensionsText: String? {
        guard let d = dimensions else { return nil }
        return String(format: "%.2f × %.2f × %.2f m", d.x, d.y, d.z)
    }

    init() {
        recorder.onProgress = { [weak self] count in
            self?.pointCount = count
        }
    }

    // MARK: - Scan lifecycle

    func startScan() {
        capturedCloud = nil
        capturedMesh = nil
        pointCount = 0
        if scanKind == .points {
            recorder.configure(quality.config)
        }
        meshCollector.reset()
        phase = .scanning
    }

    func stopScan() {
        switch scanKind {
        case .points:
            let cloud = recorder.snapshotDenoised(minNeighbors: 2)
            pointCount = cloud.count
            if cloud.isEmpty {
                phase = .idle
                showToast("No points captured — scan textured surfaces up close")
            } else {
                capturedCloud = cloud
                phase = .reviewing
            }
        case .mesh:
            let mesh = meshCollector.snapshot()
            if mesh.isEmpty {
                phase = .idle
                showToast("No mesh captured — sweep the space slowly")
            } else {
                capturedMesh = mesh
                pointCount = mesh.triangleCount
                phase = .reviewing
            }
        }
    }

    func discard() {
        capturedCloud = nil
        capturedMesh = nil
        pointCount = 0
        recorder.reset()
        meshCollector.reset()
        hasScanTarget = false
        phase = .idle
    }

    // MARK: - Scan target (region of interest)

    func setScanTarget(_ center: SIMD3<Float>) {
        recorder.setRegion(center: center, radius: scanTargetRadius)
        // Restart accumulation so the result is just the subject, not what was
        // already captured around it.
        recorder.clearAccumulation()
        pointCount = 0
        hasScanTarget = true
        showToast(String(format: "Target set — scanning within %.1f m", scanTargetRadius))
    }

    func updateScanTargetRadius(_ radius: Float) {
        scanTargetRadius = radius
        recorder.setRegionRadius(radius)
    }

    func clearScanTarget() {
        recorder.clearRegion()
        hasScanTarget = false
        showToast("Target cleared — scanning everything")
    }

    // MARK: - Load (from gallery)

    func loadSaved(_ cloud: PointCloud) {
        capturedMesh = nil
        capturedCloud = cloud
        scanKind = .points
        pointCount = cloud.count
        phase = .reviewing
    }

    func loadSavedMesh(_ mesh: MeshData) {
        capturedCloud = nil
        capturedMesh = mesh
        scanKind = .mesh
        pointCount = mesh.triangleCount
        meshColorMode = mesh.hasClassification ? .classification : .shaded
        phase = .reviewing
    }

    // MARK: - Save / export

    func savePointCloud() {
        guard let cloud = capturedCloud else { return }
        do {
            let url = try ScanStore.save(cloud, name: ScanStore.defaultName())
            if let png = ThumbnailRenderer.png(for: cloud) { Thumbnails.write(png, for: url) }
            showToast("Scan saved")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    func saveMesh() {
        guard let mesh = capturedMesh else { return }
        do {
            let url = try MeshStore.save(mesh, name: MeshStore.defaultName())
            if let png = ThumbnailRenderer.png(for: mesh) { Thumbnails.write(png, for: url) }
            showToast("Mesh saved")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    func save() {
        if capturedMesh != nil { saveMesh() } else { savePointCloud() }
    }

    // MARK: - AR Quick Look

    /// Export the captured mesh to a temporary USDZ and present it in AR Quick Look.
    func presentARQuickLook() {
        guard let mesh = capturedMesh else { return }
        do {
            arQuickLookURL = try MeshExporter.write(mesh, format: .usdz, filename: "MagicCamera-ar")
        } catch {
            showToast("AR preview failed: \(error.localizedDescription)")
        }
    }

    func exportPointCloud(format: PointCloudExporter.Format) {
        guard let cloud = capturedCloud else { return }
        do { exportURL = try PointCloudExporter.write(cloud, format: format) }
        catch { showToast("Export failed: \(error.localizedDescription)") }
    }

    func exportMesh(format: MeshExporter.Format) {
        guard let mesh = capturedMesh else { return }
        do { exportURL = try MeshExporter.write(mesh, format: format) }
        catch { showToast("Export failed: \(error.localizedDescription)") }
    }

    // MARK: - Toast

    /// Public entry point for transient hints from the AR coordinator.
    func showScanHint(_ message: String) { showToast(message) }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
