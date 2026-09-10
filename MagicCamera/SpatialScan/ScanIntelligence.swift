//
//  ScanIntelligence.swift
//  Magic Camera
//
//  On-device intelligence over scans, built on two rules:
//    · The LLM never touches geometry. It reads a compact, token-cheap fact
//      sheet (ScanFacts) and produces text (report) or a tool sequence (plan);
//      the deterministic pipeline does the actual math.
//    · Everything degrades gracefully: on iOS < 26 or with Apple Intelligence
//      off, the same entry points return a deterministic report / heuristic
//      plan, so the features work everywhere and the model only adds polish.
//

import Foundation
import simd
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Facts

/// Compact description of the current scan — small enough to be a fraction of
/// the on-device model's 4 k-token window, rich enough to reason about.
struct ScanFacts: Sendable {
    enum Kind: String, Sendable {
        case pointCloud = "point cloud"
        case mesh = "mesh"
    }

    var kind: Kind
    /// Points (cloud) or triangles (mesh).
    var count: Int
    /// Axis-aligned bounding box in metres (width × height × depth).
    var dimensions: SIMD3<Float>
    /// Fraction of cloud points below the matte-filter confidence threshold.
    var lowConfidenceFraction: Float = 0
    /// Vertex share per ARKit surface class ("wall" → 0.38 …), classified meshes.
    var classificationShares: [(name: String, share: Float)] = []
    var isTextured = false
    var hasKeyframes = false

    static func facts(cloud: PointCloud, hasKeyframes: Bool) -> ScanFacts {
        var lowConfidence = 0
        for confidence in cloud.confidences where confidence < 0.65 { lowConfidence += 1 }
        let box = cloud.boundingBox()
        let dims = box.map { $0.max - $0.min } ?? .zero
        return ScanFacts(kind: .pointCloud, count: cloud.count, dimensions: dims,
                         lowConfidenceFraction: cloud.count > 0
                             ? Float(lowConfidence) / Float(cloud.count) : 0,
                         hasKeyframes: hasKeyframes)
    }

    static func facts(mesh: MeshData, isTextured: Bool, hasKeyframes: Bool) -> ScanFacts {
        let box = mesh.boundingBox()
        let dims = box.map { $0.max - $0.min } ?? .zero
        var shares: [(String, Float)] = []
        if mesh.hasClassification {
            let names = ["", "wall", "floor", "ceiling", "table", "seat", "window", "door"]
            var counts = [Int](repeating: 0, count: names.count)
            for raw in mesh.classifications where raw < names.count { counts[Int(raw)] += 1 }
            let total = max(mesh.classifications.count, 1)
            for i in 1..<names.count where counts[i] > 0 {
                shares.append((names[i], Float(counts[i]) / Float(total)))
            }
            shares.sort { $0.1 > $1.1 }
        }
        return ScanFacts(kind: .mesh, count: mesh.triangleCount, dimensions: dims,
                         classificationShares: shares,
                         isTextured: isTextured, hasKeyframes: hasKeyframes)
    }

    /// Key: value lines handed to the model as the prompt.
    var promptBlock: String {
        var lines = [
            "kind: \(kind.rawValue)",
            "size: \(MeasurementFormat.count(count)) \(kind == .mesh ? "triangles" : "points")",
            String(format: "bounding box: %.1f × %.1f × %.1f m (W×H×D)",
                   dimensions.x, dimensions.y, dimensions.z),
        ]
        if kind == .pointCloud {
            lines.append(String(format: "low-confidence points: %.0f%%",
                                lowConfidenceFraction * 100))
        }
        if !classificationShares.isEmpty {
            let surfaces = classificationShares
                .map { String(format: "%@ %.0f%%", $0.name, $0.share * 100) }
                .joined(separator: ", ")
            lines.append("surfaces: \(surfaces)")
        }
        lines.append("textured: \(isTextured ? "yes" : "no")")
        lines.append("photo keyframes available: \(hasKeyframes ? "yes" : "no")")
        return lines.joined(separator: "\n")
    }

    /// Human-readable report without any model — the always-works fallback.
    var deterministicReport: String {
        var lines: [String] = []
        lines.append(kind == .mesh ? "Mesh scan · \(MeasurementFormat.count(count)) triangles"
                                   : "Point cloud · \(MeasurementFormat.count(count)) points")
        lines.append(String(format: "Bounding box %.1f × %.1f × %.1f m (W×H×D)",
                            dimensions.x, dimensions.y, dimensions.z))
        if kind == .pointCloud, lowConfidenceFraction > 0.02 {
            lines.append(String(format: "%.0f%% of points are low confidence — consider the Matte filter.",
                                lowConfidenceFraction * 100))
        }
        for (name, share) in classificationShares.prefix(5) {
            lines.append(String(format: "· %@ %.0f%%", name.capitalized, share * 100))
        }
        if isTextured {
            lines.append("Photo texture baked.")
        } else if hasKeyframes {
            lines.append("Photo keyframes captured — texture can be baked.")
        }
        return lines.joined(separator: "\n")
    }

    /// What the scan most likely is, from geometry alone — the always-works name
    /// and the ceiling on what the model is allowed to claim.
    ///
    /// Deliberately conservative. The on-device model gets no image, only these
    /// numbers, so neither it nor this can know a room is a *kitchen*; what the
    /// numbers do support is object-versus-room and how big it is, which is
    /// exactly what makes a list of twenty timestamped "Scan 2026-07-30 12:04"
    /// entries navigable again.
    var deterministicName: String {
        let dims = dimensions
        let footprint = SIMD3<Float>(max(dims.x, dims.z), 0, min(dims.x, dims.z))
        let longest = max(dims.x, max(dims.y, dims.z))
        guard longest > 0 else { return kind == .mesh ? "Mesh scan" : "Point cloud" }

        // Classified geometry is the one case where the scan says what it is.
        let named = Set(classificationShares.filter { $0.share >= 0.05 }.map(\.name))
        let isRoom = named.contains("floor") && (named.contains("wall") || named.contains("ceiling"))
        if isRoom || longest >= 3 {
            return "Room \(MeasurementFormat.distance(footprint.x))"
                + " × \(MeasurementFormat.distance(footprint.z))"
        }
        if let dominant = classificationShares.first, dominant.share >= 0.4,
           dominant.name != "wall", dominant.name != "floor" {
            return "\(dominant.name.capitalized) \(MeasurementFormat.distance(longest))"
        }
        let noun = longest >= 1 ? "Large object" : "Object"
        return "\(noun) \(MeasurementFormat.distance(longest))"
    }
}

// MARK: - Auto-fix steps

/// The deterministic tools the planner may sequence. Raw values double as the
/// vocabulary the model must pick from.
enum AutoFixStep: String, CaseIterable, Sendable {
    case matteFilter, cleanUp, isolate, reconstruct
    case closeBase, optimize, fillHoles, bakeTexture

    var title: String {
        switch self {
        case .matteFilter: return "Matte filter"
        case .cleanUp:     return "Clean up"
        case .isolate:     return "Isolate"
        case .reconstruct: return "Reconstruct"
        case .closeBase:   return "Close base"
        case .optimize:    return "Optimize"
        case .fillHoles:   return "Fill holes"
        case .bakeTexture: return "Texture"
        }
    }
}

// MARK: - Generable plan (iOS 26+)

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "A clean-up plan for a 3D scan")
private struct AutoFixPlanDraft {
    @Guide(description: "Ordered tool names, chosen only from: matteFilter, cleanUp, isolate, reconstruct, closeBase, optimize, fillHoles, bakeTexture. At most 6.")
    var steps: [String]
    @Guide(description: "One short sentence explaining the plan")
    var reasoning: String
}

@available(iOS 26.0, *)
@Generable(description: "A short library name for a 3D scan")
private struct ScanNameDraft {
    @Guide(description: "Two to four words naming what was scanned, in title case. No dates, no file extension, no punctuation, no quotes.")
    var name: String
}
#endif

// MARK: - Intelligence

enum ScanIntelligence {
    /// True when the on-device model can actually answer right now.
    static var isModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Natural-language description of the scan. Uses the on-device model when
    /// available; otherwise returns the deterministic fact summary.
    static func describeScene(facts: ScanFacts) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: """
                You describe 3D LiDAR scans inside a scanning app. Write in English.
                Output: a short title line, then 2–3 plain sentences about what was
                scanned and its real-world size, then up to 5 bullet lines with the
                notable facts. Use only the provided numbers — never invent objects
                or rooms that are not implied by the data. No markdown headings.
                """)
            if let response = try? await session.respond(to: facts.promptBlock) {
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        #endif
        return facts.deterministicReport
    }

    /// A short library name for the scan.
    ///
    /// The library is a wall of `Scan 2026-07-30 12:04`, which is the one thing a
    /// user cannot search. The model sees the same fact sheet everything else here
    /// gets — no image, so it is naming from dimensions and ARKit surface classes,
    /// and the instructions bind it to that. Anything it returns is put through
    /// `sanitizedName`, and an empty or unusable answer falls back to
    /// `deterministicName`, which is what runs on iOS < 26 or with Apple
    /// Intelligence off.
    static func suggestName(facts: ScanFacts) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: """
                You name 3D LiDAR scans for a scanning app's library. Write in English.
                You are given measurements only — never a picture — so name what the
                numbers support and nothing more: whether it is a room or an object,
                and any surface classes listed. A scan over 3 m across is a room; a
                scan under 1 m is a small object. Never invent a purpose ("Kitchen",
                "Office") unless a surface class implies it. Two to four words, title
                case, no dates or numbers.
                """)
            if let response = try? await session.respond(to: facts.promptBlock,
                                                         generating: ScanNameDraft.self),
               let name = sanitizedName(response.content.name) {
                return name
            }
        }
        #endif
        return facts.deterministicName
    }

    /// Trims a model-authored name to something safe to become a filename.
    /// Returns nil when nothing usable is left, so the caller falls back.
    ///
    /// Not merely cosmetic: the name becomes a path component. `FileStore.sanitize`
    /// is the last line, but a name arriving with a slash or a newline in it should
    /// never reach it in the first place.
    static func sanitizedName(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .newlines).joined(separator: " ")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t.\"'“”"))
        let words = collapsed.split(separator: " ").prefix(5)
        let name = words.joined(separator: " ")
        guard !name.isEmpty, name.count <= 48 else {
            return name.isEmpty ? nil : String(name.prefix(48))
        }
        return name
    }

    /// Ordered clean-up plan for the scan. The model picks from the fixed tool
    /// vocabulary (guided generation keeps it structured); invalid names are
    /// dropped and an empty result falls back to the heuristic plan.
    static func planAutoFix(facts: ScanFacts) async -> [AutoFixStep] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: """
                You plan clean-up for 3D LiDAR scans. Available tools:
                - matteFilter: drop low-confidence reflective noise (worth it when low-confidence ≥ 5%)
                - cleanUp: remove stray outlier points
                - isolate: cut floor/background and keep the main object (for objects, not rooms)
                - reconstruct: turn the point cloud into a surface mesh
                - closeBase: cap the open bottom left after isolate
                - optimize: smooth the mesh
                - fillHoles: cap small mesh holes
                - bakeTexture: project photo texture (only when keyframes available and not textured)
                Rules: cloud tools (matteFilter, cleanUp, isolate) only make sense
                before reconstruct; mesh tools (closeBase, optimize, fillHoles,
                bakeTexture) only once a mesh exists — a "mesh" scan already has one.
                A room-sized scan (> 3 m) should not be isolated. Pick the minimal
                helpful sequence, at most 6 steps.
                """)
            if let response = try? await session.respond(to: facts.promptBlock,
                                                          generating: AutoFixPlanDraft.self) {
                var seen = Set<AutoFixStep>()
                var plan: [AutoFixStep] = []
                for name in response.content.steps {
                    guard let step = AutoFixStep(rawValue: name),
                          seen.insert(step).inserted else { continue }
                    plan.append(step)
                }
                if !plan.isEmpty { return Array(plan.prefix(6)) }
            }
        }
        #endif
        return heuristicPlan(facts: facts)
    }

    /// The non-AI plan — same logic a careful user would click through.
    static func heuristicPlan(facts: ScanFacts) -> [AutoFixStep] {
        var plan: [AutoFixStep] = []
        switch facts.kind {
        case .pointCloud:
            if facts.lowConfidenceFraction >= 0.05 { plan.append(.matteFilter) }
            plan.append(.cleanUp)
            let maxDimension = max(facts.dimensions.x, max(facts.dimensions.y, facts.dimensions.z))
            let isObject = maxDimension > 0 && maxDimension < 3
            if isObject { plan.append(.isolate) }
            plan.append(.reconstruct)
            if isObject { plan.append(.closeBase) }
            if facts.hasKeyframes { plan.append(.bakeTexture) }
        case .mesh:
            plan.append(.fillHoles)
            let maxDimension = max(facts.dimensions.x, max(facts.dimensions.y, facts.dimensions.z))
            if maxDimension > 0 && maxDimension < 3 { plan.append(.closeBase) }
            if facts.hasKeyframes && !facts.isTextured { plan.append(.bakeTexture) }
        }
        return plan
    }
}
