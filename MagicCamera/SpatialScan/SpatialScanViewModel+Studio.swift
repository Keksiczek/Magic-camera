//
//  SpatialScanViewModel+Studio.swift
//  Magic Camera
//
//  Studio command orchestration. `runStudioCommand` drives the transcript and
//  the one-shot undo snapshot; `studioPerform` is the single validated
//  executor every Studio tool funnels through — it mirrors the Auto-fix
//  runner: re-validate preconditions on live state, fire the existing
//  operation, wait for the exclusive slot to clear, then report what actually
//  happened so the model can summarise honestly.
//

import SwiftUI

extension SpatialScanViewModel {

    func closeStudio() { isStudioActive = false }

    /// Clears the panel, transcript and model session — called whenever the
    /// reviewed scan is replaced or discarded (the conversation context would
    /// describe a scan that no longer exists).
    func resetStudio() {
        isStudioActive = false
        isStudioBusy = false
        studioTranscript = []
        studioSessionStorage = nil
    }

    /// Sends one user sentence through the Studio engine. A state snapshot is
    /// taken first so the whole command (however many tools it runs) can be
    /// undone in one tap, exactly like Auto-fix.
    func runStudioCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStudioBusy, !isBusy, !isAutoFixing, hasResult else { return }
        studioTranscript.append(StudioLine(role: .user, text: trimmed))
        isStudioBusy = true
        autoFixBackup = AutoFixBackup(cloud: capturedCloud,
                                      viewDirections: capturedViewDirections,
                                      mesh: capturedMesh,
                                      textured: texturedMesh)
        Task { [weak self] in
            guard let self else { return }
            let reply = await StudioEngine.respond(to: trimmed, viewModel: self)
            self.studioTranscript.append(StudioLine(role: .assistant, text: reply))
            self.isStudioBusy = false
        }
    }

    // MARK: - Tool execution

    /// Executes one Studio tool call. Plans come from a model, so every step
    /// is re-validated here before anything runs (the runAutoFixStep contract).
    /// Returns a short factual result string for the model.
    func studioPerform(_ step: StudioStep, amount: Double?) async -> String {
        guard !isAutoFixing else { return "Auto-fix is running — wait for it to finish." }

        // Read-only: answer from the fact sheet without claiming the op slot.
        if step == .describe {
            if let mesh = effectiveMesh {
                return ScanFacts.facts(mesh: mesh, isTextured: texturedMesh != nil,
                                       hasKeyframes: !textureKeyframes.isEmpty).promptBlock
            }
            if let cloud = capturedCloud {
                return ScanFacts.facts(cloud: cloud,
                                       hasKeyframes: !textureKeyframes.isEmpty).promptBlock
            }
            return "Nothing is captured yet."
        }

        let needsCloud = "There is no point cloud — cloud tools only apply before reconstruction."
        let needsMesh = "There is no mesh yet — reconstruct the point cloud first."
        let cloudBefore = capturedCloud?.count ?? 0
        let trisBefore = effectiveMesh?.triangleCount ?? 0

        switch step {
        case .matteFilter:
            guard capturedCloud != nil else { return needsCloud }
            removeUnreliablePoints()
        case .cleanUp:
            guard capturedCloud != nil else { return needsCloud }
            cleanUpCloud()
        case .isolate:
            guard capturedCloud != nil else { return needsCloud }
            isolateSubject()
        case .reconstruct:
            guard capturedCloud != nil else {
                return "There is already a mesh — reconstruct only applies to a point cloud."
            }
            reconstructMesh()
        case .closeBase:
            guard effectiveMesh != nil else { return needsMesh }
            closeBase()
        case .optimize:
            guard effectiveMesh != nil else { return needsMesh }
            optimizeMesh()
        case .fillHoles:
            guard effectiveMesh != nil else { return needsMesh }
            fillHoles()
        case .decimate:
            guard effectiveMesh != nil else { return needsMesh }
            decimateMesh()
        case .bakeTexture:
            guard effectiveMesh != nil else { return needsMesh }
            guard texturedMesh == nil else { return "The mesh is already textured." }
            guard canBakeTexture else {
                return "No texture source available — texturing needs this session's photos or point colours."
            }
            bakeTexture()
        case .makePrintable:
            guard effectiveMesh != nil else { return needsMesh }
            makePrintable()
        case .scaleModel:
            guard let amount, amount.isFinite, amount >= 0.05, amount <= 20 else {
                return "Scale factor must be between 0.05 and 20."
            }
            guard hasResult else { return "Nothing is captured yet." }
            scaleModel(factor: Float(amount))
        case .rotateModel:
            guard let amount, amount.isFinite else { return "Rotation needs an angle in degrees." }
            guard hasResult else { return "Nothing is captured yet." }
            rotateModel(degreesY: Float(amount))
        case .mirror:
            guard hasResult else { return "Nothing is captured yet." }
            let axis = Int((amount ?? 0).rounded())
            guard (0...2).contains(axis) else {
                return "Mirror axis must be 0 (left-right), 1 (up-down) or 2 (front-back)."
            }
            mirrorModel(axis: axis)
        case .describe:
            return ""   // handled above
        }

        // The operations claim the exclusive slot synchronously when they
        // start; if it is free the tool was rejected by its own guards.
        guard activeOperation != nil else {
            return "The tool didn't start — another operation may already be running."
        }
        // Wait the operation out (the Auto-fix runner pattern), with a hard
        // cap so a wedged run can't hang the session forever.
        var waited = 0.0
        while activeOperation != nil && waited < 900 {
            try? await Task.sleep(for: .milliseconds(120))
            waited += 0.12
        }
        guard activeOperation == nil else {
            return "The operation is taking unusually long and is still running."
        }
        return studioResult(for: step, cloudBefore: cloudBefore,
                            trisBefore: trisBefore, amount: amount)
    }

    /// Factual post-state report for a finished step — diffs the live state
    /// against the counts captured before the run.
    private func studioResult(for step: StudioStep, cloudBefore: Int,
                              trisBefore: Int, amount: Double?) -> String {
        let cloudNow = capturedCloud?.count ?? 0
        let trisNow = effectiveMesh?.triangleCount ?? 0
        switch step {
        case .matteFilter:
            let removed = cloudBefore - cloudNow
            return removed > 0
                ? "Matte filter removed \(removed) low-confidence points; \(cloudNow) remain."
                : "No low-confidence points found."
        case .cleanUp:
            let removed = cloudBefore - cloudNow
            return removed > 0
                ? "Removed \(removed) stray points; \(cloudNow) remain."
                : "The cloud was already clean."
        case .isolate:
            return cloudNow < cloudBefore
                ? "Isolated the subject — kept \(cloudNow) of \(cloudBefore) points."
                : "Isolation kept the whole cloud (no clear background found)."
        case .reconstruct:
            return effectiveMesh != nil
                ? "Built a surface mesh with \(trisNow) triangles. Cloud tools no longer apply."
                : "Reconstruction failed — the cloud may be too sparse."
        case .closeBase:
            let added = trisNow - trisBefore
            return added > 0
                ? "Closed the base, adding \(added) triangles."
                : "No open base found — the bottom is already closed."
        case .optimize:
            return "Smoothed the surface; \(trisNow) triangles."
        case .fillHoles:
            let added = trisNow - trisBefore
            return added > 0 ? "Filled small holes, adding \(added) triangles." : "No small holes found."
        case .decimate:
            return "Reduced the mesh from \(trisBefore) to \(trisNow) triangles."
        case .makePrintable:
            return "Closed the base, filled holes and smoothed — \(trisNow) triangles."
        case .mirror:
            return effectiveMesh != nil
                ? "Mirrored across the centre plane — \(trisNow) triangles."
                : "Mirrored across the centre plane — \(cloudNow) points."
        case .bakeTexture:
            if let textured = texturedMesh {
                return "Baked the texture (\(textured.textureSize)×\(textured.textureSize) atlas)."
            }
            return "Texture baking failed."
        case .scaleModel:
            let dims = dimensionsText ?? "unknown size"
            return String(format: "Scaled by %.2f× — the model is now %@.", amount ?? 1, dims)
        case .rotateModel:
            return String(format: "Rotated %.0f° around the vertical axis.", amount ?? 0)
        case .describe:
            return ""
        }
    }
}
