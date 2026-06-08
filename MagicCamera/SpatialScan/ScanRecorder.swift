//
//  ScanRecorder.swift
//  Magic Camera
//
//  Consumes ARFrames and accumulates a coloured point cloud: back-projects the
//  depth map to world space, samples colour from the captured image, filters by
//  LiDAR confidence, and bounds memory via frame striding, pixel striding, a
//  voxel grid and a hard point cap.
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

final class ScanRecorder {
    private let lock = NSLock()
    private var config: ScanConfig
    private var cloud = PointCloud()
    private var voxelGrid: VoxelGrid
    private var frameCounter = 0

    /// Called (on the main queue) when the point count changes meaningfully.
    var onProgress: ((Int) -> Void)?
    private var lastReportedCount = 0

    init(config: ScanConfig = ScanConfig()) {
        self.config = config
        self.voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
    }

    /// Apply a new config and clear accumulated state. Call before a scan.
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

    func reset() {
        lock.lock()
        cloud.removeAll()
        voxelGrid.reset()
        frameCounter = 0
        lastReportedCount = 0
        lock.unlock()
    }

    func process(frame: ARFrame) {
        frameCounter += 1
        guard frameCounter % max(config.frameStride, 1) == 0 else { return }
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let captured = frame.capturedImage

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let imageRes = frame.camera.imageResolution
        let intrinsics = DepthMath.scaledIntrinsics(
            frame.camera.intrinsics,
            imageWidth: Float(imageRes.width),
            depthWidth: Float(depthWidth))
        let cameraTransform = frame.camera.transform

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        CVPixelBufferLockBaseAddress(captured, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            CVPixelBufferUnlockBaseAddress(captured, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let depthRowStride = depthRowBytes / MemoryLayout<Float32>.stride

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

        lock.lock()
        defer {
            let count = cloud.count
            lock.unlock()
            if abs(count - lastReportedCount) >= 250 || count == 0 {
                lastReportedCount = count
                let reported = count
                DispatchQueue.main.async { [weak self] in self?.onProgress?(reported) }
            }
        }

        var v = 0
        while v < depthHeight {
            var u = 0
            while u < depthWidth {
                if cloud.count >= config.maxPoints { return }

                let depth = depthPtr[v * depthRowStride + u]
                if depth <= 0 || !depth.isFinite || depth > config.maxDepth {
                    u += stride; continue
                }

                if let confidencePtr {
                    let c = confidencePtr[v * confidenceRowBytes + u]
                    if c < config.minConfidence { u += stride; continue }
                }

                let world = DepthMath.worldPoint(
                    u: Float(u), v: Float(v), depth: depth,
                    intrinsics: intrinsics, cameraTransform: cameraTransform)

                if !voxelGrid.insert(world) { u += stride; continue }

                let color = sampleColor(
                    u: Int(Float(u) * sx), v: Int(Float(v) * sy),
                    width: imageWidth, height: imageHeight,
                    yBase: yBase, yRowBytes: yRowBytes,
                    cbcrBase: cbcrBase, cbcrRowBytes: cbcrRowBytes)

                let confidenceNorm: Float
                if let confidencePtr {
                    confidenceNorm = Float(confidencePtr[v * confidenceRowBytes + u]) / 2.0
                } else {
                    confidenceNorm = 1.0
                }

                cloud.append(position: world, color: color, confidence: confidenceNorm)
                u += stride
            }
            v += stride
        }
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
