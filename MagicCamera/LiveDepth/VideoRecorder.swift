//
//  VideoRecorder.swift
//  Magic Camera
//
//  Records the effect output to an .mp4 using AVAssetWriter. The renderer draws
//  each frame straight into a pooled CVPixelBuffer (GPU-side), which is appended
//  here, so recording does not stall the live preview.
//

import AVFoundation
import CoreVideo

final class VideoRecorder: @unchecked Sendable {
    enum State { case idle, recording, finishing }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "com.keks.MagicCamera.videoRecorder")

    private(set) var state: State = .idle
    private var startTime: CMTime?

    let outputURL: URL
    let size: CGSize

    /// `size` is rounded to even dimensions (H.264 requirement).
    init?(size requested: CGSize) {
        let width = Int(requested.width) & ~1
        let height = Int(requested.height) & ~1
        guard width > 0, height > 0 else { return nil }
        self.size = CGSize(width: width, height: height)

        let filename = "MagicCamera-\(Int(Date().timeIntervalSince1970)).mp4"
        self.outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: outputURL)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return nil }
        self.writer = writer

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        self.input = input

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: sourceAttributes)

        guard writer.canAdd(input) else { return nil }
        writer.add(input)
    }

    func start() {
        queue.sync {
            guard state == .idle, writer.startWriting() else { return }
            writer.startSession(atSourceTime: .zero)
            startTime = nil
            state = .recording
        }
    }

    /// Dequeue a pooled, Metal-compatible pixel buffer to render into.
    func dequeuePixelBuffer() -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// Append a rendered frame, timestamped from the ARFrame timestamp (seconds).
    func append(_ pixelBuffer: CVPixelBuffer, atSeconds seconds: TimeInterval) {
        queue.sync {
            guard state == .recording, input.isReadyForMoreMediaData else { return }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let presentation: CMTime
            if let start = startTime {
                presentation = CMTimeSubtract(time, start)
            } else {
                startTime = time
                presentation = .zero
            }
            adaptor.append(pixelBuffer, withPresentationTime: presentation)
        }
    }

    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, self.state == .recording else {
                    continuation.resume(returning: nil)
                    return
                }
                self.state = .finishing
                self.input.markAsFinished()
                self.writer.finishWriting {
                    let url: URL? = self.writer.status == .completed ? self.outputURL : nil
                    continuation.resume(returning: url)
                }
            }
        }
    }
}
