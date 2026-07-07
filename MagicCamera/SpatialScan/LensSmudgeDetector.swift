//
//  LensSmudgeDetector.swift
//  Magic Camera
//
//  A smudged / greasy lens is the classic cause of milky, low-contrast photos —
//  and since the scan's keyframes ARE the texture, a dirty lens quietly ruins
//  every baked surface no matter how well the user scans. iOS 26's Vision
//  `DetectLensSmudgeRequest` spots it from a frame, so the scan coach can nudge
//  "clean the lens" before the whole scan comes out soft. No-op (nil) below
//  iOS 26 — the coach simply never shows the hint there.
//

import CoreVideo
import Vision

enum LensSmudgeDetector {
    /// Smudge confidence for a camera frame, 0…1 (higher = dirtier lens), or nil
    /// when unavailable (pre-iOS 26) or the request failed. Async — Vision runs
    /// off the caller; throttle the call site so it isn't run every frame.
    static func confidence(for pixelBuffer: CVPixelBuffer) async -> Float? {
        guard #available(iOS 26.0, *) else { return nil }
        do {
            let observation = try await DetectLensSmudgeRequest().perform(on: pixelBuffer)
            return observation.confidence
        } catch {
            return nil
        }
    }
}
