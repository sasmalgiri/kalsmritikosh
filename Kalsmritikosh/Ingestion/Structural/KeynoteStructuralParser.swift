//
//  KeynoteStructuralParser.swift
//  Kalsmritikosh
//
//  W4-2 — Keynote (.key, iWork 2013+ single-file zip). The slides live in
//  `Index/*.iwa` files: each is a sequence of chunks (0x00, 3-byte little-endian
//  length, Snappy-compressed data) holding protobuf archives. This reader
//  decompresses Snappy natively (no dependency), walks the protobuf fields, and
//  keeps the length-delimited values that are readable text — which is where
//  Keynote stores slide text (TSWP storage).
//
//  Honest scope: PARTIAL. Text is recovered from the internal format without a
//  schema, so slide order and layout are approximated (one section per slide
//  file, in file-name order) and single-word labels are skipped as likely style
//  or font names. Package-format (folder) .key files and pre-2013 XML Keynote are
//  not handled. Behind the "More file types" switch.
//

import Foundation
import CryptoKit

nonisolated enum Snappy {
    enum Failure: Error { case malformed }

    /// Raw Snappy block decompression (varint length, then literal/copy elements).
    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var i = 0
        func varint() throws -> Int {
            var result = 0, shift = 0
            while i < input.count {
                let b = Int(input[i]); i += 1
                result |= (b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 35 { throw Failure.malformed }
            }
            throw Failure.malformed
        }
        let length = try varint()
        guard length <= 256 * 1_048_576 else { throw Failure.malformed }
        var out = [UInt8](); out.reserveCapacity(length)
        while i < input.count {
            let tag = Int(input[i]); i += 1
            switch tag & 3 {
            case 0:
                var len = tag >> 2
                if len >= 60 {
                    let extra = len - 59
                    guard i + extra <= input.count else { throw Failure.malformed }
                    len = 0
                    for k in 0..<extra { len |= Int(input[i + k]) << (8 * k) }
                    i += extra
                }
                len += 1
                guard i + len <= input.count else { throw Failure.malformed }
                out.append(contentsOf: input[i..<(i + len)]); i += len
            default:
                let len: Int, offset: Int
                switch tag & 3 {
                case 1:
                    guard i < input.count else { throw Failure.malformed }
                    len = ((tag >> 2) & 7) + 4; offset = ((tag >> 5) << 8) | Int(input[i]); i += 1
                case 2:
                    guard i + 2 <= input.count else { throw Failure.malformed }
                    len = (tag >> 2) + 1; offset = Int(input[i]) | Int(input[i + 1]) << 8; i += 2
                default:
                    guard i + 4 <= input.count else { throw Failure.malformed }
                    len = (tag >> 2) + 1
                    offset = Int(input[i]) | Int(input[i + 1]) << 8 | Int(input[i + 2]) << 16 | Int(input[i + 3]) << 24; i += 4
                }
                guard offset > 0, offset <= out.count else { throw Failure.malformed }
                let start = out.count - offset
                for k in 0..<len { out.append(out[start + k]) }   // overlapping copies are allowed
            }
        }
        guard out.count == length else { throw Failure.malformed }
        return out
    }
}

nonisolated enum IWAReader {
    /// Concatenated decompressed payload of an .iwa file.
    static func payload(_ data: [UInt8]) throws -> [UInt8] {
        var i = 0
        var out: [UInt8] = []
        while i + 4 <= data.count {
            guard data[i] == 0 else { throw Snappy.Failure.malformed }
            let len = Int(data[i + 1]) | Int(data[i + 2]) << 8 | Int(data[i + 3]) << 16
            i += 4
            guard i + len <= data.count else { throw Snappy.Failure.malformed }
            out += try Snappy.decompress(Array(data[i..<(i + len)]))
            i += len
        }
        return out
    }

    /// Readable text values found anywhere in a protobuf byte stream (recursing into sub-messages).
    static func texts(_ bytes: ArraySlice<UInt8>, depth: Int = 0, into out: inout [String]) {
        guard depth < 12 else { return }
        var i = bytes.startIndex
        func varint() -> Int? {
            var r = 0, s = 0
            while i < bytes.endIndex {
                let b = Int(bytes[i]); i += 1
                r |= (b & 0x7F) << s
                if b & 0x80 == 0 { return r }
                s += 7; if s > 63 { return nil }
            }
            return nil
        }
        while i < bytes.endIndex {
            guard let key = varint(), key > 0 else { return }
            switch key & 7 {
            case 0: guard varint() != nil else { return }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let len = varint(), len >= 0, i + len <= bytes.endIndex else { return }
                let sub = bytes[i..<(i + len)]
                i += len
                if let s = String(bytes: sub, encoding: .utf8), isText(s) { out.append(s) }
                else if len > 1 { texts(sub, depth: depth + 1, into: &out) }
            default: return
            }
            if i > bytes.endIndex { return }
        }
    }

    /// Text a person wrote: printable, contains a letter, and at least two words or a sentence mark.
    static func isText(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\u{2028}" }),
              t.contains(where: \.isLetter) else { return false }
        let words = t.split(whereSeparator: { $0.isWhitespace }).count
        return words >= 2 || t.contains(where: { ".?!:".contains($0) })
    }
}

public struct KeynoteStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.keynote] }
    public nonisolated var parserName: String { "keynote-iwa" }
    public nonisolated var parserVersion: String { "1" }
    public nonisolated init() {}

    public func parse(data: Data, filename: String, type: SourceType, logicalSourceID: UUID, sourceVersionID: UUID) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []
        let name = (filename as NSString).lastPathComponent
        func add(_ kind: EvidenceBlockKind, _ text: String, _ path: [String]) {
            blocks.append(EvidenceBlock(documentID: documentID, sourceVersionID: sourceVersionID, ordinal: blocks.count,
                                        kind: kind, rawText: text, locator: SourceLocator(sectionPath: [name] + path)))
        }
        func doc(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID, filename: filename,
                           detectedType: .keynote, mimeType: "application/vnd.apple.keynote", contentHash: hash,
                           blocks: blocks, warnings: warnings, extractionStatus: status)
        }
        guard ProductModuleFlags.isEnabled(.extraParsers) else {
            warnings.append(ParserWarning(severity: .warning, code: "keynote.switched_off",
                message: "Kept with custody but not read: \"More file types\" is switched off in Settings → Modules."))
            return doc(.empty)
        }
        let zip = ZIPReader(data: data)
        guard let entries = try? zip.entries() else {
            warnings.append(ParserWarning(severity: .error, code: "keynote.not_zip",
                message: "Not a single-file Keynote document (no zip directory). Package-format and pre-2013 Keynote files are not read."))
            return doc(.corrupt)
        }
        let iwas = entries.filter { $0.name.hasPrefix("Index/") && $0.name.hasSuffix(".iwa") }.sorted { $0.name < $1.name }
        guard !iwas.isEmpty else {
            warnings.append(ParserWarning(severity: .error, code: "keynote.no_index", message: "No Index/*.iwa files inside."))
            return doc(.corrupt)
        }
        add(.documentHeader, "Keynote presentation \"\(name)\": \(iwas.filter { $0.name.contains("Slide") }.count) slide file(s)", [])
        var failed = 0
        var seen = Set<String>()
        for entry in iwas {
            guard let raw = try? zip.extract(entry: entry), let payload = try? IWAReader.payload([UInt8](raw)) else { failed += 1; continue }
            var texts: [String] = []
            IWAReader.texts(payload[...], into: &texts)
            let fresh = texts.filter { seen.insert($0).inserted }
            guard !fresh.isEmpty else { continue }
            let section = (entry.name as NSString).lastPathComponent.replacingOccurrences(of: ".iwa", with: "")
            add(.sectionHeading, section, [section])
            for t in fresh { add(.paragraph, t, [section]) }
        }
        warnings.append(ParserWarning(severity: .info, code: "keynote.heuristic",
            message: "Text recovered from Keynote's internal format without a schema: slide order and layout are approximated, single-word labels are skipped."))
        if failed > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "keynote.unreadable_parts", message: "\(failed) internal file(s) could not be decompressed."))
        }
        return doc(blocks.count > 1 ? .partial : .empty)
    }
}
