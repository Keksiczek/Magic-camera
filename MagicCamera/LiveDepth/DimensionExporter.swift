//
//  DimensionExporter.swift
//  Magic Camera
//
//  Serialises captured object measurements (Dimension Scanner) to a CSV file
//  for sharing/analysis.
//

import Foundation

enum DimensionExporter {
    enum ExportError: Error { case empty }

    static func csv(_ objects: [MeasuredObject]) -> Data {
        var text = "label,distance_m,width_m,height_m,depth_m,timestamp\n"
        let formatter = ISO8601DateFormatter()
        for object in objects {
            let s = object.size
            text += "\(object.label),\(object.distance),\(s.x),\(s.y),\(s.z),"
                  + "\(formatter.string(from: object.date))\n"
        }
        return Data(text.utf8)
    }

    static func write(_ objects: [MeasuredObject],
                      filename: String = "MagicCamera-dimensions") throws -> URL {
        guard !objects.isEmpty else { throw ExportError.empty }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filename).csv")
        try? FileManager.default.removeItem(at: url)
        try csv(objects).write(to: url)
        return url
    }
}
