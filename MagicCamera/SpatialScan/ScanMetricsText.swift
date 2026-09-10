//
//  ScanMetricsText.swift
//  Magic Camera
//
//  Turning `ScanMetrics` into the three strings the app shows: the scan's name,
//  the one-line subtitle under it in the gallery, and the block of measurements
//  the user can copy out.
//
//  Kept apart from the measuring so the numbers stay testable without a locale
//  and the wording can change without touching the geometry.
//

import Foundation

extension ScanMetrics {

    /// The row of measurements, in the order they matter to a reader.
    /// `(label, value)` — the view lays them out, this decides what is in them.
    var rows: [(label: String, value: String)] {
        var rows: [(String, String)] = [("Type", kind.label)]
        switch kind {
        case .room, .area:
            rows.append(("Floor area", Self.area(footprintArea)))
            if let roomHeight {
                rows.append(("Ceiling height", Self.length(roomHeight)))
            }
            rows.append(("Volume", Self.volume(volume)))
            rows.append(("Extent", Self.extent(dimensions[0], dimensions[1])))
        case .surface:
            rows.append(("Area", Self.area(footprintArea)))
            rows.append(("Extent", Self.extent(dimensions[0], dimensions[1])))
        case .object:
            rows.append(("Size", Self.size(dimensions)))
            rows.append(("Volume", Self.volume(volume)))
        }
        rows.append(("Points", MeasurementFormat.count(pointCount)))
        rows.append(("Density", "\(MeasurementFormat.count(Int(pointDensity)))/m²"))
        return rows
    }

    /// Multi-line block for the share sheet / clipboard.
    var summaryText: String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    /// One line for a gallery cell, without the type (the icon already says it).
    var subtitle: String {
        switch kind {
        case .room, .area:
            let height = roomHeight.map { " · \(Self.length($0)) high" } ?? ""
            return Self.area(footprintArea) + height
        case .surface:
            return Self.area(footprintArea)
        case .object:
            return Self.size(dimensions)
        }
    }

    /// The scan's name. Measured rather than boxed: a room is named by the floor
    /// it covers, which is the number someone actually recognises the room by,
    /// and an object by its size. The timestamp stays — two scans of the same
    /// kitchen must not collide on disk.
    func name(at date: Date = Date()) -> String {
        let time = date.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        ).replacingOccurrences(of: ":", with: ".")
        switch kind {
        case .object:
            return "Object \(Self.size(dimensions)) \(time)"
        case .surface:
            return "Surface \(Self.area(footprintArea)) \(time)"
        case .room, .area:
            return "\(kind.label) \(Self.area(footprintArea)) \(time)"
        }
    }

    // MARK: - Units
    //
    // Plain interpolation, not `Measurement` formatting: these strings become
    // FILE NAMES, and a locale that writes "24,3 m²" or inserts a non-breaking
    // space turns a name into a different name on the next device.

    static func area(_ squareMetres: Float) -> String {
        squareMetres < 1
            ? String(format: "%.0f cm²", squareMetres * 10_000)
            : String(format: "%.1f m²", squareMetres)
    }

    static func length(_ metres: Float) -> String {
        metres < 1
            ? String(format: "%.0f cm", metres * 100)
            : String(format: "%.2f m", metres)
    }

    static func volume(_ cubicMetres: Float) -> String {
        cubicMetres < 0.1
            ? String(format: "%.0f cm³", cubicMetres * 1_000_000)
            : String(format: "%.2f m³", cubicMetres)
    }

    static func extent(_ a: Float, _ b: Float) -> String {
        String(format: "%.1f × %.1f m", a, b)
    }

    static func size(_ dimensions: SIMD3<Float>) -> String {
        dimensions[0] < 1
            ? String(format: "%.0f × %.0f × %.0f cm",
                     dimensions[0] * 100, dimensions[1] * 100, dimensions[2] * 100)
            : String(format: "%.2f × %.2f × %.2f m",
                     dimensions[0], dimensions[1], dimensions[2])
    }
}
