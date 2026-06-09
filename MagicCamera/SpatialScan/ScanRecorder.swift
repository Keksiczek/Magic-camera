//
//  ScanRecorder.swift
//  Magic Camera
//
//  Accumulates a coloured point cloud from ARFrames. Per-pixel depth
//  unprojection + colour sampling runs on the GPU (ScanComputeUnprojector) with
//  a CPU fallback; voxel dedup, capping and outlier filtering stay on the CPU.
//

import ARKit
import simd

struct ScanConfig {
    var frameStride: Int = 3
    var pixelStride: Int = 2
    var minConfidence: UInt8 = 1     // 0 low, 1 medium, 2 high
    var voxelSize: Float = 0.012
    var maxPoints: Int = 600_000
    var maxDepth: Float = 5.0
}

final class ScanRecorder: @unchecked Sendable {
    typealias Candidates = ScanComputeUnprojector.Candidates

    private let lock = NSLock()
    private var config: ScanConfig
    private var cloud = PointCloud()
    private var voxelGrid: VoxelGrid
    private var frameCounter = 0

    // Optional region of interest: when set, only points within `regionRadius`
    // of `regionCenter` are accepted, so a tapped target is scanned without the
    // surrounding clutter.
    private var regionCenter: SIMD3<Float>?
    private var regionRadiusSq: Float = 0

    private let unprojector = ScanComputeUnprojector()

    var onProgress: (@MainActor @Sendable (Int) -> Void)?
    private var lastReportedCount = 0

    init(config: ScanConfig = ScanConfig()) {
        self.config = config
        self.voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
    }

    func configure(_ config: ScanConfig) {
        lock.lock()
        self.config = config
        voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
        cloud.removeAll()
        frameCounter = 0
        lastReportedCount = 0
        lock.unlock()
    }

    var pointCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cloud.count
    }

    func snapshot() -> PointCloud {
        lock.lock(); defer { lock.unlock() }
        return cloud
    }

    /// A strided snapshot capped at `maxCount` points — cheap to rebuild for the
    /// live overlay even when the full cloud has grown into the millions, so the
    /// scan stays smooth instead of hitching every overlay refresh.
    func overlaySnapshot(maxCount: Int) -> PointCloud {
        lock.lock(); defer { lock.unlock() }
        return cloud.downsampled(maxCount: maxCount)
    }

    /// Snapshot with a cheap voxel-neighbour outlier filter applied. Points whose
    /// 3x3x3 voxel block holds fewer than `minNeighbors` occupied cells are dropped.
    ///
    /// Heavy on a large cloud (millions of points), so callers MUST run this off
    /// the main thread — doing it inline on `stopScan` blocked the main thread
    /// long enough for the watchdog to SIGKILL the app.
    func snapshotDenoised(minNeighbors: Int) -> PointCloud {
        lock.lock(); defer { lock.unlock() }
        guard minNeighbors > 1, !cloud.isEmpty else { return cloud }
        var filtered = PointCloud()
        filtered.reserveCapacity(cloud.count)
        for i in 0..<cloud.count
        where voxelGrid.hasOccupiedNeighbors(of: cloud.positions[i], atLeast: minNeighbors) {
            filtered.append(position: cloud.positions[i], color: cloud.colors[i], confidence: cloud.confidences[i])
        }
        return filtered
    }

    func reset() {
        lock.lock()
        cloud.removeAll()
        voxelGrid.reset()
        frameCounter = 0
        lastReportedCount = 0
        regionCenter = nil
        regionRadiusSq = 0
        lock.unlock()
    }

    // MARK: - Region of interest

    func setRegion(center: SIMD3<Float>, radius: Float) {
        lock.lock()
        regionCenter = center
        regionRadiusSq = radius * radius
        lock.unlock()
    }

    func setRegionRadius(_ radius: Float) {
        lock.lock()
        if regionCenter != nil { regionRadiusSq = radius * radius }
        lock.unlock()
    }

    func clearRegion() {
        lock.lock()
        regionCenter = nil
        regionRadiusSq = 0
        lock.unlock()
    }

    /// Drop accumulated points but keep the config and region — used when a scan
    /// target is (re)selected so capture restarts focused on the subject.
    func clearAccumulation() {
        lock.lock()
        cloud.removeAll()
        voxelGrid.reset()
        lastReportedCount = 0
        lock.unlock()
    }

    var hasRegion: Bool {
        lock.lock(); defer { lock.unlock() }
        return regionCenter != nil
    }

    func process(frame: ARFrame) {
        frameCounter += 1
        guard frameCounter % max(config.frameStride, 1) == 0 else { return }
        guard let candidates = unprojector?.unproject(frame: frame, config: config)
                ?? cpuUnproject(frame: frame) else { return }
        accumulate(candidates)
    }

    // MARK: - Accumulation (voxel dedup + cap)

    private func accumulate(_ candidates: Candidates) {
        lock.lock()
        let cap = config.maxPoints
        let center = regionCenter
        let radiusSq = regionRadiusSq
        let n = candidates.positions.count
        var i = 0
        while i < n {
            if cloud.count >= cap { break }
            let position = candidates.positions[i]
            if let center, simd_distance_squared(position, center) > radiusSq {
                i += 1; continue
            }
            if voxelGrid.insert(position) {
                cloud.append(position: position, color: candidates.colors[i], confidence: candidates.confidences[i])
            }
            i += 1
        }
        let count = cloud.count
        lock.unlock()

        if abs(count - lastReportedCount) >= 250 || (count > 0 && lastReportedCount == 0) {
            lastReportedCount = count
            let reported = count
            let handler = onProgress
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?(reported) } }
        }
    }

    // MARK: - CPU fallback unprojection

    private func cpuUnproject(frame: ARFrame) -> Candidates? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let captured = frame.capturedImage

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let imageRes = frame.camera.imageResolution
        let intrinsics = DepthMath.scaledIntrinsics(
            frame.camera.intrinsics, imageWidth: Float(imageRes.width), depthWidth: Float(depthWidth))
        let cameraTransform = frame.camera.transform

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        CVPixelBufferLockBaseAddress(captured, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            CVPixelBufferUnlockBaseAddress(captured, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let depthRowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride

        let confidencePtr = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }?
            .assumingMemoryBound(to: UInt8.self)
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let yBase = CVPixelBufferGetBaseAddressOfPlane(captured, 0)?.assumingMemoryBound(to: UInt8.self)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(captured, 0)
        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(captured, 1)?.assumingMemoryBound(to: UInt8.self)
        let cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(captured, 1)
        let imageWidth = CVPixelBufferGetWidthOfPlane(captured, 0)
        let imageHeight = CVPixelBufferGetHeightOfPlane(captured, 0)

        let sx = Float(imageWidth) / Float(depthWidth)
        let sy = Float(imageHeight) / Float(depthHeight)
        let stride = max(config.pixelStride, 1)

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        var confidences: [Float] = []

        var v = 0
        while v < depthHeight {
            var u = 0
            while u < depthWidth {
                let depth = depthPtr[v * depthRowStride + u]
                if depth <= 0 || !depth.isFinite || depth > config.maxDepth { u += stride; continue }
                if let confidencePtr, confidencePtr[v * confidenceRowBytes + u] < config.minConfidence {
                    u += stride; continue
                }
                let world = DepthMath.worldPoint(
                    u: Float(u), v: Float(v), depth: depth,
                    intrinsics: intrinsics, cameraTransform: cameraTransform)
                let color = sampleColor(
                    u: Int(Float(u) * sx), v: Int(Float(v) * sy),
                    width: imageWidth, height: imageHeight,
                    yBase: yBase, yRowBytes: yRowBytes, cbcrBase: cbcrBase, cbcrRowBytes: cbcrRowBytes)
                let confidence = confidencePtr.map { Float($0[v * confidenceRowBytes + u]) / 2.0 } ?? 1.0
                positions.append(world)
                colors.append(color)
                confidences.append(confidence)
                u += stride
            }
            v += stride
        }
        return Candidates(positions: positions, colors: colors, confidences: confidences)
    }

    private func sampleColor(u: Int, v: Int, width: Int, height: Int,
                             yBase: UnsafePointer<UInt8>?, yRowBytes: Int,
                             cbcrBase: UnsafePointer<UInt8>?, cbcrRowBytes: Int) -> SIMD3<Float> {
        guard let yBase, let cbcrBase else { return SIMD3<Float>(repeating: 0.5) }
        let cu = min(max(u, 0), width - 1)
        let cv = min(max(v, 0), height - 1)
        let y = Float(yBase[cv * yRowBytes + cu]) / 255.0
        let chromaIndex = (cv / 2) * cbcrRowBytes + (cu / 2) * 2
        let cb = Float(cbcrBase[chromaIndex]) / 255.0
        let cr = Float(cbcrBase[chromaIndex + 1]) / 255.0
        let r = y + 1.4020 * cr - 0.7010
        let g = y - 0.3441 * cb - 0.7141 * cr + 0.5291
        let b = y + 1.7720 * cb - 0.8860
        return simd_clamp(SIMD3<Float>(r, g, b), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }
}
