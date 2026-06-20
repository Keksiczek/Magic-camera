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
    case add(shape: String, width: Double, height: Double, depth: Double, color: String,
             x: Double, y: Double, z: Double)
    case move(object: String, dx: Double, dy: Double, dz: Double)
    case place(object: String, x: Double, y: Double, z: Double)
    case placeRelative(object: String, relativeTo: String, anchor: String)
    case rotate(object: String, degrees: Double)
    case scale(object: String, factor: Double)
    case recolor(object: String, color: String)
    case duplicate(object: String)
    case delete(object: String)
    case smooth(object: String)
    case reduce(object: String)
    case combine(objectA: String, objectB: String, operation: String)
    case mergeAll
    case describe
}

/// Where to place one object relative to another (Studio chat assembly helper).
enum RelativeAnchor: Sendable {
    case onTop, leftOf, rightOf, inFront, behind, beside

    /// Lenient parse of a model-supplied placement word.
    static func parse(_ raw: String) -> RelativeAnchor? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "ontop", "on top", "top", "above", "onto", "stack": return .onTop
        case "left", "leftof", "left of": return .leftOf
        case "right", "rightof", "right of": return .rightOf
        case "front", "infront", "in front", "ahead", "before": return .inFront
        case "back", "behind", "rear": return .behind
        case "beside", "next", "next to", "by", "near": return .beside
        default: return nil
        }
    }

    /// Human phrasing for the tool result line.
    var phrase: String {
        switch self {
        case .onTop:   return "on top of"
        case .leftOf:  return "left of"
        case .rightOf: return "right of"
        case .inFront: return "in front of"
        case .behind:  return "behind"
        case .beside:  return "beside"
        }
    }
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
    /// against the live stage, runs the deterministic operation and posts the
    /// factual result into the transcript as an activity row.
    static func perform(_ command: ModelStudioCommand, handle: ModelStudioHandle) async -> String {
        guard let viewModel = handle.viewModel else { return "The Studio screen is no longer open." }
        let result = await execute(command, viewModel: viewModel)
        viewModel.appendToolLine(result)
        return result
    }

    private static func execute(_ command: ModelStudioCommand,
                                viewModel: ModelStudioViewModel) async -> String {
        switch command {
        case .add(let shape, let width, let height, let depth, let color, let x, let y, let z):
            guard let parsed = PrimitiveShape.parse(shape) else {
                let names = PrimitiveShape.allCases.map(\.rawValue).joined(separator: ", ")
                return "Unknown shape “\(shape)” — available: \(names)."
            }
            return viewModel.addPrimitive(parsed,
                                          size: SIMD3(Float(width), Float(height), Float(depth)),
                                          colorName: color,
                                          position: SIMD3(Float(x), Float(y), Float(z)))
        case .move(let object, let dx, let dy, let dz):
            return viewModel.moveObject(object, by: SIMD3(Float(dx), Float(dy), Float(dz)))
        case .place(let object, let x, let y, let z):
            return viewModel.placeObject(object, at: SIMD3(Float(x), Float(y), Float(z)))
        case .placeRelative(let object, let relativeTo, let anchor):
            guard let parsed = RelativeAnchor.parse(anchor) else {
                return "Unknown placement “\(anchor)” — use on top, beside, left, right, in front or behind."
            }
            return viewModel.placeObject(object, relativeTo: relativeTo, anchor: parsed)
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
        case .combine(let objectA, let objectB, let operation):
            guard let parsed = MeshBoolean.Operation.parse(operation) else {
                return "Unknown operation “\(operation)” — use union, subtract or intersect."
            }
            return await viewModel.combineObjects(objectA, with: objectB, operation: parsed)
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
            let c = object.center
            return String(format: "%@ (%@, %.2f×%.2f×%.2f m, centre %.2f,%.2f,%.2f%@)",
                          object.name, object.colorName, d.x, d.y, d.z,
                          c.x, c.y, c.z,
                          object.texture != nil ? ", photo-textured" : "")
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
            return try await streamReply(session: session, prompt: prompt, viewModel: viewModel)
        } catch {
            // Most likely a filled context window — recreate and retry once.
            let fresh = makeSession(handle: ModelStudioHandle(viewModel: viewModel))
            viewModel.chatSessionStorage = fresh
            if let reply = try? await streamReply(session: fresh, prompt: prompt,
                                                  viewModel: viewModel) {
                return reply
            }
            return "Studio couldn't process that. Try a shorter, more specific instruction."
        }
    }

    /// Streams the reply, pushing each cumulative snapshot into the live
    /// transcript bubble; returns the final text.
    @available(iOS 26.0, *)
    private static func streamReply(session: LanguageModelSession, prompt: String,
                                    viewModel: ModelStudioViewModel) async throws -> String {
        var latest = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            latest = snapshot.content
            let partial = latest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty { viewModel.chatStreamUpdate(partial) }
        }
        let reply = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? "Done." : reply
    }

    @available(iOS 26.0, *)
    private static func makeSession(handle: ModelStudioHandle) -> LanguageModelSession {
        let tools: [any Tool] = [
            AddShapeTool(handle: handle),
            MoveObjectTool(handle: handle),
            PlaceObjectTool(handle: handle),
            PlaceRelativeTool(handle: handle),
            RotateObjectTool(handle: handle),
            ScaleObjectTool(handle: handle),
            ColorObjectTool(handle: handle),
            DuplicateObjectTool(handle: handle),
            DeleteObjectTool(handle: handle),
            SmoothObjectTool(handle: handle),
            ReduceObjectTool(handle: handle),
            CombineObjectsTool(handle: handle),
            MergeAllTool(handle: handle),
            DescribeStageTool(handle: handle),
        ]
        return LanguageModelSession(tools: tools, instructions: """
            You are Studio, the model-building assistant in a 3D scanning app. \
            The user composes 3D models on a small stage; the [stage now: …] line \
            lists the live objects with their size and centre position. You never \
            create or edit geometry yourself — you only call the provided tools \
            and report what they returned.

            Coordinates are metres; y is up; the ground is y = 0. addShape places \
            an object's base at the (x, y, z) you give: y = 0 sits it on the \
            ground, a larger y lifts it (use that to stack). x is left/right, z is \
            forward/back. Build EACH part directly at its final position in the \
            addShape call; to adjust afterwards use placeRelative (put one object \
            on top of / beside another), placeObject (absolute base x, y, z) or \
            moveObject (relative offset).

            Build requests from primitives, placing parts so they touch:
            • Snowman = three spheres on the same x,z: a 0.4 m sphere at y=0, a \
              0.3 m sphere at y≈0.35, a 0.2 m sphere at y≈0.6.
            • Table = a thin wide box top, then four cylinder legs under its corners.
            • Tree = a cylinder trunk at y=0, then a cone on top at y≈trunk height.
            To cut holes, overlap two solids and call combineObjects with subtract \
            (a mug = a cylinder minus a slightly thinner, taller cylinder).

            Refer to objects by the names in the stage line. Call one tool at a \
            time and adapt to each result. Keep going until the whole requested \
            model is built — don't stop after the first part. Never invent tools \
            or results. Finish with one or two short sentences on what you made.
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
        Add a primitive to the stage at a position: box, sphere, cylinder, cone, \
        torus or plane. Size is the bounding box in metres; the object's base is \
        placed at (positionX, positionY, positionZ) with positionY = 0 on the \
        ground; colour is a simple name like red, blue, brown or gray.
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
        @Guide(description: "X position of the base centre in metres (0 = stage centre)", .range(-10.0...10.0))
        var positionX: Double
        @Guide(description: "Height of the base above the ground in metres (0 = on the ground; raise to stack on another object)", .range(0.0...10.0))
        var positionY: Double
        @Guide(description: "Z position of the base centre in metres (0 = stage centre)", .range(-10.0...10.0))
        var positionZ: Double
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.add(shape: arguments.shape,
                                             width: arguments.widthMeters,
                                             height: arguments.heightMeters,
                                             depth: arguments.depthMeters,
                                             color: arguments.color,
                                             x: arguments.positionX,
                                             y: arguments.positionY,
                                             z: arguments.positionZ), handle: handle)
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
private struct PlaceObjectTool: Tool {
    let handle: ModelStudioHandle
    let name = "placeObject"
    let description = """
        Place an object at an absolute position: its base centre goes to (x, y, z), \
        with y = 0 on the ground. Easier than moveObject when you already know \
        where the object should end up.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to place")
        var object: String
        @Guide(description: "X position of the base centre in metres", .range(-10.0...10.0))
        var x: Double
        @Guide(description: "Height of the base above the ground in metres (0 = on the ground)", .range(0.0...10.0))
        var y: Double
        @Guide(description: "Z position of the base centre in metres", .range(-10.0...10.0))
        var z: Double
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.place(object: arguments.object,
                                               x: arguments.x, y: arguments.y, z: arguments.z),
                                        handle: handle)
    }
}

@available(iOS 26.0, *)
private struct PlaceRelativeTool: Tool {
    let handle: ModelStudioHandle
    let name = "placeRelative"
    let description = """
        Place one object relative to another: on top of, beside, left of, right \
        of, in front of, or behind it. Use this to assemble parts (e.g. place the \
        head on top of the body) without computing coordinates.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object to move")
        var object: String
        @Guide(description: "Name of the reference object it is placed relative to")
        var relativeTo: String
        @Guide(description: "Where: on top, beside, left, right, in front, or behind")
        var anchor: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.placeRelative(object: arguments.object,
                                                       relativeTo: arguments.relativeTo,
                                                       anchor: arguments.anchor), handle: handle)
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
private struct CombineObjectsTool: Tool {
    let handle: ModelStudioHandle
    let name = "combineObjects"
    let description = """
        Boolean-combine two overlapping solid objects into one: union joins \
        them, subtract carves the second out of the first (holes, cuts), \
        intersect keeps only the overlap. The result replaces the first \
        object; the second is consumed.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Name of the object that receives the result")
        var objectA: String
        @Guide(description: "Name of the second object (consumed)")
        var objectB: String
        @Guide(description: "Operation: union, subtract or intersect")
        var operation: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ModelStudioEngine.perform(.combine(objectA: arguments.objectA,
                                                 objectB: arguments.objectB,
                                                 operation: arguments.operation), handle: handle)
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
