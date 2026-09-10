//
//  CaptureProfile.swift
//  Magic Camera
//
//  What the scan setup asks, as two questions instead of one.
//
//  `CaptureQuality` was a flat five-way enum — Draft, Balanced, Max, Object,
//  Room — behind a single segmented picker, and its own comment admitted the
//  problem: "Object and Room have no four-tier equivalent, so they borrow
//  existing slots". Those five cases answer two INDEPENDENT questions:
//
//    · what is being scanned — which decides range, voxel size, distance
//      coarsening, carve strength, the silhouette-edge threshold and whether
//      ARKit's scene mesh and planes are captured;
//    · how well — which decides the point budget and the reconstruction tier.
//
//  Sharing one control welds them together, so "a room, quickly" and "an object,
//  roughly" could not be expressed at all: Object was pinned to ultra + fusion,
//  Room to detailed + fusion. Object then grew two further knobs (the 2 mm
//  Object+ density and a range slider) that were not in the enum and appeared
//  elsewhere, and a second, lossy `ScanSubject` projection collapsed Draft /
//  Balanced / Max back onto "Room" for the coaching text.
//
//  Here the two axes are separate and compose. **The five combinations that
//  existed before produce byte-identical configuration** — see
//  `CaptureProfileTests`, which asserts exactly that against the old enum, so the
//  split cannot silently retune a scan. The four new combinations (Object or Room
//  at a detail they never had) are compositions of tested pieces, but the
//  compositions themselves are new and want a device pass.
//

import Foundation

/// What the user is pointing the phone at. Picks the capture family.
enum CaptureSubject: String, CaseIterable, Identifiable, Sendable {
    /// A subject held or standing close: short range, fine uniform voxels, hard
    /// silhouette-edge rejection, ARKit scene mesh + planes for the isolate →
    /// Make 3-D Model workflow.
    case object = "Object"
    /// A whole room: long range, distance coarsening, gentler carving so sparsely
    /// seen far walls survive, plane anchors for wall flattening.
    case room = "Room"
    /// Anything in between — a corner, a vehicle, a garden, a workbench. This is
    /// the profile the old Draft / Balanced / Max tiers actually ran, which never
    /// had a name of its own and so read as "Room" everywhere.
    case area = "Area"

    var id: String { rawValue }

    /// The detail tier at which this subject's config is the ORIGINAL, untouched
    /// preset. Every other tier is a deliberate step away from it, which is what
    /// makes "the five old combinations are unchanged" a checkable claim rather
    /// than an intention.
    var nativeDetail: CaptureDetail {
        switch self {
        case .object: return .max        // the old .object case was ultra
        case .room:   return .balanced   // the old .room case was detailed/fusion
        case .area:   return .balanced   // …and each area tier maps 1:1 anyway
        }
    }

    var systemImage: String {
        switch self {
        case .object: return "cube"
        case .room:   return "square.split.bottomrightquarter"
        case .area:   return "mappin.and.ellipse"
        }
    }

    var detailLine: String {
        switch self {
        case .object: return "A subject up close — fine detail, short range."
        case .room:   return "A whole room — long range, wide coverage."
        case .area:   return "A place or a scene — general purpose."
        }
    }

    /// What to tell the user to actually DO once capture starts.
    var coachingLine: String {
        switch self {
        case .object:
            return "Circle the object slowly from every side — top and underneath too."
        case .room:
            return "Sweep the space slowly. Amber marks show what still needs a photo."
        case .area:
            return "Walk the scene slowly and keep the subject in frame from several sides."
        }
    }
}

/// How much the capture and the reconstruction are allowed to spend.
enum CaptureDetail: String, CaseIterable, Identifiable, Sendable {
    case quick = "Quick"
    case balanced = "Balanced"
    case max = "Max"

    var id: String { rawValue }

    /// Ordering, so a profile can express "one tier coarser than native".
    var rank: Int {
        switch self {
        case .quick: return 0
        case .balanced: return 1
        case .max: return 2
        }
    }

    /// The four-tier preset an Area scan runs — the old Draft / Balanced / Max.
    var areaQuality: ScanQuality {
        switch self {
        case .quick: return .fast
        case .balanced: return .balanced
        case .max: return .ultra
        }
    }

    var detailLine: String {
        switch self {
        case .quick:    return "Fastest and lightest — good for a quick look."
        case .balanced: return "A solid trade-off of detail and size."
        case .max:      return "Finest detail — needs a dense, patient scan."
        }
    }
}

/// How many points a capture may hold — a device-capability ceiling, not a dial.
///
/// This used to move with the detail tier, which made it the thing that decided
/// how much of a room a scan could cover: a long sweep saturated the cap partway
/// and then stopped growing, so the far half never made it in. Density is what the
/// user chooses; this is only the guard that keeps the phone alive, and the last
/// device round is why it needs to be adjustable at all — a big room bake sat at
/// 2.7-3.1 GB with 246 MB of headroom left.
enum CaptureBudget: String, CaseIterable, Identifiable, Sendable {
    /// For older or smaller-memory devices, and for anyone who has seen a scan
    /// die mid-sweep.
    case careful = "Careful"
    /// What every room scan shipped with before the budget was adjustable.
    case standard = "Standard"
    /// A Pro-class phone with room to spare.
    case high = "High"

    var id: String { rawValue }

    var maxPoints: Int {
        switch self {
        case .careful:  return 1_500_000
        case .standard: return 3_000_000
        case .high:     return 4_000_000
        }
    }

    var detailLine: String {
        switch self {
        case .careful:  return "1.5 M points — safest on older phones."
        case .standard: return "3 M points — the tested default."
        case .high:     return "4 M points — for a Pro with memory to spare."
        }
    }

    /// The user's choice, read without the main actor because the capture config
    /// is built off it.
    static var selected: CaptureBudget {
        CaptureSettings.pointBudget
    }
}

/// One capture setting: a subject and how well to capture it.
struct CaptureProfile: Equatable, Sendable {
    var subject: CaptureSubject
    var detail: CaptureDetail

    init(subject: CaptureSubject = .room, detail: CaptureDetail? = nil) {
        self.subject = subject
        self.detail = detail ?? subject.nativeDetail
    }

    /// Steps away from the subject's untouched preset. 0 means "exactly what this
    /// subject shipped as before the split".
    var detailOffset: Int { detail.rank - subject.nativeDetail.rank }

    // MARK: - Capture

    /// The config the recorder runs. `fine` and `rangeMeters` are Object's own
    /// extras and are ignored by the other subjects.
    func scanConfig(fine: Bool = false, rangeMeters: Float = 1.5) -> ScanConfig {
        switch subject {
        case .area:
            // Identical to the old `default:` branch: the four-tier preset plus a
            // mild silhouette trim and plane seeds. Detail maps 1:1, so there is
            // nothing to scale.
            var config = detail.areaQuality.config
            config.edgeThreshold = 0.09
            config.wantsPlanes = true
            config.maxPoints = CaptureBudget.selected.maxPoints
            return config
        case .object:
            var config = CaptureQuality.objectConfig(fine: fine, rangeMeters: rangeMeters)
            applyDetailStep(to: &config)
            return config
        case .room:
            var config = CaptureQuality.roomConfig()
            applyDetailStep(to: &config)
            return config
        }
    }

    /// Detail moves the DENSITY, and only the density.
    ///
    /// It used to move the point budget as well, which made the budget the thing
    /// that decided what a scan could cover: a big room at a fine tier hit the cap
    /// partway through and simply stopped growing, so the far half never made it
    /// in. Density and extent are different questions — a lower density should buy
    /// a LARGER area, not a truncated one — and tying them together meant neither
    /// could be chosen. The budget is now one device-capability setting
    /// (`CaptureBudget`), applied to every profile, and it is a safety ceiling
    /// rather than a dial: it exists so a phone does not die, not so a scan is
    /// smaller.
    ///
    /// A step is 1.5× on the voxel, roughly one halving of sampled surface density
    /// per tier — the same spacing the four-tier presets already use between
    /// neighbours. Range, coarsening, carve strength, the edge threshold and the
    /// scene-mesh/plane requests are *what you are scanning* and stay untouched;
    /// moving them here is exactly the welding this type exists to undo.
    private func applyDetailStep(to config: inout ScanConfig) {
        config.maxPoints = CaptureBudget.selected.maxPoints
        let steps = detailOffset
        guard steps != 0 else { return }
        let voxelScale = pow(1.5, Float(-steps))
        config.voxelSize = (config.voxelSize * voxelScale).rounded(toPlaces: 4)
    }

    // MARK: - Reconstruction

    /// Per-subject tables rather than one shared mapping, because the subjects do
    /// not agree: a room at its native tier reconstructs `.detailed` + fusion
    /// while an area at the same tier is `.standard` + smooth. Writing them out
    /// is what keeps the old combinations exact.
    var reconstructDetail: MeshDetail {
        switch (subject, detail) {
        case (.area, .quick):     return .draft
        case (.area, .balanced):  return .standard
        case (.area, .max):       return .ultra
        case (.object, .quick):   return .standard
        case (.object, .balanced): return .detailed
        case (.object, .max):     return .ultra       // = the old .object
        case (.room, .quick):     return .standard
        case (.room, .balanced):  return .detailed    // = the old .room
        case (.room, .max):       return .ultra
        }
    }

    var reconstructMethod: ReconstructionMethod {
        switch (subject, detail) {
        case (.area, .quick):     return .voxel
        case (.area, .balanced):  return .smooth
        case (.area, .max):       return .fusion
        case (.object, .quick):   return .smooth
        case (.object, .balanced), (.object, .max): return .fusion
        case (.room, .quick):     return .smooth
        case (.room, .balanced), (.room, .max):     return .fusion
        }
    }

    /// The four-tier preset the rest of the app (Settings, RoomPlan) still speaks.
    var scanQuality: ScanQuality {
        switch subject {
        case .area:   return detail.areaQuality
        case .object: return detail == .quick ? .balanced : .ultra
        case .room:   return detail == .max ? .ultra : .detailed
        }
    }

    var captureEstimate: CaptureEstimate {
        QualityEstimator.capture(maxPoints: scanConfig().maxPoints)
    }

    /// One line under the picker: what this pair will do.
    var detailLine: String { "\(subject.detailLine) \(detail.detailLine)" }

    /// Short label for breadcrumbs and saved-scan names.
    var label: String { "\(subject.rawValue) · \(detail.rawValue)" }

    // MARK: - Legacy bridge

    /// Maps the old five-way enum onto the pair. Used to migrate anything that
    /// still speaks `CaptureQuality` — the home-screen intents, App Intents — and
    /// by the tests that assert the five old combinations are unchanged.
    init(legacy: CaptureQuality) {
        switch legacy {
        case .draft:    self.init(subject: .area, detail: .quick)
        case .balanced: self.init(subject: .area, detail: .balanced)
        case .max:      self.init(subject: .area, detail: .max)
        case .object:   self.init(subject: .object, detail: .max)
        case .room:     self.init(subject: .room, detail: .balanced)
        }
    }

    /// True when this pair is one of the five the old enum could express — i.e.
    /// when its behaviour is the shipped, device-tested one.
    var isLegacyCombination: Bool {
        switch (subject, detail) {
        case (.area, _), (.object, .max), (.room, .balanced): return true
        default: return false
        }
    }
}

private extension Float {
    /// Keeps a scaled voxel a readable number (4.5 mm, not 4.4999998) so the
    /// diagnostics and the estimate labels do not print noise.
    func rounded(toPlaces places: Int) -> Float {
        let scale = pow(Float(10), Float(places))
        return (self * scale).rounded() / scale
    }
}
