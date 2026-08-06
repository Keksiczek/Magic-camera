//
//  CaptureGuidance.swift
//  Magic Camera
//
//  Live capture hints from a handful of cheap per-frame numbers — the reusable
//  part of Apple's scan guidance. Their published nets are two-layer MLPs with
//  tens of parameters, far too small to be doing anything clever; the value was
//  never the model, it was the choice of inputs. The interesting one is 2D
//  *projected* velocity alongside the 3D one: 3D speed alone cannot tell a brisk
//  walk across a large room (fine) from waving the phone 20 cm from a mug
//  (ruinous), because the same metres per second sweep wildly different amounts
//  of image per second. Dividing by subject distance separates them.
//
//  Pure value math — no ARKit, unit-testable. `ScanRecorder` feeds it; the scan
//  coaches render it. See docs/analysis/APPLE-PIPELINE-NOTES.md, item 3.
//

import Foundation

enum CaptureGuidance {

    /// One processed frame's guidance inputs. Everything here is either free off
    /// `ARFrame` or a few dozen depth samples — no CoreML, no pixel pass.
    struct Signals: Equatable, Sendable {
        /// `ARLightEstimate.ambientIntensity`, in lumens (0 = unknown). ~1000 is
        /// ARKit's neutral indoor reference.
        var ambientIntensity: Float = 0
        /// `ARFrame.rawFeaturePoints` count. Corroborates the light estimate: a
        /// dim *and* featureless frame is the one that actually tracks badly.
        var featurePoints: Int = 0
        /// Pose-to-pose camera speed, m/s.
        var linearSpeed: Float = 0
        /// Pose-to-pose camera rotation, rad/s.
        var angularSpeed: Float = 0
        /// Mean depth of the frame's centre region, m (0 = unknown).
        var subjectDistance: Float = 0
        /// How much image the scene sweeps per second, in screen widths.
        var imageSpeed: Float = 0
    }

    /// What to tell the user. `none` = nothing worth interrupting for.
    enum Hint: Equatable, Sendable {
        case none
        /// Too dark (and too featureless) to reconstruct from.
        case light
        /// Moving fast enough to motion-blur the depth map.
        case slowDown
        /// Fast *in the image* only because the phone is right on top of the
        /// subject — backing off fixes it where slowing down barely helps.
        case moveBack
    }

    // MARK: - Thresholds

    /// Screen widths per second above which the depth map smears. At ~0.55 the
    /// scene crosses half the frame in a second; a deliberate orbit sits near
    /// 0.15. Deliberately close to (a little under) the steadiness gate that
    /// silently drops frames, so the user is warned *before* the drops start.
    static let maxImageSpeed: Float = 0.55
    /// Under this subject distance, a too-fast frame is a proximity problem, not
    /// a speed one — at 30 cm even a careful hand sweeps the frame.
    static let closeSubjectDistance: Float = 0.45
    /// Ambient lumens under which the scene is dark whatever else is true.
    static let darkAmbient: Float = 140
    /// Dim, but only a problem when the frame is also feature-poor.
    static let dimAmbient: Float = 320
    /// Raw feature points under which ARKit is tracking on very little.
    static let sparseFeaturePoints = 40

    // MARK: - Projected velocity

    /// Image-space speed in screen widths per second.
    ///
    /// A point at `subjectDistance` sweeps `focalLength · v / d` pixels per
    /// second under translation across the view axis, and `focalLength · ω`
    /// pixels per second under rotation (small angles, distance-free). `v` is
    /// used whole rather than resolved perpendicular to the axis: this feeds a
    /// warning, and over-warning on a dolly-in beats missing a pan.
    static func imageSpeed(linearSpeed: Float, angularSpeed: Float,
                           subjectDistance: Float,
                           focalLength: Float, imageWidth: Float) -> Float {
        guard focalLength > 0, imageWidth > 0 else { return 0 }
        // Below 5 cm the depth reading is noise, not a distance — drop the
        // translation term rather than divide by it.
        let translation = subjectDistance > 0.05
            ? focalLength * max(linearSpeed, 0) / subjectDistance
            : 0
        let rotation = focalLength * max(angularSpeed, 0)
        return (translation + rotation) / imageWidth
    }

    // MARK: - Verdict

    /// The single hint worth showing, motion first: motion is the one that is
    /// already costing frames (the steadiness gate drops them), and it is also
    /// the one the user can fix in a second.
    static func hint(for signals: Signals) -> Hint {
        if signals.imageSpeed > maxImageSpeed {
            let close = signals.subjectDistance > 0
                && signals.subjectDistance < closeSubjectDistance
            return close ? .moveBack : .slowDown
        }
        if signals.ambientIntensity > 0 {
            if signals.ambientIntensity < darkAmbient { return .light }
            if signals.ambientIntensity < dimAmbient,
               signals.featurePoints < sparseFeaturePoints { return .light }
        }
        return .none
    }

    // MARK: - Hysteresis

    /// Holds a hint until it has been true for a few frames running, so a single
    /// jerk or one dark frame mid-sweep doesn't flash a pill at the user. Both
    /// directions are held, including the return to `.none`.
    struct Stabiliser {
        /// Frames a hint must persist before it replaces the published one.
        let holdFrames: Int
        private(set) var published: Hint = .none
        private var candidate: Hint = .none
        private var streak = 0

        init(holdFrames: Int = 4) { self.holdFrames = max(holdFrames, 1) }

        /// Feeds one frame's verdict. Returns the new published hint when it
        /// changed, `nil` while nothing has settled.
        mutating func update(_ hint: Hint) -> Hint? {
            if hint == candidate {
                streak += 1
            } else {
                candidate = hint
                streak = 1
            }
            guard streak >= holdFrames, hint != published else { return nil }
            published = hint
            return hint
        }

        mutating func reset() {
            published = .none
            candidate = .none
            streak = 0
        }
    }
}
