//
//  TextureGutterFillTests.swift
//  Magic Camera
//
//  `TextureAtlas.fillGutters` is the most expensive single pass of a paged bake —
//  it walks every texel of an 8192² sheet and then floods the unpainted remainder
//  — so it is written for cost: raw pointers, one queue entry per texel, one BFS
//  wave live at a time. All three are claimed to be *invisible* in the output.
//  These tests hold that claim to a byte-for-byte comparison against the plain,
//  obvious BFS below, because the alternative is trusting a comment.
//

import XCTest
import simd
@testable import MagicCamera

final class TextureGutterFillTests: XCTestCase {

    // MARK: - Reference implementation

    /// The straightforward flood fill: bounds-checked subscripts, every neighbour
    /// re-enqueued after every fill, one queue for the whole flood. Deliberately
    /// naive — it is the definition the optimised version must reproduce.
    private func referenceFill(pixels: inout [UInt8], size: Int) {
        var queue: [Int32] = []
        for y in 0..<size {
            for x in 0..<size {
                let i = y * size + x
                guard pixels[i * 4 + 3] == 0 else { continue }
                if (x > 0 && pixels[(i - 1) * 4 + 3] != 0)
                    || (x + 1 < size && pixels[(i + 1) * 4 + 3] != 0)
                    || (y > 0 && pixels[(i - size) * 4 + 3] != 0)
                    || (y + 1 < size && pixels[(i + size) * 4 + 3] != 0) {
                    queue.append(Int32(i))
                }
            }
        }
        var head = 0
        while head < queue.count {
            let i = Int(queue[head]); head += 1
            guard pixels[i * 4 + 3] == 0 else { continue }
            let x = i % size, y = i / size
            var source = -1
            if x > 0, pixels[(i - 1) * 4 + 3] != 0 { source = i - 1 }
            else if x + 1 < size, pixels[(i + 1) * 4 + 3] != 0 { source = i + 1 }
            else if y > 0, pixels[(i - size) * 4 + 3] != 0 { source = i - size }
            else if y + 1 < size, pixels[(i + size) * 4 + 3] != 0 { source = i + size }
            guard source >= 0 else { continue }
            pixels[i * 4] = pixels[source * 4]
            pixels[i * 4 + 1] = pixels[source * 4 + 1]
            pixels[i * 4 + 2] = pixels[source * 4 + 2]
            pixels[i * 4 + 3] = 255
            if x > 0, pixels[(i - 1) * 4 + 3] == 0 { queue.append(Int32(i - 1)) }
            if x + 1 < size, pixels[(i + 1) * 4 + 3] == 0 { queue.append(Int32(i + 1)) }
            if y > 0, pixels[(i - size) * 4 + 3] == 0 { queue.append(Int32(i - size)) }
            if y + 1 < size, pixels[(i + size) * 4 + 3] == 0 { queue.append(Int32(i + size)) }
        }
    }

    // MARK: - Fixtures

    /// A sheet with `chartCount` painted axis-aligned blobs of distinct colours,
    /// deterministically placed — several charts with gutters between them, which
    /// is the shape a real atlas has.
    private func atlas(size: Int, chartCount: Int, seed: UInt64 = 0x5EED) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var state = seed
        func nextRandom(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        for chart in 0..<chartCount {
            let w = 2 + nextRandom(max(size / 4, 2))
            let h = 2 + nextRandom(max(size / 4, 2))
            let x0 = nextRandom(max(size - w, 1))
            let y0 = nextRandom(max(size - h, 1))
            // Colour varies per texel as well as per chart, so a fill that picked
            // the wrong source neighbour cannot pass by coincidence.
            for y in y0..<(y0 + h) {
                for x in x0..<(x0 + w) {
                    let i = (y * size + x) * 4
                    pixels[i] = UInt8((chart * 37 + x) % 256)
                    pixels[i + 1] = UInt8((chart * 61 + y) % 256)
                    pixels[i + 2] = UInt8((chart * 97 + x + y) % 256)
                    pixels[i + 3] = 255
                }
            }
        }
        return pixels
    }

    // MARK: - Tests

    func testMatchesTheReferenceFloodByteForByte() {
        for (size, charts) in [(64, 6), (97, 11), (128, 3)] {
            var optimised = atlas(size: size, chartCount: charts)
            var reference = optimised
            TextureAtlas.fillGutters(pixels: &optimised, size: size)
            referenceFill(pixels: &reference, size: size)
            XCTAssertEqual(optimised, reference,
                           "gutter fill diverged from the reference flood at \(size)²")
        }
    }

    /// Degenerate inputs the bake can genuinely hand it: a single painted texel
    /// (whose colour must reach the whole sheet) and a sheet with no paint at all
    /// (nothing to flood from, so nothing may change).
    func testDegenerateSheetsMatchTheReference() {
        let size = 33
        var single = [UInt8](repeating: 0, count: size * size * 4)
        let centre = (size / 2 * size + size / 2) * 4
        single[centre] = 200; single[centre + 1] = 100; single[centre + 2] = 50
        single[centre + 3] = 255
        var reference = single
        TextureAtlas.fillGutters(pixels: &single, size: size)
        referenceFill(pixels: &reference, size: size)
        XCTAssertEqual(single, reference)
        XCTAssertTrue(single.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 },
                      "one painted texel should still reach every texel")

        var empty = [UInt8](repeating: 0, count: size * size * 4)
        let untouched = empty
        TextureAtlas.fillGutters(pixels: &empty, size: size)
        XCTAssertEqual(empty, untouched, "no paint means nothing to flood from")
    }

    /// A fully painted sheet has no gutters, so the pass must leave it alone.
    func testFullyPaintedSheetIsUnchanged() {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4] = UInt8(i % 256); pixels[i * 4 + 3] = 255
        }
        let before = pixels
        TextureAtlas.fillGutters(pixels: &pixels, size: size)
        XCTAssertEqual(pixels, before)
    }

    /// A cancel must stop the flood, not corrupt it: whatever was filled keeps a
    /// real chart colour (the caller discards the atlas, but a half-filled sheet
    /// must never contain a half-written texel).
    func testCancelStopsTheFloodWithoutCorrupting() {
        let size = 64
        var pixels = atlas(size: size, chartCount: 4)
        let paintedBefore = (0..<(size * size)).filter { pixels[$0 * 4 + 3] != 0 }.count
        TextureAtlas.fillGutters(pixels: &pixels, size: size, isCancelled: { true })
        let paintedAfter = (0..<(size * size)).filter { pixels[$0 * 4 + 3] != 0 }.count
        XCTAssertEqual(paintedAfter, paintedBefore,
                       "a cancel before the first wave should fill nothing")
    }

    /// Rejects a buffer whose length does not match `size²` rather than reading
    /// past it — the guard is what keeps the raw-pointer body safe.
    func testMismatchedBufferIsRejected() {
        var pixels = [UInt8](repeating: 0, count: 10)
        let before = pixels
        TextureAtlas.fillGutters(pixels: &pixels, size: 64)
        XCTAssertEqual(pixels, before)
    }
}
