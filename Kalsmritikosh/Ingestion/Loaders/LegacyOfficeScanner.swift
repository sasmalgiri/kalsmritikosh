//
//  LegacyOfficeScanner.swift
//  Kalsmritikosh
//
//  Lean text extractor for the pre-OOXML Office binaries: .doc, .xls,
//  and .ppt. Full BIFF / FIB / PowerPoint record parsing is a multi-
//  month rabbit hole; this scanner walks the OLE2 compound-file
//  directory, picks the streams that historically carry the human
//  text, and runs a UTF-16LE + Latin-1 printable-string sweep over
//  each. Imperfect — formatting and layout are gone — but it lifts
//  these formats out of the binary-stub bucket so the chunker / NER /
//  FTS layers see real content.
//
//  Approach is inspired by the classic `strings(1)` utility plus the
//  observation that Word/Excel/PowerPoint 97-2003 store user text
//  either as UTF-16LE runs (modern unicode-mode files) or as
//  Windows-1252 / Latin-1 in older files. We try both, keep runs of
//  printable characters at or above a small length threshold, and
//  join them with newlines so the chunker has natural splits.
//

import Foundation

public nonisolated enum LegacyOfficeScanner {

    /// Read the OLE2 streams that carry text for a given legacy
    /// format, run printable-string extraction across each, and join
    /// the results. Returns nil only when the file doesn't even open
    /// as a CFB — every other failure mode yields whatever text was
    /// recovered, which is the right tradeoff for archival ingest.
    public static func extractText(at url: URL, kind: Kind) throws -> Extraction {
        let raw: Data
        do { raw = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let reader: OLE2Reader
        do { reader = try OLE2Reader(data: raw) }
        catch {
            // Some "legacy" Office files are actually mis-extensioned
            // OOXML zips. Surface that as a parse failure so the
            // caller can decide whether to try the OOXML path
            // separately, but don't crash the ingest.
            throw IngestorError.parseFailure(url, reason: "ole2: \(error)")
        }

        let entries = reader.rootChildren()
        // Pick the streams that the format spec lists as carriers of
        // user text. We accept either the canonical names below OR
        // anything that looks like a sizeable named text-bearing
        // stream — older Word for Mac shipped variants with leading
        // 0x01 / 0x05 prefix bytes which we ignore.
        let targets = entries.filter { entry in
            let name = entry.name.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0001}\u{0005}\u{0000}"))
            switch kind {
            case .doc:
                return name == "WordDocument"
                    || name == "0Table" || name == "1Table"
                    || name.lowercased().contains("text")
            case .xls:
                return name == "Workbook" || name == "Book"
                    || name == "SharedStrings"
            case .ppt:
                return name == "PowerPoint Document"
                    || name == "Pictures" && false  // Pictures stream is binary image data; skip.
                    || name.lowercased().contains("powerpoint")
                    || name.lowercased().contains("currentuser")
            }
        }
        // Fallback: if none of the canonical streams are present (some
        // mis-built files put text in a non-standard stream), scan
        // every stream over 256 bytes. This is the "strings"
        // approach and is the right last resort for archival ingest.
        let scanned: [OLE2Reader.DirectoryEntry]
        if targets.isEmpty {
            scanned = entries.filter { $0.size >= 256 && $0.type != 5 }
        } else {
            scanned = targets
        }

        var pieces: [String] = []
        var bytesScanned = 0
        for entry in scanned {
            let data = reader.readEntryData(entry)
            if data.isEmpty { continue }
            bytesScanned += data.count
            let runs = extractStringRuns(from: data)
            if !runs.isEmpty {
                pieces.append(contentsOf: runs)
            }
        }
        // Cheap deduplication — Excel SST and PowerPoint outline
        // streams routinely repeat the same string many times.
        // Preserving order matters (sentences scattered across the
        // file shouldn't be alphabetized), so we use an inline seen-
        // set rather than `Set` of pieces.
        var seen = Set<String>()
        var uniquePieces: [String] = []
        uniquePieces.reserveCapacity(pieces.count)
        for p in pieces {
            if seen.insert(p).inserted {
                uniquePieces.append(p)
            }
        }
        let joined = uniquePieces.joined(separator: "\n")
        return Extraction(
            text: joined,
            streamsScanned: scanned.count,
            bytesScanned: bytesScanned,
            runCount: uniquePieces.count
        )
    }

    public enum Kind: Sendable {
        case doc, xls, ppt
    }

    public struct Extraction: Sendable {
        public let text: String
        public let streamsScanned: Int
        public let bytesScanned: Int
        public let runCount: Int
    }

    // MARK: - Printable-string extraction

    /// Pull out every run of printable characters from `data`,
    /// trying UTF-16LE first (the format used by Office 97+ for
    /// Unicode text) and Latin-1 second. Runs shorter than
    /// `minRunLength` are dropped because they're almost always
    /// binary noise misread as ASCII.
    public static func extractStringRuns(
        from data: Data,
        minRunLength: Int = 4
    ) -> [String] {
        var runs: [String] = []
        runs.append(contentsOf: utf16LERuns(in: data, minRunLength: minRunLength))
        runs.append(contentsOf: latin1Runs(in: data, minRunLength: minRunLength))
        return runs
    }

    /// UTF-16LE scan: read 16-bit code units, accumulate runs of
    /// characters that pass the printable-or-whitespace test, emit
    /// when a non-printable code unit (or run end) breaks the run.
    /// Office Unicode text is always little-endian on disk.
    static func utf16LERuns(in data: Data, minRunLength: Int) -> [String] {
        var runs: [String] = []
        var current = ""
        var i = 0
        let n = data.count - 1
        while i < n {
            let lo = UInt16(data[i])
            let hi = UInt16(data[i + 1])
            let unit = lo | (hi << 8)
            // Surrogate pairs are rare in Office binaries; treat
            // them as run boundaries rather than implementing full
            // UTF-16 surrogate handling for marginal gain.
            if unit < 0xD800,
               let scalar = Unicode.Scalar(unit),
               isPrintableOrSoftBreak(scalar) {
                current.append(Character(scalar))
            } else {
                if current.count >= minRunLength {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { runs.append(trimmed) }
                }
                current = ""
            }
            i += 2
        }
        if current.count >= minRunLength {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { runs.append(trimmed) }
        }
        return runs
    }

    /// Single-byte scan: each byte stands in for a Latin-1 code
    /// point. Windows-1252 specifics (the 0x80-0x9F printable range)
    /// are mapped via `windows1252Map` since Office files routinely
    /// emit smart quotes / em-dashes / euro signs in that band.
    static func latin1Runs(in data: Data, minRunLength: Int) -> [String] {
        var runs: [String] = []
        var current = ""
        for byte in data {
            let scalarValue: UInt32
            if let mapped = windows1252Map[byte] {
                scalarValue = UInt32(mapped)
            } else {
                scalarValue = UInt32(byte)
            }
            if let scalar = Unicode.Scalar(scalarValue),
               isPrintableOrSoftBreak(scalar) {
                current.append(Character(scalar))
            } else {
                if current.count >= minRunLength {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { runs.append(trimmed) }
                }
                current = ""
            }
        }
        if current.count >= minRunLength {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { runs.append(trimmed) }
        }
        return runs
    }

    /// What counts as a printable character for the purposes of run
    /// detection. We keep tab / newline / nbsp inside runs so
    /// table cells and bullets don't get split into single-word
    /// noise; everything else outside the ASCII printable range
    /// gets cleared via the lookup tables above.
    private static func isPrintableOrSoftBreak(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v == 9 || v == 10 || v == 13 { return true } // \t \n \r
        if v == 0x00A0 { return true }                 // nbsp
        if v < 0x20 { return false }                   // other control
        if v >= 0x7F && v < 0xA0 { return false }      // DEL + C1 controls
        // The Office formats commonly emit private-use / fill bytes
        // in the 0xE000+ range and beyond; clamp the upper bound to
        // BMP printable territory so we don't slurp binary CJK/emoji
        // noise from random byte sequences.
        if v > 0x2FFF { return false }
        return true
    }

    /// Windows-1252 high-byte mappings that differ from Latin-1.
    /// These are the characters Office files most often use in the
    /// 0x80-0x9F range and would otherwise be discarded as C1
    /// controls. Source: Microsoft Win-1252 codepage.
    private static let windows1252Map: [UInt8: UInt32] = [
        0x80: 0x20AC, // €
        0x82: 0x201A, // ‚
        0x83: 0x0192, // ƒ
        0x84: 0x201E, // „
        0x85: 0x2026, // …
        0x86: 0x2020, // †
        0x87: 0x2021, // ‡
        0x88: 0x02C6, // ˆ
        0x89: 0x2030, // ‰
        0x8A: 0x0160, // Š
        0x8B: 0x2039, // ‹
        0x8C: 0x0152, // Œ
        0x8E: 0x017D, // Ž
        0x91: 0x2018, // ‘
        0x92: 0x2019, // ’
        0x93: 0x201C, // “
        0x94: 0x201D, // ”
        0x95: 0x2022, // •
        0x96: 0x2013, // –
        0x97: 0x2014, // —
        0x98: 0x02DC, // ˜
        0x99: 0x2122, // ™
        0x9A: 0x0161, // š
        0x9B: 0x203A, // ›
        0x9C: 0x0153, // œ
        0x9E: 0x017E, // ž
        0x9F: 0x0178  // Ÿ
    ]
}
