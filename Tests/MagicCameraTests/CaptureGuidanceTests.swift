//
//  CaptureGuidanceTests.swift
//  MagicCameraTests
//
//  The guidance signals' contract: image-space speed separates "walking briskly
//  across a room" from "waving the phone at a mug" where 3D speed alone cannot,
//  the verdict picks the hint the user can act on, and the stabiliser refuses to
//  flash on a single frame.
//

import XCTest
@testable import MagicCamera

final class CaptureGuidanceTests: XCTestCase {

    // Roughly an iPhone rear camera at 1920×1440.
    private let focal: Float = 1500
    private let width: Float = 1920

    // MARK: - Projected velocity

    func testSameSpeedFarIsCalmAndNearIsNot() {
        // 0.4 m/s — a stroll — across a large room.
        let far = CaptureGuidance.imageSpeed(linearSpeed: 0.4, angularSpeed: 0,
                                             subjectDistance: 3.0,
                                             focalLength: focal, imageWidth: width)
        // The same 0.4 m/s, 25 cm from a mug.
        let near = CaptureGuidance.imageSpeed(linearSpeed: 0.4, angularSpeed: 0,
                                              subjectDistance: 0.25,
                                              focalLength: focal, imageWidth: width)
        XCTAssertLessThan(far, CaptureGuidance.maxImageSpeed,
                          "a stroll across a room is fine")
        XCTAssertGreaterThan(near, CaptureGuidance.maxImageSpeed,
                             "the same metres per second up close sweeps the frame")
        XCTAssertGreaterThan(near, far * 10, "image speed scales as 1/distance")
    }

    func testRotationCountsWithoutADistance() {
        let speed = CaptureGuidance.imageSpeed(linearSpeed: 0, angularSpeed: 1.0,
                                               subjectDistance: 0,
                                               focalLength: focal, imageWidth: width)
        XCTAssertGreaterThan(speed, CaptureGuidance.maxImageSpeed,
                             "~57°/s sweeps most of the frame per second")
    }

    func testUnknownDistanceDropsTheTranslationTerm() {
        let speed = CaptureGuidance.imageSpeed(linearSpeed: 5, angularSpeed: 0,
                                               subjectDistance: 0,
                                               focalLength: focal, imageWidth: width)
        XCTAssertEqual(speed, 0, "no distance = no divisor, not a divide by zero")
    }

    func testDegenerateCameraIsSilent() {
        XCTAssertEqual(CaptureGuidance.imageSpeed(linearSpeed: 1, angularSpeed: 1,
                                                  subjectDistance: 1,
                                                  focalLength: 0, imageWidth: width), 0)
        XCTAssertEqual(CaptureGuidance.imageSpeed(linearSpeed: 1, angularSpeed: 1,
                                                  subjectDistance: 1,
                                                  focalLength: focal, imageWidth: 0), 0)
    }

    // MARK: - Verdict

    func testCalmWellLitFrameSaysNothing() {
        var signals = CaptureGuidance.Signals()
        signals.ambientIntensity = 900
        signals.featurePoints = 300
        signals.imageSpeed = 0.15
        signals.subjectDistance = 1.2
        XCTAssertEqual(CaptureGuidance.hint(for: signals), .none)
    }

    func testFastAndFarSaysSlowDown() {
        var signals = CaptureGuidance.Signals()
        signals.ambientIntensity = 900
        signals.imageSpeed = CaptureGuidance.maxImageSpeed + 0.2
        signals.subjectDistance = 2.0
        XCTAssertEqual(CaptureGuidance.hint(for: signals), .slowDown)
    }

    func testFastAndCloseSaysMoveBack() {
        var signals = CaptureGuidance.Signals()
        signals.ambientIntensity = 900
        signals.imageSpeed = CaptureGuidance.maxImageSpeed + 0.2
        signals.subjectDistance = 0.25
        XCTAssertEqual(CaptureGuidance.hint(for: signals), .moveBack,
                       "up close, backing off fixes what slowing down barely can")
    }

    func testMotionOutranksDarkness() {
        var signals = CaptureGuidance.Signals()
        signals.ambientIntensity = 50
        signals.imageSpeed = CaptureGuidance.maxImageSpeed + 0.2
        signals.subjectDistance = 2.0
        XCTAssertEqual(CaptureGuidance.hint(for: signals), .slowDown,
                       "motion is already costing frames — say that first")
    }

    func testDarkFrameAsksForLight() {
        var signals = CaptureGuidance.Signals()
        signals.ambientIntensity = 80
        signals.featurePoints = 400
        XCTAssertEqual(CaptureGuidance.hint(for: signals), .light,
                       "dark enough is dark regardless of tracking")
    }

    func testDimButRichlyTexturedIsLeftAlone() {
        var signals = CaptureGuidance.Signals()
        signals.ambientIntensity = 250
        signals.featurePoints = 400
        XCTAssertEqual(CaptureGuidance.hint(for: signals), .none,
                       "dim only matters when tracking is also thin")
    }

    func testDimAndFeaturelessAsksForLight() {
        var signals = CaptureGuidance.Signals()
        signals.ambientIntensity = 250
        signals.featurePoints = 10
        XCTAssertEqual(CaptureGuidance.hint(for: signals), .light)
    }

    func testUnknownLightIsNotDarkness() {
        var signals = CaptureGuidance.Signals()
        signals.ambientIntensity = 0
        signals.featurePoints = 0
        XCTAssertEqual(CaptureGuidance.hint(for: signals), .none,
                       "no light estimate is not evidence of a dark room")
    }

    // MARK: - Hysteresis

    func testOneBadFrameNeverShows() {
        var stabiliser = CaptureGuidance.Stabiliser(holdFrames: 3)
        XCTAssertNil(stabiliser.update(.slowDown))
        XCTAssertNil(stabiliser.update(.none))
        XCTAssertNil(stabiliser.update(.none))
        XCTAssertEqual(stabiliser.published, .none)
    }

    func testSustainedHintPublishesOnce() {
        var stabiliser = CaptureGuidance.Stabiliser(holdFrames: 3)
        XCTAssertNil(stabiliser.update(.slowDown))
        XCTAssertNil(stabiliser.update(.slowDown))
        XCTAssertEqual(stabiliser.update(.slowDown), .slowDown)
        XCTAssertNil(stabiliser.update(.slowDown), "no repeat once it is published")
        XCTAssertEqual(stabiliser.published, .slowDown)
    }

    func testClearingIsHeldToo() {
        var stabiliser = CaptureGuidance.Stabiliser(holdFrames: 2)
        _ = stabiliser.update(.slowDown)
        XCTAssertEqual(stabiliser.update(.slowDown), .slowDown)
        XCTAssertNil(stabiliser.update(.none), "one calm frame doesn't clear it")
        XCTAssertEqual(stabiliser.update(.none), CaptureGuidance.Hint.none)
    }

    func testResetDropsEverything() {
        var stabiliser = CaptureGuidance.Stabiliser(holdFrames: 1)
        XCTAssertEqual(stabiliser.update(.light), .light)
        stabiliser.reset()
        XCTAssertEqual(stabiliser.published, .none)
        XCTAssertEqual(stabiliser.update(.light), .light, "a fresh scan can warn again")
    }
}
