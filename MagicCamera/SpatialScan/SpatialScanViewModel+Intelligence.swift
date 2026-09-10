//
//  SpatialScanViewModel+Intelligence.swift
//  Magic Camera
//
//  Scan report + Auto-fix orchestration. The model (or the heuristic fallback)
//  only ever decides *which* of the existing deterministic tools to run and in
//  what order — geometry math stays in the tools themselves. Auto-fix keeps a
//  one-shot backup so the whole sequence can be undone in one tap.
//

import SwiftUI

/// Snapshot of the review state taken before an auto-fix run.
struct AutoFixBackup {
    var cloud: PointCloud?
    var viewDirections: [SIMD3<Float>]?
    var mesh: MeshData?
    var textured: TexturedMesh?
}

extension SpatialScanViewModel {

    // MARK: - Scan report

    /// Builds the fact sheet off-main and asks the on-device model for a
    /// readable description (deterministic summary when AI is unavailable).
    func describeScan() {
        guard !isDescribing, capturedCloud != nil || capturedMesh != nil else { return }
        isDescribing = true
        let cloudBox = UncheckedSendableBox(capturedCloud)
        let meshBox = UncheckedSendableBox(effectiveMesh)
        let isTextured = texturedMesh != nil
        let hasKeyframes = !textureKeyframes.isEmpty
        Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) { () async -> String in
                let facts: ScanFacts
                if let mesh = meshBox.value {
                    facts = ScanFacts.facts(mesh: mesh, isTextured: isTextured,
                                            hasKeyframes: hasKeyframes)
                } else if let cloud = cloudBox.value {
                    facts = ScanFacts.facts(cloud: cloud, hasKeyframes: hasKeyframes)
                } else {
                    return "Nothing to describe yet."
                }
                return await ScanIntelligence.describeScene(facts: facts)
            }.value
            guard let self else { return }
            self.isDescribing = false
            self.sceneReport = report
        }
    }

    // MARK: - Auto-fix

    /// Plans a clean-up sequence (on-device model, heuristic fallback) and
    /// runs it through the existing tools, waiting for each to finish.
    func autoFix() {
        guard !isAutoFixing, !isBusy,
              capturedCloud != nil || capturedMesh != nil else { return }
        isAutoFixing = true
        showToast("Auto-fix: planning…")
        autoFixBackup = AutoFixBackup(cloud: capturedCloud,
                                      viewDirections: capturedViewDirections,
                                      mesh: capturedMesh,
                                      textured: texturedMesh)
        let cloudBox = UncheckedSendableBox(capturedCloud)
        let meshBox = UncheckedSendableBox(effectiveMesh)
        let isTextured = texturedMesh != nil
        let hasKeyframes = !textureKeyframes.isEmpty
        Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) { () async -> [AutoFixStep] in
                let facts: ScanFacts
                if let mesh = meshBox.value {
                    facts = ScanFacts.facts(mesh: mesh, isTextured: isTextured,
                                            hasKeyframes: hasKeyframes)
                } else if let cloud = cloudBox.value {
                    facts = ScanFacts.facts(cloud: cloud, hasKeyframes: hasKeyframes)
                } else {
                    return []
                }
                return await ScanIntelligence.planAutoFix(facts: facts)
            }.value
            guard let self else { return }
            guard !plan.isEmpty else {
                self.isAutoFixing = false
                self.autoFixBackup = nil
                self.showToast("Auto-fix: nothing to do")
                return
            }
            self.showToast("Auto-fix: " + plan.map(\.title).joined(separator: " → "))
            try? await Task.sleep(for: .seconds(1.2))   // let the plan toast land

            var executed: [AutoFixStep] = []
            for step in plan {
                guard self.runAutoFixStep(step) else { continue }
                executed.append(step)
                // Each tool claims the exclusive operation slot; wait it out.
                while self.activeOperation != nil {
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            self.isAutoFixing = false
            self.showToast(executed.isEmpty
                           ? "Auto-fix: nothing applied"
                           : "Auto-fix done · " + executed.map(\.title).joined(separator: " → "))
        }
    }

    /// Restores the state captured before the last auto-fix run.
    func undoAutoFix() {
        guard let backup = autoFixBackup, !isBusy, !isAutoFixing else { return }
        capturedCloud = backup.cloud
        capturedViewDirections = backup.viewDirections   // after cloud (didSet clears it)
        capturedMesh = backup.mesh
        texturedMesh = backup.textured                   // after mesh (didSet clears it)
        removeStructure = false
        scanKind = backup.mesh != nil ? .mesh : .points
        pointCount = backup.mesh?.triangleCount ?? backup.cloud?.count ?? 0
        autoFixBackup = nil
        showToast("Auto-fix undone")
    }

    // MARK: - Recipes

    /// Runs a post-processing recipe: the two review buttons, and Auto-fix, all
    /// come through here.
    ///
    /// There is deliberately no second implementation for "what the app does by
    /// itself". A button runs `ScanRecipe.standard(...)`; the user editing the
    /// disclosure runs the same structure with different steps. That is what makes
    /// "I want to click together the same post-process it would have done" true by
    /// construction rather than by two functions being kept in sync.
    func runRecipe(_ recipe: ScanRecipe) {
        guard !isBusy, !isAutoFixing, !recipe.steps.isEmpty else { return }
        isAutoFixing = true
        autoFixBackup = AutoFixBackup(cloud: capturedCloud,
                                      viewDirections: capturedViewDirections,
                                      mesh: capturedMesh,
                                      textured: texturedMesh)
        // The recipe's reconstruction settings are the ones the steps run with —
        // otherwise the disclosure would show a method the run ignores.
        reconstructMethod = recipe.method
        reconstructDetail = recipe.detail
        Diagnostics.shared.log("recipe",
            "\(recipe.kind.rawValue)\(recipe.isStandard ? " (standard)" : " (edited)")"
            + " · \(recipe.summary) · \(recipe.method.rawValue)/\(recipe.detail.rawValue)")
        showToast("\(recipe.kind.rawValue): " + recipe.summary)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))   // let the plan toast land
            guard let self else { return }
            var executed: [AutoFixStep] = []
            for step in recipe.steps {
                guard self.runAutoFixStep(step) else { continue }
                executed.append(step)
                // Each tool claims the exclusive operation slot; wait it out.
                while self.activeOperation != nil {
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            self.isAutoFixing = false
            self.showToast(executed.isEmpty
                           ? "\(recipe.kind.rawValue): nothing applied"
                           : "\(recipe.kind.rawValue) done · "
                             + executed.map(\.title).joined(separator: " → "))
        }
    }

    /// The recipe the app would run right now — what the review screen shows
    /// pre-filled under each button.
    func standardRecipe(_ kind: ScanRecipe.Kind) -> ScanRecipe {
        let facts: ScanFacts
        if let mesh = effectiveMesh {
            facts = ScanFacts.facts(mesh: mesh, isTextured: texturedMesh != nil,
                                    hasKeyframes: !textureKeyframes.isEmpty)
        } else if let cloud = capturedCloud {
            facts = ScanFacts.facts(cloud: cloud, hasKeyframes: !textureKeyframes.isEmpty)
        } else {
            return ScanRecipe(kind: kind, steps: [], method: reconstructMethod,
                              detail: reconstructDetail, isStandard: true)
        }
        return ScanRecipe.standard(kind, facts: facts, profile: captureProfile)
    }

    /// Fires the tool for a step when its preconditions hold; false skips it.
    /// Plans come from a model, so every step is re-validated here.
    private func runAutoFixStep(_ step: AutoFixStep) -> Bool {
        switch step {
        case .matteFilter:
            guard capturedCloud != nil else { return false }
            removeUnreliablePoints()
        case .cleanUp:
            guard capturedCloud != nil else { return false }
            cleanUpCloud()
        case .isolate:
            guard capturedCloud != nil else { return false }
            isolateSubject()
        case .reconstruct:
            guard capturedCloud != nil else { return false }
            reconstructMesh()
        case .closeBase:
            guard effectiveMesh != nil else { return false }
            closeBase()
        case .optimize:
            guard effectiveMesh != nil else { return false }
            optimizeMesh()
        case .fillHoles:
            guard effectiveMesh != nil else { return false }
            fillHoles()
        case .bakeTexture:
            guard canBakeTexture, texturedMesh == nil else { return false }
            bakeTexture()
        }
        return true
    }
}
