//
//  WiggleVideoBuilder.swift
//  Magic Camera
//
//  Renders a short, seamlessly-looping "3D photo" wiggle from a single captured
//  frame: the virtual camera orbits a tiny ellipse while EffectRenderer applies a
//  depth-driven parallax warp, and the frames are encoded offline to an .mp4.
//

import ARKit
import AVFoundation
import CoreVideo
import simd

enum WiggleVideoBuilder {
    private static let frameCount = 60
    private static let fps: Int32 = 30
    private static let amplitude: Float = 1.0
    private static let strength: Float = 0.5
    private static let maxShift: Float = 0.035

    /// Encodes the wiggle and returns the file URL, or `nil` on failure. Intended
    /// to run on a background task (each frame render blocks on the GPU).
    static func make(frame: ARFrame, renderer: EffectRenderer,
                     size: CGSize, focus: Float) async -> URL? {
        guard renderer.supportsParallax else { return nil }
        let width = Int(size.width) & ~1
        let height = Int(size.height) & ~1
        guard width > 0, height > 0 else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagicCamera-wiggle-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { writer.cancelWriting(); return nil }

        for i in 0..<frameCount {
            let theta = 2 * Float.pi * Float(i) / Float(frameCount)
            // Small ellipse, returning to centre at the loop boundary.
            let offset = simd_float2(amplitude * sin(theta),
                                     amplitude * 0.18 * (cos(theta) - 1))
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixelBuffer = buffer else { continue }
            _ = renderer.renderParallax(frame: frame, offset: offset, focus: focus,
                                        strength: strength, maxShift: maxShift, into: pixelBuffer)
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()

        let writerBox = UncheckedSendableBox(writer)
        return await withCheckedContinuation { continuation in
            writerBox.value.finishWriting {
                continuation.resume(returning: writerBox.value.status == .completed ? url : nil)
            }
        }
    }

    /// Estimates the parallax pivot depth from a central window of the depth map.
    static func estimateFocus(frame: ARFrame) -> Float {
        guard let depthMap = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap else { return 1.0 }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(depthMap) else { return 1.0 }

        let rowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let cx = width / 2, cy = height / 2
        let radius = max(min(width, height) / 10, 1)

        var sum: Float = 0
        var count = 0
        for v in max(cy - radius, 0)...min(cy + radius, height - 1) {
            for u in max(cx - radius, 0)...min(cx + radius, width - 1) {
                let d = ptr[v * rowStride + u]
                if d > 0, d.isFinite { sum += d; count += 1 }
            }
        }
        return count > 0 ? max(sum / Float(count), 0.2) : 1.0
    }
}
