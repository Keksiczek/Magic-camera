//
//  KeyframePhotogrammetry.swift
//  MagicCamera
//
//  Photogrammetric reconstruction from a Spatial Scan's OWN keyframes.
//
//  The app already had photogrammetry, but only behind Apple's guided Object
//  Capture flow — a separate mode with its own ARKit-driven capture UI, its own
//  orbit coaching and its own gallery entry. Inside the app's own scan mode the
//  only reconstruction available was the LiDAR path: cloud → marching cubes →
//  multi-view texture bake. That path's geometry is floored by depth noise
//  (measured on device: 3.7 mm local-plane RMS on an object, 15.3 mm in a room),
//  so a 4 mm lattice is already at the limit of what the data supports and no
//  amount of tuning gets past it.
//
//  Photogrammetry is not bound by that floor — it recovers geometry from image
//  correspondence, not from the depth sensor. And the scan already captures
//  exactly what it needs: sharp JPEGs with known camera poses, 43-96 of them per
//  scan, selected for pose diversity. They were only ever used as a texture
//  source. This feeds them to `PhotogrammetrySession` instead, so the user's own
//  mode can produce a photogrammetric model without a second capture.
//
//  Honest about where it works: `PhotogrammetrySession` is built for OBJECTS —
//  a subject orbited from outside, seen against a background it can discard.
//  A room is the inverse topology (camera inside, looking out) and Apple does not
//  target it. It is offered for rooms because the user asked for the option, and
//  it does sometimes produce a good result on a small, well-orbited alcove — but
//  the LiDAR path remains the recommended one for rooms and the UI says so.
//

import Foundation
import RealityKit
import UIKit

enum KeyframePhotogrammetry {

    /// Whether this device can run photogrammetry at all. False on most iPhones
    /// without the required silicon, and always false in the simulator.
    static var isAvailable: Bool { PhotogrammetrySession.isSupported }

    /// Fewest keyframes worth attempting. Below this the session reliably stalls
    /// part-way and reports nothing useful — the guided flow's own experience,
    /// where "stopped early" almost always meant too few usable images.
    static let minimumKeyframes = 20

    /// Most images to hand the session. Mirrors the guided flow's cap: past this
    /// the matching cost grows faster than the quality does, and the CPU watchdog
    /// is a real ceiling on-device.
    static let maximumKeyframes = 160

    enum Failure: LocalizedError {
        case unsupported
        case tooFewKeyframes(have: Int, need: Int)
        case producedNothing
        case cancelled
        case session(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "This device can't run photogrammetry."
            case .tooFewKeyframes(let have, let need):
                return "Only \(have) photos in this scan — photogrammetry needs at least \(need). Scan more slowly, all the way around."
            case .producedNothing:
                return "Photogrammetry finished but produced no model. Capture more overlapping photos in even lighting."
            case .cancelled:
                return "Photogrammetry was cancelled."
            case .session(let message):
                return message
            }
        }
    }

    /// Runs photogrammetry over `keyframes` and returns the imported mesh.
    ///
    /// `progress` is called with 0…1 and a stage label. The caller owns
    /// cancellation through normal task cancellation — the session is cancelled
    /// and the scratch directory removed on the way out.
    static func reconstruct(
        keyframes: [ScanKeyframe],
        progress: @MainActor @escaping (Double, String) -> Void
    ) async throws -> USDZMeshImporter.Imported {
        guard isAvailable else { throw Failure.unsupported }
        guard keyframes.count >= minimumKeyframes else {
            throw Failure.tooFewKeyframes(have: keyframes.count, need: minimumKeyframes)
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photogrammetry-\(UUID().uuidString)")
        let images = scratch.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let used = spread(keyframes, to: maximumKeyframes)
        // The JPEGs are already encoded — write the bytes, don't re-encode. Names
        // are zero-padded so the directory listing keeps capture order, which is
        // what `.sequential` ordering below relies on.
        for (index, keyframe) in used.enumerated() {
            try keyframe.jpeg.write(
                to: images.appendingPathComponent(String(format: "%04d.jpg", index)),
                options: .atomic)
        }
        Diagnostics.shared.log("photogrammetry",
                               "\(used.count) of \(keyframes.count) keyframes")

        var configuration = PhotogrammetrySession.Configuration()
        // Keyframes are banked along the sweep, so they ARE in spatial order —
        // telling the session so skips the expensive unordered matching pass.
        // (No `checkpointDirectory`: those only index an Object Capture set.)
        configuration.sampleOrdering = .sequential
        let session = try PhotogrammetrySession(input: images, configuration: configuration)
        let modelURL = scratch.appendingPathComponent("model.usdz")
        let outputs = session.outputs
        // NOTE: the iOS SDK exposes only `.reduced` detail — same constraint the
        // guided flow hit; `.medium`/`.full` are macOS-only.
        try session.process(requests: [.modelFile(url: modelURL, detail: .reduced)])

        var wrote = false
        do {
            for try await output in outputs {
                if Task.isCancelled { session.cancel(); throw Failure.cancelled }
                switch output {
                case .requestProgress(_, let fraction):
                    await progress(fraction, "Reconstructing…")
                case .requestProgressInfo(_, let info):
                    await progress(-1, stageLabel(info.processingStage) ?? "Reconstructing…")
                case .requestComplete(_, let result):
                    if case .modelFile = result { wrote = true }
                case .requestError(_, let error):
                    throw Failure.session(error.localizedDescription)
                case .processingCancelled:
                    throw Failure.cancelled
                case .processingComplete:
                    break
                default:
                    break
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.session(error.localizedDescription)
        }

        guard wrote || FileManager.default.fileExists(atPath: modelURL.path) else {
            throw Failure.producedNothing
        }
        await progress(1, "Loading model…")
        guard let imported = USDZMeshImporter.importModel(from: modelURL) else {
            throw Failure.producedNothing
        }
        Diagnostics.shared.log("photogrammetry",
                               "mesh \(imported.mesh.triangleCount) tris"
                               + (imported.textured != nil ? " · textured" : " · untextured"))
        return imported
    }

    /// Evenly-spaced subset of `keyframes`, preserving order.
    ///
    /// Even spacing rather than "the sharpest N": photogrammetry needs COVERAGE
    /// above all — a gap in the orbit is unrecoverable, whereas one soft frame
    /// among its neighbours costs almost nothing. This is the opposite of the
    /// texture bake's selection rule, which does want the sharpest frames.
    static func spread(_ keyframes: [ScanKeyframe], to limit: Int) -> [ScanKeyframe] {
        guard keyframes.count > limit, limit > 0 else { return keyframes }
        let step = Double(keyframes.count) / Double(limit)
        return (0..<limit).map { keyframes[min(keyframes.count - 1, Int(Double($0) * step))] }
    }

    private static func stageLabel(_ stage: PhotogrammetrySession.Output.ProcessingStage?) -> String? {
        switch stage {
        case .preProcessing:            return "Preparing photos…"
        case .imageAlignment:           return "Aligning photos…"
        case .pointCloudGeneration:     return "Building point cloud…"
        case .meshGeneration:           return "Building mesh…"
        case .textureMapping:           return "Mapping texture…"
        case .optimization:             return "Optimising…"
        default:                        return nil
        }
    }
}
