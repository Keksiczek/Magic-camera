//
//  ModelStudioEngine.swift
//  Magic Camera
//
//  Prompt-driven model building for the standalone Model Studio screen. One
//  user sentence ("build a snowman", "make the roof red and twice as big") is
//  routed by the on-device FoundationModels session through tool calling to
//  the deterministic stage operations on ModelStudioViewModel — the same
//  contract as the scan Studio: the model never touches geometry, every tool
//  re-validates against the live stage and reports what actually happened.
//
//  Below iOS 26 (or with Apple Intelligence off) the chat explains itself;
//  the manual tools keep working regardless.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tool vocabulary the Model Studio chat may execute. Stage mutations funnel
/// through `ModelStudioViewModel`; this enum just names the calls.
enum ModelStudioCommand: Sendable {
    case add(shape: String, width: Double, height: Double, depth: Double, color: String)
    case move(object: String, dx: Double, dy: Double, dz: Double)
    case rotate(object: String, degrees: Double)
    case scale(object: String, factor: Double)
    case recolor(object: String, color: String)
    case duplicate(object: String)
    case delete(object: String)
    case smooth(object: String)
    case reduce(object: String)
    case mergeAll
    case describe
}

/// Weak bridge from the Sendable tool structs back to the main-actor view
/// model — file-scope for the same reason as the scan Studio's handle (the
/// nonisolated Tool protocol can't live inside a main-actor type).
final class ModelStudioHandle: @unchecked Sendable {
    @MainActor weak var viewModel: ModelStudioViewModel?
    @MainActor init(viewModel: ModelStudioViewModel) { self.viewModel = viewModel }
}

@MainActor
enum ModelStudioEngine {
    static var isAvailable: Bool { ScanIntelligence.isModelAvailable }

    static let unavailableMessage = """
        The Studio assistant needs the on-device Apple Intelligence model \
        (iOS 26 or later with Apple Intelligence enabled). The manual tools \
        below work without it.
        """

    /// Routes one user command through the model and its tools; returns the
    /// assistant reply for the transcript.
    static func respond(to text: String, viewModel: ModelStudioViewModel) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            return await modelRespond(to: text, viewModel: viewModel)
        }
        #endif
        return unavailableMessage
    }

    /// Shared executor for all tools: hops to the main actor, re-validates
    /// against the live stage and runs the deterministic operation.
    static func perform(_ command: ModelStudioCommand, handle: ModelStudioHandle) async -> String {
        guard let viewModel = handle.viewModel else { return "The Studio screen is no longer open." }
        switch command {
        case .add(let shape, let width, let height, let depth, let color):
            guard let parsed = PrimitiveShape.parse(shape) else {
                let names = PrimitiveShape.allCases.map(\.rawValue).joined(separator: ", ")
                return "Unknown shape “\(shape)” — available: \(names)."
            }
            return viewModel.addPrimitive(parsed,
                                          size: SIMD3(Float(width), Float(height), Float(depth)),
                                          colorName: color)
        case .move(let object, let dx, let dy, let dz):
            return viewModel.moveObject(object, by: SIMD3(Float(dx), Float(dy), Float(dz)))
        case .rotate(let object, let degrees):
            return viewModel.rotateObject(object, degreesY: Float(degrees))
        case .scale(let object, let factor):
            return viewModel.scaleObject(object, factor: Float(factor))
        case .recolor(let object, let color):
            return viewModel.recolorObject(object, colorName: color)
        case .duplicate(let object):
            return viewModel.duplicateObject(object)
        case .delete(let object):
            return viewModel.deleteObject(object)
        case .smooth(let object):
            return await viewModel.smoothObject(object)
        case .reduce(let object):
            return await viewModel.reduceObject(object)
        case .mergeAll:
            return viewModel.mergeAll()
        case .describe:
            return viewModel.describeScene()
        }
    }

    /// Compact live-stage line prepended to every prompt so the model plans
    /// against reality instead of a stale transcript.
    private static func factsLine(_ viewModel: ModelStudioViewModel) -> String {
        guard !viewModel.objects.isEmpty else {
            return "[stage now: empty — no objects yet]"
        }
        var parts = viewModel.objects.prefix(10).map { object -> String in
            let d = object.dimensions
            return String(format: "%@ (%@, %.2f×%.2f×%.2f m)",
                          object.name, object.colorName, d.x, d.y, d.z)
        }
        if viewModel.objects.count > 10 {
            parts.append("+\(viewModel.objects.count - 10) more")
        }
        let selected = viewModel.selectedObject.map { " · selected: \($0.name)" } ?? ""
        return "[stage now: " + parts.joined(separator: " · ") + selected + "]"
    }

    #if canImport(FoundationModels)

    @available(iOS 26.0, *)
    private static func modelRespond(to text: String,
                                     viewModel: ModelStudioViewModel) async -> String {
        let session: LanguageModelSession
        if let existing = viewModel.chatSessionStorage as? LanguageModelSession {
            session = existing
        } else {
            session = makeSession(handle: ModelStudioHandle(viewModel: viewModel))
            viewModel.chatSessionStorage = session
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
            // Most likely a filled context window — recreate and retry once.
            let fresh = makeSession(handle: ModelStudioHandle(viewModel: viewModel))
            viewModel.chatSessionStorage = fresh
            if let response = try? await fresh.respond(to: prompt) {
                let reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty { return reply }
            }
            return "Studio couldn't process that. Try a shorter, more specific instruction."
        }
    }

    @available(iOS 26.0, *)
    private static func makeSession(handle: ModelStudioHandle) -> LanguageModelSession {
        let tools: [any Tool] = [
            AddShapeTool(handle: handle),
            MoveObjectTool(handle: handle),
            RotateObjectTool(handle: handle),
            ScaleObjectTool(handle: handle),
            ColorObjectTool(handle: handle),
            DuplicateObjectTool(handle: handle),
            DeleteObjectTool(handle: handle),
            SmoothObjectTool(handle: handle),
            ReduceObjectTool(handle: handle),
            MergeAllTool(handle: handle),
            DescribeStageTool(handle: handle),
        ]
        return LanguageModelSession(tools: tools, instructions: """
            You are Studio, the model-building assistant in a 3D scanning app. \
            The user composes 3D models on a small stage; a [stage now: …] line \
            states the live objects. You never create or edit geometry yourself \
            — you only call the provided tools and report what they returned. \
            Build requests from primitives: a snowman is three stacked spheres, \
            a table is a box top on four cylinder legs, a tree is a cone on a \
            cylinder. Units are metres; y is up; the ground is y = 0; objects \
            keep their base on the ground unless moved up. New objects appear \
            beside the others — move them into position yourself. Refer to \
            objects by the names in the stage line. Call one tool at a time and \
            adapt to each result. Never invent tools or results. Finish with \
            one or two short sentences summarising what happened.
            """)
    }

    #endif
}

#if canImport(FoundationModels)

@available(iOS 26.0, *)
private struct AddShapeTool: Tool {
    let handle: ModelStudioHandle
    let name = "addShape"
    let description = """
        Add a primitive to the stage: box, sphere, cylinder, cone, torus or \
        plane. Size is the bounding box in metres; colour is a simple name \
        like red, blue, brown or gray.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Shape: box, sphere, cylinder, cone, torus or plane")
        var shape: String
        @Guide(description: "Width in metres (x)", .range(0.01...10.0))
        var widthMeters: Double
        @Guide(description: "Height in metres (y)", .range(0.0...10.0))
        var heightMeters: Double
        @Guide(description: "Depth in metres (z)", .range(0.01...10.0))
        var depthMeters: Double
        @Guide(description: "Colour name, e.g. red, orange, green, blue, white, brown; use gray for no preference")
        var color: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.add(shape: arguments.shape,
                                             width: arguments.widthMeters,
                                             height: arguments.heightMeters,
                                             depth: arguments.depthMeters,
                                             color: arguments.color), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct MoveObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "moveObject"
    let description = "Move an object by an offset in metres. y is up (positive dy lifts it)."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to move")
        var object: String
        @Guide(description: "Offset along x in metres", .range(-10.0...10.0))
        var dxMeters: Double
        @Guide(description: "Offset along y (up) in metres", .range(-10.0...10.0))
        var dyMeters: Double
        @Guide(description: "Offset along z in metres", .range(-10.0...10.0))
        var dzMeters: Double
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.move(object: arguments.object,
                                              dx: arguments.dxMeters,
                                              dy: arguments.dyMeters,
                                              dz: arguments.dzMeters), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct RotateObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "rotateObject"
    let description = "Rotate an object around the vertical axis by an angle in degrees."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to rotate")
        var object: String
        @Guide(description: "Angle in degrees, e.g. 45 or -90", .range(-360.0...360.0))
        var degrees: Double
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.rotate(object: arguments.object,
                                                degrees: arguments.degrees), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct ScaleObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "scaleObject"
    let description = "Uniformly scale an object about its base. factor 1.2 = 20% bigger, 0.5 = half size."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to scale")
        var object: String
        @Guide(description: "Scale factor, e.g. 1.2 for 20% bigger", .range(0.05...20.0))
        var factor: Double
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.scale(object: arguments.object,
                                               factor: arguments.factor), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct ColorObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "colorObject"
    let description = "Change an object's colour to a named colour (red, orange, yellow, green, mint, teal, blue, purple, pink, brown, white, gray, black)."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to recolour")
        var object: String
        @Guide(description: "Colour name, e.g. red")
        var color: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.recolor(object: arguments.object,
                                                 color: arguments.color), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct DuplicateObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "duplicateObject"
    let description = "Duplicate an object; the copy appears beside the original."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to duplicate")
        var object: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.duplicate(object: arguments.object), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct DeleteObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "deleteObject"
    let description = "Remove an object from the stage."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to delete")
        var object: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.delete(object: arguments.object), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct SmoothObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "smoothObject"
    let description = "Smooth an object's surface (good after merging or on rough scans)."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to smooth")
        var object: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.smooth(object: arguments.object), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct ReduceObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "reduceObject"
    let description = "Reduce an object's triangle count for lighter models."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to reduce")
        var object: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.reduce(object: arguments.object), handle: handle)
    }
}

@available(iOS 26.0, *)
private struct MergeAllTool: Tool {
    let handle: ModelStudioHandle
    let name = "mergeAll"
    let description = "Merge every object on the stage into one (the result takes a single colour)."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.mergeAll, handle: handle)
    }
}

@available(iOS 26.0, *)
private struct DescribeStageTool: Tool {
    let handle: ModelStudioHandle
    let name = "describeStage"
    let description = "Read the live stage: every object's name, colour, size, triangle count and position."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.describe, handle: handle)
    }
}

#endif
