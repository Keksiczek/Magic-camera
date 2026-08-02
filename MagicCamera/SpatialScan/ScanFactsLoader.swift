//
//  ScanFactsLoader.swift
//  Magic Camera
//
//  Builds a `ScanFacts` for a scan that is only on disk — the library's naming
//  and description features need one, and loading the file to get it is not an
//  option: a room's point cloud runs to hundreds of MB, and the caller is a
//  rename dialog.
//
//  Both on-disk formats put their positions in a fixed-stride block at a fixed
//  offset, so a bounding box can be estimated from a few thousand seeks instead:
//
//    .mcscan — 12-byte header, then 28 bytes per point, position first.
//    .mcmesh — 20-byte header, then the vertex block, 12 bytes per vertex.
//
//  A strided sample gives a bounding box that is correct to within the spacing
//  between samples, which for naming ("Room 4.2 × 2.6 m") is far below the noise
//  in the number anyway.
//

import Foundation
import simd

enum ScanFactsLoader {
    /// How many positions to sample. 2048 seeks is a few milliseconds and pins a
    /// bounding box to well under a centimetre on any real scan.
    private static let sampleCount = 2048

    /// Facts for a library entry, read without loading the scan.
    static func facts(for item: LibraryItem) -> ScanFacts {
        let box: (min: SIMD3<Float>, max: SIMD3<Float>)?
        switch item.kind {
        case .points: box = sampledBox(at: item.url, headerBytes: 12, stride: 28, count: item.count)
        // The mesh header counts VERTICES, `item.count` counts triangles; the two
        // differ by roughly a factor of two on a welded mesh and much more on the
        // duplicated-corner soup a textured save produces. Read the real count out
        // of the header rather than guessing from the triangles.
        case .mesh: box = sampledBox(at: item.url, headerBytes: 20, stride: 12,
                                     count: vertexCount(at: item.url))
        }
        let dimensions = box.map { $0.max - $0.min } ?? .zero
        return ScanFacts(kind: item.kind == .mesh ? .mesh : .pointCloud,
                         count: item.count, dimensions: dimensions)
    }

    /// Vertex count from an `.mcmesh` header (field 3 of five `UInt32`s).
    private static func vertexCount(at url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12 else { return 0 }
        return Int(head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
    }

    private static func sampledBox(at url: URL, headerBytes: Int, stride: Int,
                                   count: Int) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Never read past the end: a truncated or half-synced iCloud file would
        // otherwise take the whole feature down with it.
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let usable = min(count, max(0, (size - headerBytes) / stride))
        guard usable > 0 else { return nil }

        let step = max(usable / sampleCount, 1)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        var index = 0
        while index < usable {
            try? handle.seek(toOffset: UInt64(headerBytes + index * stride))
            guard let raw = try? handle.read(upToCount: 12), raw.count == 12 else { break }
            // Component-wise: `SIMD3<Float>` is 16 bytes and 16-byte aligned, so it
            // must never be loaded straight out of a 12-byte-strided buffer.
            let p = raw.withUnsafeBytes { bytes in
                SIMD3<Float>(bytes.loadUnaligned(fromByteOffset: 0, as: Float.self),
                             bytes.loadUnaligned(fromByteOffset: 4, as: Float.self),
                             bytes.loadUnaligned(fromByteOffset: 8, as: Float.self))
            }
            if p.x.isFinite, p.y.isFinite, p.z.isFinite {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
                found = true
            }
            index += step
        }
        return found ? (lo, hi) : nil
    }
}
