//
//  PPTStructuralParser.swift
//  Kalsmritikosh
//
//  W4-2 — legacy PowerPoint 97–2003 (.ppt, OLE2 / [MS-PPT]). The text lives in
//  the "PowerPoint Document" stream as a tree of records (8-byte header:
//  version/instance, type, length; version 0xF = container). This reader walks
//  that tree and keeps the text atoms in order:
//
//    TextHeaderAtom 0x0F9F  what the next text is (0 title, 1 body, 2 notes, 4 other,
//                           5 centred body, 6 centred title, 7 half body, 8 quarter body)
//    TextCharsAtom  0x0FA0  UTF-16LE text
//    TextBytesAtom  0x0FA8  8-bit text (Windows-1252)
//    SlidePersistAtom 0x03F3 inside SlideListWithText 0x0FF0 starts the next slide
//
//  Titles become headings, body text paragraphs, notes are kept and marked as
//  notes. Repeated text within a slide (the same atom stored twice by newer
//  PowerPoint versions) is kept once. Behind the "More file types" switch.
//

import Foundation
import CryptoKit

public nonisolated struct PPTStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.ppt] }
    public nonisolated var parserName: String { "PPTStructuralParser" }
    public nonisolated var parserVersion: String { "1" }
    public nonisolated init() {}

    struct TextRun: Equatable { let slide: Int; let kind: Int; let text: String }

    public func parse(data: Data, filename: String, type: SourceType, logicalSourceID: UUID, sourceVersionID: UUID) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = (filename as NSString).lastPathComponent
        var blocks: [EvidenceBlock] = []
        func doc(_ warnings: [ParserWarning], _ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID, filename: filename,
                           detectedType: .ppt, mimeType: "application/vnd.ms-powerpoint", contentHash: hash,
                           blocks: blocks, warnings: warnings, extractionStatus: status)
        }
        guard ProductModuleFlags.isEnabled(.extraParsers) else {
            return doc([ParserWarning(severity: .warning, code: "ppt.switched_off",
                message: "Kept with custody but not read: \"More file types\" is switched off in Settings → Modules.")], .empty)
        }
        let reader: OLE2Reader
        do { reader = try OLE2Reader(data: data) }
        catch {
            return doc([ParserWarning(severity: .error, code: "ppt.notOLE2",
                message: "Not an OLE2 .ppt (mis-extensioned or corrupt): \(error)")], .unsupported)
        }
        let clean: (String) -> String = { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}\u{0001}\u{0005}")) }
        guard let entry = reader.rootChildren().first(where: { clean($0.name) == "PowerPoint Document" }) else {
            return doc([ParserWarning(severity: .error, code: "ppt.noDocumentStream",
                message: "No \"PowerPoint Document\" stream.")], .corrupt)
        }
        let stream = [UInt8](reader.readEntryData(entry))
        let runs = Self.textRuns(stream)
        guard !runs.isEmpty else {
            return doc([ParserWarning(severity: .warning, code: "ppt.noText", message: "No text found in the presentation.")], .empty)
        }
        let slides = Set(runs.map(\.slide)).count
        func add(_ kind: EvidenceBlockKind, _ text: String, _ path: [String], _ attrs: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(documentID: documentID, sourceVersionID: sourceVersionID, ordinal: blocks.count,
                                        kind: kind, rawText: text, locator: SourceLocator(sectionPath: [name] + path),
                                        attributes: attrs))
        }
        add(.documentHeader, "PowerPoint presentation \"\(name)\": \(slides) slide(s)", [])
        for run in runs {
            let slide = run.slide == 0 ? "Document" : "Slide \(run.slide)"
            switch run.kind {
            case 0, 6: add(.sectionHeading, run.text, [slide], ["slide": AnyCodable(.int(Int64(run.slide)))])
            case 2: add(.paragraph, run.text, [slide, "Notes"], ["slide": AnyCodable(.int(Int64(run.slide))), "notes": AnyCodable(.bool(true))])
            default: add(.paragraph, run.text, [slide], ["slide": AnyCodable(.int(Int64(run.slide)))])
            }
        }
        return doc([], .complete)
    }

    /// Text atoms in reading order with their slide number (0 = before the first slide) and text type.
    static func textRuns(_ s: [UInt8]) -> [TextRun] {
        var out: [TextRun] = []
        var seen = Set<String>()
        var slide = 0
        var kind = 4
        func u16(_ o: Int) -> Int { o + 2 <= s.count ? Int(s[o]) | Int(s[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= s.count ? Int(s[o]) | Int(s[o + 1]) << 8 | Int(s[o + 2]) << 16 | Int(s[o + 3]) << 24 : 0 }
        func walk(_ start: Int, _ end: Int, inSlideList: Bool, depth: Int) {
            guard depth < 32 else { return }
            var o = start
            while o + 8 <= end {
                let verInst = u16(o), type = u16(o + 2), len = u32(o + 4)
                let body = o + 8
                guard len >= 0, body + len <= end else { return }
                if verInst & 0x000F == 0x000F {
                    walk(body, body + len, inSlideList: inSlideList || type == 0x0FF0, depth: depth + 1)
                } else {
                    switch type {
                    case 0x03F3 where inSlideList:
                        slide += 1; seen.removeAll()
                    case 0x0F9F:
                        kind = u32(body)
                    case 0x0FA0, 0x0FA8:
                        let raw = Array(s[body..<(body + len)])
                        let text: String = type == 0x0FA0
                            ? String(decoding: stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }, as: UTF16.self)
                            : (String(bytes: raw, encoding: .windowsCP1252) ?? String(decoding: raw, as: UTF8.self))
                        // PowerPoint uses \r for paragraph breaks and \u{0B} for line breaks.
                        let cleaned = text.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{0B}", with: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty, seen.insert("\(kind)|\(cleaned)").inserted {
                            out.append(TextRun(slide: slide, kind: kind, text: cleaned))
                        }
                    default: break
                    }
                }
                o = body + len
            }
        }
        walk(0, s.count, inSlideList: false, depth: 0)
        return out
    }
}
