//
//  ScanRecipe.swift
//  Magic Camera
//
//  What happens to a scan after it is captured, as something the user can see and
//  change — not as a hidden path the app takes on their behalf.
//
//  The rule this type exists to enforce, in the user's words: *"I want to be able
//  to click together the same post-process it would have done by itself."* So
//  there is no automatic path and manual path. There is one ordered list of steps,
//  and the two buttons on the review screen are simply that list, pre-filled.
//  Pressing "3D model" runs exactly the recipe the disclosure below it is showing,
//  and every step in it can be turned off, reordered by choosing a different
//  recipe, or run alone from the tools drawer.
//
//  Both recipes are built from `ScanIntelligence.heuristicPlan`, the same function
//  Auto-fix has always planned with, so "the best for this case" is one definition
//  rather than three that drift.
//

import Foundation

/// An ordered post-processing plan plus the reconstruction settings it runs with.
struct ScanRecipe: Equatable, Sendable {

    /// The two things a user wants from a finished scan.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        /// Pull the subject out of its surroundings and close it into a solid —
        /// the isolate → reconstruct → close-base → texture workflow.
        case model = "3D model"
        /// Keep everything and turn it into a surface — the room / area workflow,
        /// with no isolation step that would throw the scene away.
        case surface = "Surface"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .model:   return "cube"
            case .surface: return "square.3.layers.3d"
            }
        }

        /// One line under the button. Says what it will DO, not what it is.
        var detailLine: String {
            switch self {
            case .model:
                return "Lifts the subject off its surroundings, closes the underside and textures it."
            case .surface:
                return "Turns everything you captured into one textured surface."
            }
        }
    }

    var kind: Kind
    /// The steps, in the order they will run. Empty means "nothing to do".
    var steps: [AutoFixStep]
    var method: ReconstructionMethod
    var detail: MeshDetail

    /// True when this is exactly what the app would have chosen — what the
    /// disclosure shows before the user touches anything.
    var isStandard: Bool

    // MARK: - The defaults

    /// The recipe the app would run on its own. **This is the only definition of
    /// "best for this case"** — the buttons, the disclosure and Auto-fix all read
    /// it, so what the user sees pre-filled is what would have happened.
    ///
    /// `facts` decides the details (a cloud with no keyframes gets no texture
    /// step; a mesh skips the cloud tools); `profile` supplies the reconstruction
    /// method and detail the capture was set up for, so a Max scan reconstructs at
    /// Max without the user re-stating it.
    static func standard(_ kind: Kind, facts: ScanFacts,
                         profile: CaptureProfile) -> ScanRecipe {
        let planned = ScanIntelligence.heuristicPlan(facts: facts)
        let steps: [AutoFixStep]
        switch kind {
        case .model:
            // The heuristic already isolates when the scan looks object-sized.
            // Asking for a 3-D model says so explicitly, so add it (in the right
            // place — before reconstruct, after the cloud is cleaned) when the
            // size test did not, and keep the base cap that goes with it.
            steps = withSubjectSteps(planned, facts: facts)
        case .surface:
            // A surface keeps the scene. Isolation and the base cap are exactly
            // the two steps that would throw part of it away.
            steps = planned.filter { $0 != .isolate && $0 != .closeBase }
        }
        return ScanRecipe(kind: kind, steps: steps,
                          method: profile.reconstructMethod,
                          detail: profile.reconstructDetail,
                          isStandard: true)
    }

    /// Inserts `isolate` before `reconstruct` and `closeBase` after it, if the
    /// plan does not already have them and the scan is a cloud (a mesh has been
    /// reconstructed already, and isolating it is a different tool).
    private static func withSubjectSteps(_ plan: [AutoFixStep],
                                         facts: ScanFacts) -> [AutoFixStep] {
        guard facts.kind == .pointCloud else { return plan }
        var steps = plan
        if !steps.contains(.isolate), let at = steps.firstIndex(of: .reconstruct) {
            steps.insert(.isolate, at: at)
        }
        if !steps.contains(.closeBase), let at = steps.firstIndex(of: .reconstruct) {
            steps.insert(.closeBase, at: steps.index(after: at))
        }
        return steps
    }

    // MARK: - Editing

    /// Turns a step on or off, keeping the canonical order so a user cannot build
    /// a plan that runs the mesh tools before the mesh exists.
    func setting(_ step: AutoFixStep, enabled: Bool) -> ScanRecipe {
        var copy = self
        if enabled {
            guard !copy.steps.contains(step) else { return copy }
            copy.steps = AutoFixStep.canonicalOrder.filter {
                copy.steps.contains($0) || $0 == step
            }
        } else {
            copy.steps.removeAll { $0 == step }
        }
        copy.isStandard = false
        return copy
    }

    func with(method: ReconstructionMethod) -> ScanRecipe {
        var copy = self
        copy.method = method
        copy.isStandard = false
        return copy
    }

    func with(detail: MeshDetail) -> ScanRecipe {
        var copy = self
        copy.detail = detail
        copy.isStandard = false
        return copy
    }

    /// Steps this recipe leaves out, so the disclosure can offer them.
    var omittedSteps: [AutoFixStep] {
        AutoFixStep.canonicalOrder.filter { !steps.contains($0) }
    }

    var summary: String {
        steps.isEmpty ? "Nothing to do" : steps.map(\.title).joined(separator: " → ")
    }
}

extension AutoFixStep {
    /// The only order in which these steps make sense: the cloud tools before the
    /// reconstruction that consumes the cloud, the mesh tools after it.
    static let canonicalOrder: [AutoFixStep] = [
        .matteFilter, .cleanUp, .isolate, .reconstruct,
        .closeBase, .optimize, .fillHoles, .bakeTexture,
    ]

    /// What this step is for, in one line, for the disclosure. The user asked to
    /// be able to tell what each option is actually for.
    var purpose: String {
        switch self {
        case .matteFilter: return "Drops points the depth sensor was unsure about — shiny and dark surfaces."
        case .cleanUp:     return "Removes stray specks floating around the scan."
        case .isolate:     return "Keeps the subject and cuts away the floor and background."
        case .reconstruct: return "Turns the points into a surface."
        case .closeBase:   return "Caps the open underside left after isolating."
        case .optimize:    return "Smooths the surface."
        case .fillHoles:   return "Caps small holes."
        case .bakeTexture: return "Projects the photos taken during the scan onto the surface."
        }
    }

    /// Whether this step needs a mesh (rather than a cloud) to run.
    var needsMesh: Bool {
        switch self {
        case .matteFilter, .cleanUp, .isolate, .reconstruct: return false
        case .closeBase, .optimize, .fillHoles, .bakeTexture: return true
        }
    }
}
