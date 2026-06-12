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

/// Configuration for the scanning process.
struct ScanConfig {
    var frameStride: Int = 3
    var pixelStride: Int = 2
    var minConfidence: UInt8 = 1     // 0 low, 1 medium, 2 high
    var voxelSize: Float = 0.012
    var maxPoints: Int = 600_000
    var maxDepth: Float = 5.0
    /// If true, the recorder will adapt its effective frameStride based on
    /// average confidence of the incoming frame (lower confidence → higher stride).
    var adaptiveStrideEnabled: Bool = true
    /// If true, points farther from the camera are snapped to a coarser voxel
    /// lattice before insertion, so distant (noisier, sparser) surfaces consume
    /// fewer points while close-up detail stays full-resolution. Points closer
    /// than `adaptiveVoxelNearDistance` are never coarsened.
    var adaptiveVoxelEnabled: Bool = true
    /// Distance (metres) within which adaptive voxel coarsening is disabled.
    var adaptiveVoxelNearDistance: Float = 1.5
    /// Distance band width (metres): each band beyond the near distance bumps the
    /// voxel-size multiplier by one, up to `adaptiveVoxelMaxMultiplier`.
    var adaptiveVoxelBandWidth: Float = 1.0
    /// Maximum voxel-size multiplier applied to the farthest points.
    var adaptiveVoxelMaxMultiplier: Int = 4
    /// TSDF-style weighted voxel fusion: instead of "first sample per voxel
    /// wins", every depth sample falling into a voxel refines the stored point
    /// as a confidence-weighted running average (position, colour and
    /// confidence). Dramatically reduces depth noise on repeated sweeps.
    var fusionEnabled: Bool = true
    /// Per-voxel weight cap so very old observations don't freeze the average.
    var fusionMaxWeight: Float = 48
    /// Capture camera keyframes (photo + pose + depth) during the scan so a
    /// reconstructed mesh can be photo-textured instead of point-coloured.
    var keyframesEnabled: Bool = true
}

extension ScanConfig {
    /// Preset for the RoomPlan hybrid walkthrough. A room has far more surface
    /// than a tabletop scan: with the tabletop preset (12 mm voxels, 600 k cap,
    /// 5 m range) the cap landed mid-walkthrough and the last wall never
    /// accumulated. Coarser voxels + a higher cap + longer range cover a full
    /// room; frameStride 1 because the ~8 Hz poll is already the stride.
    static let roomWalkthrough = ScanConfig(
        frameStride: 1,
        pixelStride: 2,
        minConfidence: 1,
        voxelSize: 0.025,
        maxPoints: 1_500_000,
        maxDepth: 8.0)
}

/// Estimates how "saturated" a scan is from the rate at which new points are
/// still being added. Early on, sweeping fresh surface adds points fast (low
/// coverage — keep scanning); once the rate falls off relative to its peak, the
/// visible area is largely captured (high coverage). Pure value type so it is
/// unit-testable in isolation from ARKit.
struct ScanCoverageEstimator {
    /// Smoothing factor for the growth EMA (0…1; higher = more reactive).
    var smoothing: Float = 0.3
    /// Points must exceed this before coverage is reported, so the unstable
    /// first frames don't produce a misleading number.
    var warmupPoints: Int = 2_000

    private var lastCount = 0
    private var emaGrowth: Float = 0
    private var peakGrowth: Float = 0
    private var started = false

    /// Feeds the latest total point count and returns the coverage estimate in
    /// [0, 1], or `nil` while still warming up.
    mutating func update(totalCount: Int) -> Float? {
        defer { lastCount = totalCount }
        let delta = Float(max(0, totalCount - lastCount))
        if !started {
            started = true
            emaGrowth = delta
        } else {
            emaGrowth += smoothing * (delta - emaGrowth)
        }
        peakGrowth = max(peakGrowth, emaGrowth)
        guard totalCount >= warmupPoints, peakGrowth > 0 else { return nil }
        return min(max(1 - emaGrowth / peakGrowth, 0), 1)
    }

    mutating func reset() {
        lastCount = 0
        emaGrowth = 0
        peakGrowth = 0
        started = false
    }
}

/// A one-shot subject silhouette plus the camera that saw it. Candidate world
/// points are reprojected into that view and tested against the mask, so a
/// targeted scan keeps the subject and rejects the clutter around it. Points
/// outside the silhouette's frustum can't be judged and are accepted — the
/// ROI sphere still bounds those.
struct ScanSilhouette {
    let mask: SubjectMasker.MaskBitmap
    let worldToCamera: simd_float4x4
    /// Intrinsics in full image-pixel units (matching `width`/`height`).
    let fx: Float, fy: Float, cx: Float, cy: Float
    let width: Float, height: Float

    func rejects(_ p: SIMD3<Float>) -> Bool {
        let camera = worldToCamera * SIMD4<Float>(p, 1)
        let depth = -camera.z
        guard depth > 0.05 else { return false }
        let u = camera.x / depth * fx + cx
        let v = -camera.y / depth * fy + cy
        guard u >= 0, v >= 0, u < width, v < height else { return false }
        return !mask.contains(normalizedX: u / width, normalizedY: v / height)
    }
}

/// Thread‑safe point‑cloud recorder using a private serial queue.
final class ScanRecorder: @unchecked Sendable {
    typealias Candidates = ScanComputeUnprojector.Candidates

    // MARK: - State
    private let queue = DispatchQueue(label: "com.keks.MagicCamera.scanRecorder")
    private var config: ScanConfig
    private var cloud = PointCloud()
    private var voxelGrid: VoxelGrid
    /// Voxel → (stored point index, accumulated weight) for weighted fusion.
    private var fusionCells: [SIMD3<Int32>: (index: Int32, weight: Float)] = [:]
    /// Per-point mean view direction (camera → point), index-aligned with the
    /// cloud — feeds the ray-carved "Fusion" (TSDF-style) reconstruction.
    private var viewDirections: [SIMD3<Float>] = []
    private var frameCounter = 0
    private var regionCenter: SIMD3<Float>?
    private var regionRadiusSq: Float = 0
    /// Latest subject silhouette for targeted scans (refreshed ~1 Hz by the
    /// scan view); nil when no target is set or nothing lifts.
    private var silhouette: ScanSilhouette?
    /// Points killed by free-space carving since the last compaction.
    private var tombstones = 0

    private let unprojector = ScanComputeUnprojector()
    /// Keyframe photos for texture baking (owned by `queue`).
    private let keyframeRecorder = ScanKeyframeRecorder()

    var onProgress: (@MainActor @Sendable (Int) -> Void)?
    /// Called on the main actor when scan confidence changes noticeably (0 = low, 1 = high).
    /// Only fired when adaptive stride is enabled and a confidence map is available.
    var onQualityUpdate: (@MainActor @Sendable (Float) -> Void)?
    /// Called on the main actor when the coverage estimate changes noticeably
    /// (0 = sweeping fresh surface, 1 = the visible area is largely captured).
    var onCoverageUpdate: (@MainActor @Sendable (Float) -> Void)?

    // MARK: - Lifecycle
    init(config: ScanConfig = ScanConfig()) {
        self.config = config
        self.voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
    }

    // MARK: - Configuration
    func configure(_ config: ScanConfig) {
        queue.sync {
            self.config = config
            self.voxelGrid = VoxelGrid(voxelSize: config.voxelSize)
            self.cloud.removeAll()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.frameCounter = 0
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.silhouette = nil
            self.resetReportingState()
        }
    }

    var pointCount: Int {
        queue.sync { self.cloud.count }
    }

    func snapshot() -> PointCloud {
        queue.sync { self.cloud }
    }

    /// Keyframes captured so far (photo + pose + depth, for texture baking).
    func snapshotKeyframes() -> [ScanKeyframe] {
        queue.sync { self.keyframeRecorder.keyframes }
    }

    /// A strided snapshot capped at `maxCount` points — cheap to rebuild for the
    /// live overlay even when the full cloud has grown into the millions.
    func overlaySnapshot(maxCount: Int) -> PointCloud {
        queue.sync { self.cloud.downsampled(maxCount: maxCount) }
    }

    /// Snapshot with a cheap voxel‑neighbour outlier filter applied. Points whose
    /// 3x3x3 voxel block holds fewer than `minNeighbors` occupied cells are
    /// dropped; the per-point view directions stay index-aligned through the
    /// filter so the Fusion reconstruction can use them.
    ///
    /// Heavy on a large cloud (millions of points), so callers MUST run this off
    /// the main thread — doing it inline on `stopScan` blocked the main thread
    /// long enough for the watchdog to SIGKILL the app.
    func snapshotDenoised(minNeighbors: Int)
        -> (cloud: PointCloud, viewDirections: [SIMD3<Float>]) {
        queue.sync {
            guard minNeighbors > 1, !self.cloud.isEmpty else {
                return (self.cloud, self.viewDirections)
            }
            let hasDirections = self.viewDirections.count == self.cloud.count
            var filtered = PointCloud()
            filtered.reserveCapacity(self.cloud.count)
            var directions: [SIMD3<Float>] = []
            if hasDirections { directions.reserveCapacity(self.cloud.count) }
            for i in 0..<self.cloud.count
            where self.cloud.confidences[i] >= 0
                && self.voxelGrid.hasOccupiedNeighbors(of: self.cloud.positions[i], atLeast: minNeighbors) {
                filtered.append(position: self.cloud.positions[i],
                                color: self.cloud.colors[i],
                                confidence: self.cloud.confidences[i])
                if hasDirections { directions.append(self.viewDirections[i]) }
            }
            return (filtered, directions)
        }
    }

    // Note: true statistical outlier removal (mean k-NN distance + std-dev
    // threshold) lives in `PointCloudDenoiser.removeOutliers`, applied at review
    // time. The recorder keeps only the cheap voxel-neighbour pre-filter above,
    // which is fast enough to run inline when a scan stops.

    func reset() {
        queue.sync {
            self.cloud.removeAll()
            self.voxelGrid.reset()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.frameCounter = 0
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.silhouette = nil
            self.resetReportingState()
        }
    }

    // MARK: - Region of interest
    func setRegion(center: SIMD3<Float>, radius: Float) {
        queue.sync {
            self.regionCenter = center
            self.regionRadiusSq = radius * radius
        }
    }

    func setRegionRadius(_ radius: Float) {
        queue.sync {
            if self.regionCenter != nil {
                self.regionRadiusSq = radius * radius
            }
        }
    }

    func clearRegion() {
        queue.sync {
            self.regionCenter = nil
            self.regionRadiusSq = 0
            self.silhouette = nil
        }
    }

    /// Latest subject silhouette for targeted capture (nil clears it).
    func setSilhouette(_ newSilhouette: ScanSilhouette?) {
        queue.sync { self.silhouette = newSilhouette }
    }

    func clearAccumulation() {
        queue.sync {
            self.cloud.removeAll()
            self.voxelGrid.reset()
            self.fusionCells.removeAll(keepingCapacity: true)
            self.viewDirections.removeAll(keepingCapacity: true)
            self.keyframeRecorder.reset()
            self.resetReportingState()
        }
    }

    /// Resets progress/quality/coverage tracking. Must be called on `queue`.
    private func resetReportingState() {
        tombstones = 0
        lastReportedCount = 0
        lastReportedConfidence = -1
        lastReportedCoverage = -1
        coverageEstimator.reset()
    }

    var hasRegion: Bool {
        queue.sync { self.regionCenter != nil }
    }

    // MARK: - Frame processing

    /// Movement-gated keyframe capture only — used by mesh scans, which skip
    /// the point pipeline but still want photos for texture baking in review.
    func considerKeyframe(frame: ARFrame) {
        queue.async {
            guard case .normal = frame.camera.trackingState else { return }
            self.keyframeRecorder.considerCapture(frame: frame)
        }
    }

    func process(frame: ARFrame) {
        queue.async {
            self._process(frame: frame)
        }
    }

    private func _process(frame: ARFrame) {
        // Only accumulate while tracking is solid: during excessive motion,
        // relocalisation or feature loss the pose drifts, and points fused
        // then land smeared across the cloud.
        guard case .normal = frame.camera.trackingState else { return }
        frameCounter += 1
        let effectiveStride: Int
        if config.adaptiveStrideEnabled,
           let confMap = frame.smoothedSceneDepth?.confidenceMap {
            let avgConf = computeAverageConfidence(from: confMap)
            reportQualityIfChanged(avgConf)
            // Map confidence [0,1] to stride multiplier [1,4]: poor quality → sample less
            let multiplier = 1 + Int((1.0 - avgConf) * 3)
            effectiveStride = max(config.frameStride, 1) * multiplier
        } else {
            effectiveStride = max(config.frameStride, 1)
        }
        guard frameCounter % effectiveStride == 0 else { return }

        if config.keyframesEnabled {
            keyframeRecorder.considerCapture(frame: frame)
        }

        guard let candidates = unprojector?.unproject(frame: frame, config: config)
                ?? cpuUnproject(frame: frame) else { return }

        let cameraPosition = frame.camera.transform.columns.3
        accumulate(candidates, cameraPosition: SIMD3<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z))
    }

    // MARK: - Accumulation (voxel fusion / dedup + cap)
    private func accumulate(_ candidates: Candidates, cameraPosition: SIMD3<Float>) {
        let cap = config.maxPoints
        let center = regionCenter
        let radiusSq = regionRadiusSq
        let silhouette = self.silhouette
        let n = candidates.positions.count
        var i = 0
        while i < n {
            let position = candidates.positions[i]
            if let center,
               simd_distance_squared(position, center) > radiusSq {
                i += 1; continue
            }
            if let silhouette, silhouette.rejects(position) {
                i += 1; continue
            }
            // Snap distant points to a coarser lattice so far surfaces consume
            // fewer points while close-up detail stays full-resolution.
            let stored = Self.adaptiveSnap(position, cameraDistance: simd_distance(position, cameraPosition),
                                           voxelSize: voxelGrid.voxelSize, config: config)
            let ray = stored - cameraPosition
            let rayLength = simd_length(ray)
            let direction = rayLength > 1e-6 ? ray / rayLength : SIMD3<Float>(0, 0, -1)
            if config.fusionEnabled, rayLength > 0.4 {
                // Free-space carving: this ray proves the space in front of
                // its hit is empty, so stored points sitting there (depth
                // ghosts, reflections, moved objects) lose weight and die —
                // later views *correct* earlier mistakes instead of only
                // averaging into them.
                carveFreeSpace(cameraPosition: cameraPosition, direction: direction,
                               hitDistance: rayLength)
            }
            if config.fusionEnabled {
                fuse(position: stored, color: candidates.colors[i],
                     confidence: candidates.confidences[i], direction: direction, cap: cap)
            } else {
                if cloud.count >= cap { break }
                if voxelGrid.insert(stored) {
                    cloud.append(position: stored,
                                 color: candidates.colors[i],
                                 confidence: candidates.confidences[i])
                    viewDirections.append(direction)
                }
            }
            i += 1
        }
        compactTombstonesIfNeeded()

        let count = cloud.count
        // Report progress on the main actor.
        reportAfterAccumulate(count)
    }

    /// Probes the ray at 70% and 85% of its hit distance: a fused point in a
    /// probed voxel is contradicted (we can see past it). Its weight drops;
    /// at zero it is tombstoned (confidence −1) and its voxel freed so honest
    /// re-observations can claim it. Must run on `queue`.
    private func carveFreeSpace(cameraPosition: SIMD3<Float>, direction: SIMD3<Float>,
                                hitDistance: Float) {
        let voxel = voxelGrid.voxelSize
        for fraction: Float in [0.7, 0.85] {
            let probeDistance = hitDistance * fraction
            // The probe must sit clearly in front of the surface, not in the
            // noise band around it.
            guard hitDistance - probeDistance > max(0.08, voxel * 3) else { continue }
            let probe = cameraPosition + direction * probeDistance
            let scaled = probe / voxel
            let key = SIMD3<Int32>(Int32(scaled.x.rounded(.down)),
                                   Int32(scaled.y.rounded(.down)),
                                   Int32(scaled.z.rounded(.down)))
            guard let cell = fusionCells[key] else { continue }
            let weight = cell.weight - 1.0
            if weight <= 0 {
                let index = Int(cell.index)
                cloud.update(at: index, position: cloud.positions[index],
                             color: cloud.colors[index], confidence: -1)
                fusionCells.removeValue(forKey: key)
                tombstones += 1
            } else {
                fusionCells[key] = (cell.index, weight)
            }
        }
    }

    /// Rebuilds the cloud without tombstoned points once they pass ~5%:
    /// indices shift, so fusion cells and view directions re-align and the
    /// dedup grid is re-seeded. Must run on `queue`.
    private func compactTombstonesIfNeeded() {
        guard tombstones >= 2_000, tombstones * 20 >= cloud.count else { return }
        var map = [Int32](repeating: -1, count: cloud.count)
        var compacted = PointCloud()
        compacted.reserveCapacity(cloud.count - tombstones)
        let hasDirections = viewDirections.count == cloud.count
        var directions: [SIMD3<Float>] = []
        if hasDirections { directions.reserveCapacity(cloud.count - tombstones) }
        for i in 0..<cloud.count where cloud.confidences[i] >= 0 {
            map[i] = Int32(compacted.count)
            compacted.append(position: cloud.positions[i], color: cloud.colors[i],
                             confidence: cloud.confidences[i])
            if hasDirections { directions.append(viewDirections[i]) }
        }
        var cells: [SIMD3<Int32>: (index: Int32, weight: Float)] = [:]
        cells.reserveCapacity(fusionCells.count)
        for (key, cell) in fusionCells {
            let mapped = map[Int(cell.index)]
            if mapped >= 0 { cells[key] = (mapped, cell.weight) }
        }
        cloud = compacted
        if hasDirections { viewDirections = directions }
        fusionCells = cells
        voxelGrid.reset()
        for p in cloud.positions { _ = voxelGrid.insert(p) }
        tombstones = 0
    }

    /// Weighted running average per voxel (TSDF-style fusion): the stored point
    /// converges to the confidence-weighted mean of every sample that hit its
    /// voxel, which suppresses LiDAR depth noise instead of keeping the first
    /// (possibly noisy) sample. New voxels still respect the point cap; updates
    /// to existing voxels are free refinements. Must run on `queue`.
    private func fuse(position: SIMD3<Float>, color: SIMD3<Float>,
                      confidence: Float, direction: SIMD3<Float>, cap: Int) {
        let voxel = voxelGrid.voxelSize
        let s = position / voxel
        let key = SIMD3<Int32>(Int32(s.x.rounded(.down)),
                               Int32(s.y.rounded(.down)),
                               Int32(s.z.rounded(.down)))
        let weight = 0.25 + confidence   // low-confidence samples count, but less

        if let cell = fusionCells[key] {
            let index = Int(cell.index)
            let t = weight / (cell.weight + weight)
            let p = cloud.positions[index] + (position - cloud.positions[index]) * t
            let c = cloud.colors[index] + (color - cloud.colors[index]) * t
            let conf = cloud.confidences[index] + (confidence - cloud.confidences[index]) * t
            cloud.update(at: index, position: p, color: c, confidence: conf)
            let blended = viewDirections[index] + (direction - viewDirections[index]) * t
            let blendedLength = simd_length(blended)
            if blendedLength > 1e-6 { viewDirections[index] = blended / blendedLength }
            fusionCells[key] = (cell.index, min(cell.weight + weight, config.fusionMaxWeight))
        } else {
            guard cloud.count < cap else { return }
            fusionCells[key] = (Int32(cloud.count), weight)
            _ = voxelGrid.insert(position)   // keeps the denoise neighbour grid in sync
            cloud.append(position: position, color: color, confidence: confidence)
            viewDirections.append(direction)
        }
    }

    /// Progress/coverage reporting shared by both accumulation paths.
    private func reportAfterAccumulate(_ count: Int) {
        if abs(count - lastReportedCount) >= 250 || (count > 0 && lastReportedCount == 0) {
            lastReportedCount = count
            let reported = count
            // Hop to MainActor to invoke the callback.
            DispatchQueue.main.async { [weak self] in
                self?.onProgress?(reported)
            }
        }
        if let coverage = coverageEstimator.update(totalCount: count) {
            reportCoverageIfChanged(coverage)
        }
    }

    /// Snaps `position` onto a distance-scaled voxel lattice. Points within
    /// `adaptiveVoxelNearDistance` (or when adaptive voxel is off) are returned
    /// unchanged; farther points snap to a lattice `multiplier`× coarser, where
    /// the multiplier grows one step per `adaptiveVoxelBandWidth` of distance up
    /// to `adaptiveVoxelMaxMultiplier`. Static + pure so it is unit-testable.
    static func adaptiveSnap(_ position: SIMD3<Float>, cameraDistance d: Float,
                             voxelSize: Float, config: ScanConfig) -> SIMD3<Float> {
        guard config.adaptiveVoxelEnabled, d > config.adaptiveVoxelNearDistance else { return position }
        let band = (d - config.adaptiveVoxelNearDistance) / max(config.adaptiveVoxelBandWidth, 0.01)
        let multiplier = min(1 + Int(band), max(config.adaptiveVoxelMaxMultiplier, 1))
        guard multiplier > 1 else { return position }
        let cell = voxelSize * Float(multiplier)
        let s = position / cell
        return SIMD3<Float>(s.x.rounded(), s.y.rounded(), s.z.rounded()) * cell
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
                if let confidencePtr,
                   confidencePtr[v * confidenceRowBytes + u] < config.minConfidence {
                    u += stride; continue
                }
                let world = DepthMath.worldPoint(
                    u: Float(u), v: Float(v), depth: depth,
                    intrinsics: intrinsics, cameraTransform: cameraTransform)
                let color = sampleColor(
                    u: Int(Float(u) * sx), v: Int(Float(v) * sy),
                    width: imageWidth, height: imageHeight,
                    yBase: yBase, yRowBytes: yRowBytes,
                    cbcrBase: cbcrBase, cbcrRowBytes: cbcrRowBytes)
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
        return simd_clamp(SIMD3<Float>(r, g, b),
                          SIMD3<Float>(repeating: 0),
                          SIMD3<Float>(repeating: 1))
    }

    // MARK: - Helper
    private var lastReportedCount = 0
    private var lastReportedConfidence: Float = -1
    private var lastReportedCoverage: Float = -1
    private var coverageEstimator = ScanCoverageEstimator()

    /// Computes average ARKit confidence, normalised to [0, 1].
    /// ARConfidenceLevel pixels are 0 (low), 1 (medium), or 2 (high) — NOT 0–255.
    /// Samples every `sampleStride` pixels to stay cheap on the serial queue.
    private func computeAverageConfidence(from map: CVPixelBuffer) -> Float {
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(map) else { return 0 }
        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowStride = CVPixelBufferGetBytesPerRow(map)
        let sampleStride = 8
        var sum: Float = 0
        var count = 0
        var y = 0
        while y < height {
            let rowOffset = y * rowStride
            var x = 0
            while x < width {
                sum += Float(base[rowOffset + x])
                count += 1
                x += sampleStride
            }
            y += sampleStride
        }
        // Divide by 2 to normalise values 0/1/2 → 0.0/0.5/1.0.
        return count > 0 ? (sum / Float(count)) / 2.0 : 0
    }

    private func reportQualityIfChanged(_ confidence: Float) {
        guard abs(confidence - lastReportedConfidence) > 0.05 else { return }
        lastReportedConfidence = confidence
        DispatchQueue.main.async { [weak self] in
            self?.onQualityUpdate?(confidence)
        }
    }

    private func reportCoverageIfChanged(_ coverage: Float) {
        guard abs(coverage - lastReportedCoverage) > 0.03 else { return }
        lastReportedCoverage = coverage
        DispatchQueue.main.async { [weak self] in
            self?.onCoverageUpdate?(coverage)
        }
    }
}
