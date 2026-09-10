//
//  LocalizationTests.swift
//  MagicCameraTests
//
//  Holds the translations to the key set.
//
//  Localisation rots silently: a missing key shows the English literal, which
//  looks like a design choice rather than a bug, and nothing in the build says
//  a word. These read both `.strings` files off disk — the source of truth,
//  not the bundle, so the test fails on the edit rather than on the run.
//

import XCTest

final class LocalizationTests: XCTestCase {

    private struct Table {
        let language: String
        let entries: [String: String]
        var keys: Set<String> { Set(entries.keys) }
    }

    /// Repo root, walked up from this file — the resources live in the app
    /// target, so the test bundle cannot see them.
    private var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/MagicCameraTests/this.swift
            .deletingLastPathComponent()          // …/Tests/MagicCameraTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("MagicCamera/Resources")
    }

    /// Minimal `.strings` parser: `"key" = "value";`, `/* comments */` skipped.
    /// Deliberately strict — a line that looks like an entry but does not parse
    /// is a failure, because that is exactly how a stray quote silently drops a
    /// translation.
    private func table(_ language: String) throws -> Table {
        let url = resourcesDirectory
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [String: String] = [:]
        var inComment = false
        for (number, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if inComment {
                guard let end = line.range(of: "*/") else { continue }
                inComment = false
                line = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line = (line[..<start.lowerBound] + line[end.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    inComment = true
                    line = String(line[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !line.isEmpty else { continue }
            guard line.hasPrefix("\""), line.hasSuffix("\";"),
                  let split = line.range(of: "\" = \"") else {
                XCTFail("\(language).lproj:\(number + 1) is not a valid entry: \(line)")
                continue
            }
            let key = String(line[line.index(after: line.startIndex)..<split.lowerBound])
            let value = String(line[split.upperBound..<line.index(line.endIndex, offsetBy: -2)])
            XCTAssertNil(entries[key], "\(language): duplicate key \"\(key)\"")
            entries[key] = value
        }
        return Table(language: language, entries: entries)
    }

    func testTheTranslationsCoverExactlyTheKeySet() throws {
        let english = try table("en"), czech = try table("cs")
        XCTAssertFalse(english.entries.isEmpty, "the English table is the key set")

        let untranslated = english.keys.subtracting(czech.keys).sorted()
        XCTAssertTrue(untranslated.isEmpty,
                      "missing Czech translations — these would show in English:\n"
                      + untranslated.joined(separator: "\n"))

        let orphaned = czech.keys.subtracting(english.keys).sorted()
        XCTAssertTrue(orphaned.isEmpty,
                      "Czech keys with no English original — a typo here is a string "
                      + "that is never looked up:\n" + orphaned.joined(separator: "\n"))
    }

    func testNoTranslationIsEmpty() throws {
        for language in ["en", "cs"] {
            for (key, value) in try table(language).entries {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language): \"\(key)\" translates to nothing")
            }
        }
    }

    func testFormatSpecifiersSurviveTranslation() throws {
        // A translation that drops or adds a `%@`/`%d` crashes `String(format:)`
        // at runtime, in the other language, on someone else's phone.
        let english = try table("en"), czech = try table("cs")
        for (key, source) in english.entries {
            guard let translated = czech.entries[key] else { continue }
            XCTAssertEqual(specifiers(in: source), specifiers(in: translated),
                           "format specifiers differ for \"\(key)\"")
        }
    }

    func testTheEnglishTableMapsEachKeyToItself() throws {
        // English is the development language, so its file exists to WRITE THE
        // KEY SET DOWN. A value that differs from its key means the literal in
        // the source and the entry here have drifted apart, and the drift is
        // invisible: English keeps working, Czech quietly loses the key.
        for (key, value) in try table("en").entries {
            XCTAssertEqual(key, value, "en.lproj should map \"\(key)\" to itself")
        }
    }

    func testCzechActuallyTranslates() throws {
        // Guards against a half-finished pass that copies English across.
        //
        // Two reasons a value may legitimately match: it is a proper noun or an
        // abbreviation ("Magic Camera", "CSV", "iCloud"), or Czech borrowed the
        // word wholesale and the correct translation IS the English spelling
        // ("Panel", "Detail", "Export", "Studio"). Anything else that matches is
        // an untranslated string, not a coincidence.
        let unchanged: Set<String> = ["Magic Camera", "OK", "CSV", "iCloud", "Studio",
                                      "Export", "Model Studio", "Panel", "Detail"]
        let english = try table("en"), czech = try table("cs")
        var copied: [String] = []
        for (key, source) in english.entries where !unchanged.contains(key) {
            if czech.entries[key] == source { copied.append(key) }
        }
        XCTAssertTrue(copied.isEmpty,
                      "left in English:\n" + copied.sorted().joined(separator: "\n"))
    }

    private func specifiers(in string: String) -> [String] {
        var found: [String] = []
        var rest = Substring(string)
        while let percent = rest.firstIndex(of: "%") {
            var index = rest.index(after: percent)
            var token = "%"
            while index < rest.endIndex {
                let character = rest[index]
                token.append(character)
                index = rest.index(after: index)
                if character.isLetter || character == "%" { break }
            }
            if token != "%%" { found.append(token) }
            rest = rest[index...]
        }
        return found
    }
}
