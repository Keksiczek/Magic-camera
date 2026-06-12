//
//  StudioEngine.swift
//  Magic Camera
//
//  Studio mode: natural-language editing over the review state. One user
//  sentence ("isolate the mug, close the bottom and texture it") is routed by
//  the on-device model through tool calling to the same deterministic
//  operations the buttons run — the Auto-fix contract, generalised to
//  conversation and parameters. The model never touches geometry; every tool
//  re-validates preconditions on the live state before running.
//
//  Below iOS 26 (or with Apple Intelligence off) Studio explains itself
//  instead of degrading to a heuristic chat — there is no fallback parser.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One line of the Studio transcript.
struct StudioLine: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
}

/// Tool vocabulary Studio may execute — the Auto-fix steps plus decimation,
/// the parametric transforms and a read-only describe. Raw values double as
/// the tool names the model calls.
enum StudioStep: String, CaseIterable, Sendable {
    case matteFilter, cleanUp, isolate, reconstruct
    case closeBase, optimize, fillHoles, decimate, bakeTexture
    case scaleModel, rotateModel, describe
}

/// Weak bridge from the Sendable tool structs back to the main-actor view
/// model — weak so the session (stored on the view model) cannot retain-cycle
/// it. File-scope on purpose: nested types would inherit StudioEngine's
/// main-actor isolation, which the nonisolated Tool protocol can't satisfy.
final class StudioHandle: @unchecked Sendable {
    @MainActor weak var viewModel: SpatialScanViewModel?
    @MainActor init(viewModel: SpatialScanViewModel) { self.viewModel = viewModel }
}

@MainActor
enum StudioEngine {
    /// True when the on-device model can actually answer right now.
    static var isAvailable: Bool { ScanIntelligence.isModelAvailable }

    static let unavailableMessage = """
        Studio needs the on-device Apple Intelligence model (iOS 26 or later \
        with Apple Intelligence enabled). On this device, use the Edit tools \
        or Auto-fix instead.
        """

    /// Routes one user command through the model and its tools; returns the
    /// assistant reply for the transcript. The deterministic tools run via
    /// the view model's exclusive operation slot, exactly like button taps.
    static func respond(to text: String, viewModel: SpatialScanViewModel) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            return await modelRespond(to: text, viewModel: viewModel)
        }
        #endif
        return unavailableMessage
    }

    /// Shared executor for all tools: hops to the main actor, re-validates
    /// against the live state and runs the deterministic operation.
    static func perform(_ step: StudioStep, amount: Double?,
                        handle: StudioHandle) async -> String {
        guard let viewModel = handle.viewModel else { return "The scan view is no longer open." }
        return await viewModel.studioPerform(step, amount: amount)
    }

    /// Compact state line prepended to every prompt so the model plans against
    /// the live scan instead of a stale transcript.
    private static func factsLine(_ viewModel: SpatialScanViewModel) -> String {
        let d = viewModel.dimensions ?? .zero
        if let mesh = viewModel.effectiveMesh {
            return String(format: "[scan now: mesh · %d triangles · %.2f × %.2f × %.2f m%@%@]",
                          mesh.triangleCount, d.x, d.y, d.z,
                          viewModel.texturedMesh != nil ? " · textured" : "",
                          viewModel.canBakeTexture && viewModel.texturedMesh == nil
                              ? " · texture can be baked" : "")
        }
        if let cloud = viewModel.capturedCloud {
            return String(format: "[scan now: point cloud · %d points · %.2f × %.2f × %.2f m]",
                          cloud.count, d.x, d.y, d.z)
        }
        return "[scan now: nothing captured]"
    }

    #if canImport(FoundationModels)

    @available(iOS 26.0, *)
    private static func modelRespond(to text: String,
                                     viewModel: SpatialScanViewModel) async -> String {
        let session: LanguageModelSession
        if let existing = viewModel.studioSessionStorage as? LanguageModelSession {
            session = existing
        } else {
            session = makeSession(handle: StudioHandle(viewModel: viewModel))
            viewModel.studioSessionStorage = session
        }
        guard !session.isResponding else {
            return "Still finishing the previous request — try again in a moment."
        }
        let prompt = factsLine(viewModel) + "\n" + text
        do {
            let response = try await session.respond(to: prompt)
            let reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return reply.isEmpty ? "Done." : reply
        } catch {
            // Most likely the 4k context filled up over a long conversation —
            // start a fresh session (same tools/instructions) and retry once.
            let fresh = makeSession(handle: StudioHandle(viewModel: viewModel))
            viewModel.studioSessionStorage = fresh
            if let response = try? await fresh.respond(to: prompt) {
                let reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty { return reply }
            }
            return "Studio couldn't process that. Try a shorter, more specific instruction."
        }
    }

    @available(iOS 26.0, *)
    private static func makeSession(handle: StudioHandle) -> LanguageModelSession {
        let opTools: [(StudioStep, String)] = [
            (.matteFilter, "Remove low-confidence reflective noise from the point cloud."),
            (.cleanUp,     "Remove stray outlier points from the point cloud."),
            (.isolate,     "Cut the floor and background, keeping the main object (point cloud only)."),
            (.reconstruct, "Turn the point cloud into a smooth surface mesh."),
            (.closeBase,   "Cap the open bottom of the mesh so the object reads as a solid."),
            (.optimize,    "Smooth the mesh surface."),
            (.fillHoles,   "Cap small holes in the mesh."),
            (.decimate,    "Reduce the mesh triangle count for lighter exports."),
            (.bakeTexture, "Bake the photo or point-colour texture onto the mesh."),
            (.describe,    "Read the current scan's facts: kind, size, dimensions."),
        ]
        var tools: [any Tool] = opTools.map {
            StudioOpTool(step: $0.0, description: $0.1, handle: handle)
        }
        tools.append(StudioScaleTool(handle: handle))
        tools.append(StudioRotateTool(handle: handle))
        return LanguageModelSession(tools: tools, instructions: """
            You are Studio, the editing assistant inside a 3D scanning app. The \
            user has a captured scan and asks for edits in plain language; a \
            [scan now: …] line states the live state. You never edit geometry \
            yourself — you only call the provided tools and report what they \
            returned. Order matters: point-cloud tools (matteFilter, cleanUp, \
            isolate) work only before reconstruct; mesh tools (closeBase, \
            optimize, fillHoles, decimate, bakeTexture, scaleModel, rotateModel) \
            only once a mesh exists. Call one tool at a time and adapt to each \
            result. Never invent tools or results. Finish with one or two short \
            sentences summarising what happened.
            """)
    }

    #endif
}

#if canImport(FoundationModels)

/// Wraps one parameterless deterministic operation as a model tool.
@available(iOS 26.0, *)
private struct StudioOpTool: Tool {
    let step: StudioStep
    let description: String
    let handle: StudioHandle
    var name: String { step.rawValue }

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await StudioEngine.perform(step, amount: nil, handle: handle)
    }
}

@available(iOS 26.0, *)
private struct StudioScaleTool: Tool {
    let handle: StudioHandle
    let name = StudioStep.scaleModel.rawValue
    let description = "Uniformly scale the model about its centre. factor 1.2 = 20% bigger, 0.5 = half size."

    @Generable
    struct Arguments {
        @Guide(description: "Scale factor, e.g. 1.2 for 20% bigger", .range(0.05...20.0))
        var factor: Double
    }

    func call(arguments: Arguments) async throws -> String {
        await StudioEngine.perform(.scaleModel, amount: arguments.factor, handle: handle)
    }
}

@available(iOS 26.0, *)
private struct StudioRotateTool: Tool {
    let handle: StudioHandle
    let name = StudioStep.rotateModel.rawValue
    let description = "Rotate the model around the vertical axis by an angle in degrees (positive turns counter-clockwise seen from above)."

    @Generable
    struct Arguments {
        @Guide(description: "Rotation angle in degrees, e.g. 45 or -90", .range(-360.0...360.0))
        var degrees: Double
    }

    func call(arguments: Arguments) async throws -> String {
        await StudioEngine.perform(.rotateModel, amount: arguments.degrees, handle: handle)
    }
}

#endif
