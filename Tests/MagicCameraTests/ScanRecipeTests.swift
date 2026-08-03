//
//  ScanRecipeTests.swift
//  Magic Camera
//
//  The user's requirement, in their words: *"I want to be able to click together
//  the same post-process it would have done by itself."* That is a property, and
//  properties can be tested. These pin it:
//
//   · the standard recipe is built from the same heuristic the app has always
//     planned with, so there is no second definition of "best for this case";
//   · every step the app can run is reachable from the editor;
//   · editing is order-safe — a user cannot build a plan that runs the mesh tools
//     before the mesh exists.
//

import XCTest
import simd
@testable import MagicCamera

final class ScanRecipeTests: XCTestCase {

    private func objectCloudFacts(keyframes: Bool = true) -> ScanFacts {
        ScanFacts(kind: .pointCloud, count: 120_000,
                  dimensions: SIMD3(0.3, 0.25, 0.28),
                  lowConfidenceFraction: 0.08, hasKeyframes: keyframes)
    }

    private func roomCloudFacts(keyframes: Bool = true) -> ScanFacts {
        ScanFacts(kind: .pointCloud, count: 900_000,
                  dimensions: SIMD3(5.2, 2.6, 4.1),
                  lowConfidenceFraction: 0.02, hasKeyframes: keyframes)
    }

    private let objectProfile = CaptureProfile(subject: .object, detail: .max)
    private let roomProfile = CaptureProfile(subject: .room, detail: .balanced)

    // MARK: - The standard recipes are the app's own plan

    /// No second definition of "best": the standard recipe's steps must be the
    /// heuristic plan, modulo the one thing each button means.
    func testSurfaceRecipeIsTheHeuristicPlanWithoutTheSubjectSteps() {
        let facts = roomCloudFacts()
        let heuristic = ScanIntelligence.heuristicPlan(facts: facts)
        let recipe = ScanRecipe.standard(.surface, facts: facts, profile: roomProfile)
        XCTAssertEqual(recipe.steps, heuristic.filter { $0 != .isolate && $0 != .closeBase })
        XCTAssertTrue(recipe.isStandard)
    }

    /// Asking for a 3-D model says "this is a subject" out loud, so isolate and
    /// the base cap are present even when the size test alone would not add them.
    func testModelRecipeAlwaysIsolatesAndCapsTheBase() {
        for facts in [objectCloudFacts(), roomCloudFacts()] {
            let recipe = ScanRecipe.standard(.model, facts: facts, profile: objectProfile)
            XCTAssertTrue(recipe.steps.contains(.isolate), "model recipe must isolate")
            XCTAssertTrue(recipe.steps.contains(.closeBase), "model recipe must cap the base")
        }
    }

    /// …and in an order that can actually run.
    func testModelRecipeKeepsTheCanonicalOrder() {
        let recipe = ScanRecipe.standard(.model, facts: roomCloudFacts(), profile: objectProfile)
        let ranks = recipe.steps.compactMap { AutoFixStep.canonicalOrder.firstIndex(of: $0) }
        XCTAssertEqual(ranks, ranks.sorted(), "steps must stay in canonical order")
        if let isolate = recipe.steps.firstIndex(of: .isolate),
           let reconstruct = recipe.steps.firstIndex(of: .reconstruct),
           let base = recipe.steps.firstIndex(of: .closeBase) {
            XCTAssertLessThan(isolate, reconstruct, "isolate must precede reconstruct")
            XCTAssertLessThan(reconstruct, base, "the base is capped after the mesh exists")
        } else {
            XCTFail("model recipe is missing one of isolate/reconstruct/closeBase")
        }
    }

    /// A scan with no photos cannot be textured, and the recipe must not pretend.
    func testNoKeyframesMeansNoTextureStep() {
        let recipe = ScanRecipe.standard(.surface, facts: roomCloudFacts(keyframes: false),
                                         profile: roomProfile)
        XCTAssertFalse(recipe.steps.contains(.bakeTexture))
    }

    /// The reconstruction settings come from the capture, so a Max scan does not
    /// have to be told twice.
    func testRecipeAdoptsTheCaptureProfilesReconstruction() {
        let recipe = ScanRecipe.standard(.surface, facts: roomCloudFacts(), profile: roomProfile)
        XCTAssertEqual(recipe.method, roomProfile.reconstructMethod)
        XCTAssertEqual(recipe.detail, roomProfile.reconstructDetail)
    }

    // MARK: - Everything the app can do is reachable by hand

    /// The property the whole design rests on: no step exists that only the
    /// automatic path can run.
    func testEveryStepCanBeSwitchedOnByHand() {
        var recipe = ScanRecipe.standard(.surface, facts: roomCloudFacts(), profile: roomProfile)
        for step in AutoFixStep.allCases {
            recipe = recipe.setting(step, enabled: true)
            XCTAssertTrue(recipe.steps.contains(step), "\(step.title) is not reachable")
        }
        XCTAssertEqual(Set(recipe.steps), Set(AutoFixStep.allCases))
        XCTAssertEqual(recipe.steps, AutoFixStep.canonicalOrder,
                       "switching steps on must keep them runnable in order")
    }

    func testTurningAStepOffRemovesOnlyThatStep() {
        let recipe = ScanRecipe.standard(.model, facts: objectCloudFacts(), profile: objectProfile)
        let without = recipe.setting(.isolate, enabled: false)
        XCTAssertFalse(without.steps.contains(.isolate))
        XCTAssertEqual(without.steps, recipe.steps.filter { $0 != .isolate })
    }

    /// Editing marks the recipe as no longer standard, which is what lets the UI
    /// offer "back to the standard recipe" honestly.
    func testEditingClearsTheStandardFlag() {
        let recipe = ScanRecipe.standard(.surface, facts: roomCloudFacts(), profile: roomProfile)
        XCTAssertTrue(recipe.isStandard)
        XCTAssertFalse(recipe.setting(.optimize, enabled: true).isStandard)
        XCTAssertFalse(recipe.with(method: .voxel).isStandard)
        XCTAssertFalse(recipe.with(detail: .draft).isStandard)
    }

    func testEnablingAnAlreadyPresentStepIsANoOp() {
        let recipe = ScanRecipe.standard(.surface, facts: roomCloudFacts(), profile: roomProfile)
        guard let present = recipe.steps.first else { return XCTFail("empty recipe") }
        XCTAssertEqual(recipe.setting(present, enabled: true).steps, recipe.steps)
    }

    func testOmittedStepsAreExactlyTheRest() {
        let recipe = ScanRecipe.standard(.surface, facts: roomCloudFacts(), profile: roomProfile)
        XCTAssertEqual(Set(recipe.steps).union(recipe.omittedSteps),
                       Set(AutoFixStep.canonicalOrder))
        XCTAssertTrue(Set(recipe.steps).isDisjoint(with: Set(recipe.omittedSteps)))
    }

    // MARK: - Labelling

    /// The user asked to be able to tell what each option is for. Every step has
    /// to carry that line, and the mesh/cloud split has to be stated.
    func testEveryStepExplainsItself() {
        for step in AutoFixStep.allCases {
            XCTAssertFalse(step.title.isEmpty, "\(step.rawValue) has no title")
            XCTAssertFalse(step.purpose.isEmpty, "\(step.rawValue) has no purpose line")
        }
        XCTAssertFalse(AutoFixStep.reconstruct.needsMesh)
        XCTAssertTrue(AutoFixStep.bakeTexture.needsMesh)
    }

    func testCanonicalOrderCoversEveryStepExactlyOnce() {
        XCTAssertEqual(Set(AutoFixStep.canonicalOrder), Set(AutoFixStep.allCases))
        XCTAssertEqual(AutoFixStep.canonicalOrder.count, AutoFixStep.allCases.count)
        // The cloud tools all come before the first mesh tool.
        let firstMesh = AutoFixStep.canonicalOrder.firstIndex { $0.needsMesh } ?? 0
        XCTAssertTrue(AutoFixStep.canonicalOrder.prefix(firstMesh).allSatisfy { !$0.needsMesh })
        XCTAssertTrue(AutoFixStep.canonicalOrder.dropFirst(firstMesh).allSatisfy(\.needsMesh))
    }
}
