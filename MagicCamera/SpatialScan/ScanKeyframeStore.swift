//
//  ScanKeyframeStore.swift
//  Magic Camera
//
//  Persists a scan's texture keyframes (photo + pose + intrinsics + depth) as a
//  sidecar next to the .mcscan file. Keyframes are the photo-texture source;
//  without them a gallery-reopened scan silently fell back to point-colour
//  baking ("texture-bake — cloud colours — no keyframes") and the texture came
//  out visibly soft. A sidecar (not an .mcscan v3) keeps the cloud format and
//  its readers untouched, costs nothing when listing the gallery, and loads
//  only when the scan is actually opened.
//
//  Size note: up to 32 keyframes × (JPEG ~1-2 MB + 256×192 depth) ≈ tens of MB
//  per saved scan — the price of full-quality re-texturing after a reopen.
//

import Foundation
import simd

enum ScanKeyframeStore {
    private static let magic: UInt32 = 0x4D43_4B46 // "MCKF"
    private static let version: UInt32 = 1

    /// `Scan 2026-07-03.mcscan` → `Scan 2026-07-03.mckeys` (same directory).
    static func sidecarURL(for scanURL: URL) -> URL {
        scanURL.deletingPathExtension().appendingPathExtension("mckeys")
    }

    /// Writes the keyframes next to the scan; removes a stale sidecar when the
    /// scan has none (a re-save after edits must not resurrect old photos).
    static func save(_ keyframes: [ScanKeyframe], for scanURL: URL) {
        let url = sidecarURL(for: scanURL)
        guard !keyframes.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? encode(keyframes).write(to: url, options: .atomic)
    }

    /// Keyframes stored for the scan; empty when there is no (or a corrupt)
    /// sidecar — callers fall back to point-colour baking exactly as before.
    static func load(for scanURL: URL) -> [ScanKeyframe] {
        guard let data = try? Data(contentsOf: sidecarURL(for: scanURL)) else { return [] }
        return decode(data)
    }

    static func delete(for scanURL: URL) {
        try? FileManager.default.removeItem(at: sidecarURL(for: scanURL))
    }

    static func move(from oldScanURL: URL, to newScanURL: URL) {
        let old = sidecarURL(for: oldScanURL)
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        try? FileManager.default.moveItem(at: old, to: sidecarURL(for: newScanURL))
    }

    // MARK: - Binary layout

    static func encode(_ keyframes: [ScanKeyframe]) -> Data {
        var data = Data()
        append(magic, to: &data)
        append(version, to: &data)
        append(UInt32(keyframes.count), to: &data)
        for k in keyframes {
            append(UInt32(k.jpeg.count), to: &data)
            data.append(k.jpeg)
            for column in [k.cameraTransform.columns.0, k.cameraTransform.columns.1,
                           k.cameraTransform.columns.2, k.cameraTransform.columns.3] {
                append(column.x, to: &data); append(column.y, to: &data)
                append(column.z, to: &data); append(column.w, to: &data)
            }
            for column in [k.intrinsics.columns.0, k.intrinsics.columns.1,
                           k.intrinsics.columns.2] {
                append(column.x, to: &data); append(column.y, to: &data)
                append(column.z, to: &data)
            }
            append(UInt32(k.depthWidth), to: &data)
            append(UInt32(k.depthHeight), to: &data)
            k.depth.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Bounds-checked parse; a truncated/corrupt sidecar yields the keyframes
    /// read so far (or none) rather than crashing.
    static func decode(_ data: Data) -> [ScanKeyframe] {
        var offset = 0
        guard read(UInt32.self, from: data, at: &offset) == magic,
              read(UInt32.self, from: data, at: &offset) == version,
              let count = read(UInt32.self, from: data, at: &offset),
              count <= 256 else { return [] }
        var keyframes: [ScanKeyframe] = []
        keyframes.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let jpegLen = read(UInt32.self, from: data, at: &offset),
                  offset + Int(jpegLen) <= data.count else { break }
            let jpeg = data.subdata(in: offset..<(offset + Int(jpegLen)))
            offset += Int(jpegLen)

            var transformValues = [Float](repeating: 0, count: 16)
            var intrinsicValues = [Float](repeating: 0, count: 9)
            var ok = true
            for i in 0..<16 {
                guard let v = read(Float.self, from: data, at: &offset) else { ok = false; break }
                transformValues[i] = v
            }
            for i in 0..<9 where ok {
                guard let v = read(Float.self, from: data, at: &offset) else { ok = false; break }
                intrinsicValues[i] = v
            }
            guard ok,
                  let width = read(UInt32.self, from: data, at: &offset),
                  let height = read(UInt32.self, from: data, at: &offset),
                  width > 0, height > 0, width * height <= 4_000_000 else { break }
            let depthCount = Int(width * height)
            let depthBytes = depthCount * MemoryLayout<Float>.size
            guard offset + depthBytes <= data.count else { break }
            var depth = [Float](repeating: 0, count: depthCount)
            depth.withUnsafeMutableBytes {
                data.copyBytes(to: $0, from: offset..<(offset + depthBytes))
            }
            offset += depthBytes

            let transform = simd_float4x4(
                SIMD4<Float>(transformValues[0], transformValues[1], transformValues[2], transformValues[3]),
                SIMD4<Float>(transformValues[4], transformValues[5], transformValues[6], transformValues[7]),
                SIMD4<Float>(transformValues[8], transformValues[9], transformValues[10], transformValues[11]),
                SIMD4<Float>(transformValues[12], transformValues[13], transformValues[14], transformValues[15]))
            let intrinsics = simd_float3x3(
                SIMD3<Float>(intrinsicValues[0], intrinsicValues[1], intrinsicValues[2]),
                SIMD3<Float>(intrinsicValues[3], intrinsicValues[4], intrinsicValues[5]),
                SIMD3<Float>(intrinsicValues[6], intrinsicValues[7], intrinsicValues[8]))
            keyframes.append(ScanKeyframe(jpeg: jpeg, cameraTransform: transform,
                                          intrinsics: intrinsics,
                                          depthWidth: Int(width), depthHeight: Int(height),
                                          depth: depth))
        }
        return keyframes
    }

    // MARK: - Primitive IO

    private static func append<T>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private static func read<T>(_ type: T.Type, from data: Data, at offset: inout Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        let value = data.subdata(in: offset..<(offset + size)).withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: T.self)
        }
        offset += size
        return value
    }
}
