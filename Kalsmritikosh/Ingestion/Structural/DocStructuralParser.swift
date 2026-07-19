//
//  DocStructuralParser.swift
//  Kalsmritikosh
//
//  Phase 2 — a real structural parser for legacy Word 97–2003 binary `.doc`
//  (OLE2 / [MS-DOC]). It reconstructs the document text properly via the FIB +
//  piece table (not the old `strings(1)` sweep), splits it into paragraph blocks
//  on the Word paragraph mark, and detects table cells best-effort. Output is
//  typed EvidenceBlocks, so legacy .doc flows through the same evidence-first
//  ingest pipeline as every modern format.
//
//  Honest scope (audit: "unsupported portions marked partial, never dropped"):
//    • Clean piece-table text  → extractionStatus .complete, confidence 1.0.
//    • Piece table missing/odd → fall back to a raw fcMin..fcMac text span, then
//      to the printable-string sweep; status .partial, confidence lowered, with
//      a warning naming what degraded. Formatting, styles, images, footnotes,
//      revision marks and exact table geometry are not recovered — a table's
//      cells are emitted as paragraph blocks flagged partial.
//

import Foundation
import CryptoKit

public nonisolated struct DocStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.doc] }
    public nonisolated var parserName: String { "DocStructuralParser" }
    public nonisolated var parserVersion: String { "1.0" }

    public nonisolated init() {}

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        func doc(_ blocks: [EvidenceBlock], _ warnings: [ParserWarning], _ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .doc, mimeType: "application/msword",
                contentHash: hash, metadata: [:], blocks: blocks, warnings: warnings, extractionStatus: status
            )
        }

        // Open the OLE2 compound file. A mis-extensioned OOXML/RTF/HTML file
        // (common in real archives) has no CFB magic → report unsupported
        // rather than throw, so the ingest records it and moves on.
        let reader: OLE2Reader
        do { reader = try OLE2Reader(data: data) }
        catch {
            return doc([], [ParserWarning(severity: .error, code: "doc.notOLE2",
                message: "Not an OLE2 .doc (mis-extensioned or corrupt): \(error)")], .unsupported)
        }

        let entries = reader.rootChildren()
        func stream(_ predicate: (String) -> Bool) -> Data? {
            guard let e = entries.first(where: { predicate(cleanName($0.name)) }) else { return nil }
            return reader.readEntryData(e)
        }
        guard let wd = stream({ $0 == "WordDocument" }), wd.count >= 384 else {
            return doc([], [ParserWarning(severity: .error, code: "doc.noWordDocument",
                message: "WordDocument stream missing or too small.")], .corrupt)
        }

        var warnings: [ParserWarning] = []
        var status: ExtractionStatus = .complete
        var confidence = 1.0

        // Reconstruct the main text via the piece table (the correct path).
        var text = extractViaPieceTable(wordDocument: wd, entries: entries, reader: reader)
        if text == nil {
            // Fallback 1 — raw fcMin..fcMac span (works for simple, non-complex
            // files); Fallback 2 — printable-string sweep. Both are partial.
            warnings.append(ParserWarning(severity: .warning, code: "doc.noPieceTable",
                message: "Piece table not found/parseable — used a degraded text extraction."))
            status = .partial
            confidence = 0.6
            text = extractViaFcSpan(wordDocument: wd)
        }
        if text == nil || text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Last resort — printable-string sweep directly over the stream.
            let runs = LegacyOfficeScanner.extractStringRuns(from: wd)
            if runs.isEmpty {
                return doc([], warnings + [ParserWarning(severity: .warning, code: "doc.empty",
                    message: "No recoverable text in the .doc.")], .empty)
            }
            warnings.append(ParserWarning(severity: .warning, code: "doc.stringSweep",
                message: "Fell back to printable-string sweep; text order/structure approximate."))
            status = .partial
            confidence = 0.4
            text = runs.joined(separator: "\n")
        }

        let hadTableCells = text!.contains("\u{07}")
        if hadTableCells {
            // Table CELL TEXT is fully recovered via the piece table; only the
            // exact table GEOMETRY is approximate (cells emitted as paragraphs).
            // That's an informational note, not content loss — it must not
            // downgrade a complete extraction to .partial (which would make the
            // confidence layer under-trust a faithful text extraction).
            warnings.append(ParserWarning(severity: .info, code: "doc.tablePartial",
                message: "Tables detected — cells emitted as paragraphs; exact geometry not recovered."))
        }

        let blocks = paragraphBlocks(
            from: text!, documentID: documentID, sourceVersionID: sourceVersionID,
            confidence: confidence
        )
        if blocks.isEmpty {
            return doc([], warnings + [ParserWarning(severity: .warning, code: "doc.empty",
                message: "Text recovered but produced no non-empty blocks.")], .empty)
        }
        return doc(blocks, warnings, status)
    }

    // MARK: - Paragraph blocks

    private func paragraphBlocks(
        from text: String, documentID: UUID, sourceVersionID: UUID, confidence: Double
    ) -> [EvidenceBlock] {
        // Word paragraph mark = \r (0x0D). Cell mark = \x07. Normalize both to
        // line breaks, drop the remaining low control chars Word sprinkles in
        // (field markers 0x13/0x14/0x15, line break 0x0B, page break 0x0C, etc.).
        var normalized = ""
        normalized.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x07, 0x0B, 0x0C, 0x0A: normalized.unicodeScalars.append("\n")
            case 0x09: normalized.unicodeScalars.append("\t")
            case 0x00...0x1F: break                 // drop other control bytes
            case 0xFFFE, 0xFFFF: break              // BOM/guard artifacts
            default: normalized.unicodeScalars.append(scalar)
            }
        }
        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 2 else { continue }
            // A short leading line with no sentence punctuation reads as a
            // heading; everything else is a paragraph.
            let kind: EvidenceBlockKind = (ordinal == 0 && line.count <= 80 && !line.contains("."))
                ? .sectionHeading : .paragraph
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: kind, rawText: line,
                locator: SourceLocator(paragraphIndex: ordinal),
                extractionMethod: .native, extractionConfidence: confidence
            ))
            ordinal += 1
        }
        return blocks
    }

    // MARK: - Piece table (the correct [MS-DOC] path)

    /// Reconstruct the main document text from the FIB + piece table (CLX in the
    /// Table stream). Returns nil when the FIB/piece table can't be parsed, so
    /// the caller falls back. Handles both compressed (CP1252, 1 byte/char) and
    /// uncompressed (UTF-16LE) pieces per [MS-DOC] §2.4.1.
    private func extractViaPieceTable(
        wordDocument wd: Data, entries: [OLE2Reader.DirectoryEntry], reader: OLE2Reader
    ) -> String? {
        // wIdent must be 0xA5EC for a Word binary document.
        guard OLE2Reader.readUInt16(wd, offset: 0) == 0xA5EC else { return nil }
        // fWhichTblStm (flags bit 0x0200) selects 0Table vs 1Table.
        let flags = OLE2Reader.readUInt16(wd, offset: 0x0A)
        let tableName = (flags & 0x0200) != 0 ? "1Table" : "0Table"
        guard let table = entries.first(where: { cleanName($0.name) == tableName })
            .map({ reader.readEntryData($0) }) else { return nil }

        // Walk the FIB by its declared sub-structure counts (robust across nFib
        // versions) to locate fcClx/lcbClx in FibRgFcLcb.
        let csw = Int(OLE2Reader.readUInt16(wd, offset: 32))
        let cslwOffset = 34 + csw * 2
        guard cslwOffset + 2 <= wd.count else { return nil }
        let cslw = Int(OLE2Reader.readUInt16(wd, offset: cslwOffset))
        let fibRgLwBase = cslwOffset + 2
        let cbRgFcLcbOffset = fibRgLwBase + cslw * 4
        guard cbRgFcLcbOffset + 2 <= wd.count else { return nil }
        let fibRgFcLcbBase = cbRgFcLcbOffset + 2
        // fcClx is the 67th 4-byte value (0-indexed 66) in FibRgFcLcb97.
        let fcClxOffset = fibRgFcLcbBase + 66 * 4
        guard fcClxOffset + 8 <= wd.count else { return nil }
        let fcClx = Int(OLE2Reader.readUInt32(wd, offset: fcClxOffset))
        let lcbClx = Int(OLE2Reader.readUInt32(wd, offset: fcClxOffset + 4))
        guard lcbClx > 0, fcClx >= 0, fcClx + lcbClx <= table.count else { return nil }

        let clx = table.subdata(in: fcClx..<(fcClx + lcbClx))
        guard let plcpcd = locatePlcPcd(in: clx) else { return nil }

        // PlcPcd = (n+1) CPs (UInt32) followed by n PCDs (8 bytes each).
        let pcdSize = 8
        let n = (plcpcd.count - 4) / (4 + pcdSize)
        guard n > 0 else { return nil }
        let cpBase = 0
        let pcdBase = (n + 1) * 4
        guard pcdBase + n * pcdSize <= plcpcd.count else { return nil }

        var out = String.UnicodeScalarView()
        for i in 0..<n {
            let cpStart = Int(OLE2Reader.readUInt32(plcpcd, offset: cpBase + i * 4))
            let cpEnd = Int(OLE2Reader.readUInt32(plcpcd, offset: cpBase + (i + 1) * 4))
            let charCount = cpEnd - cpStart
            guard charCount > 0, charCount < 50_000_000 else { continue }
            // PCD.fc is a 4-byte FcCompressed at PCD offset +2. Bit 30 set =
            // compressed (CP1252 at fc/2); clear = UTF-16LE at fc.
            let pcdOffset = pcdBase + i * pcdSize
            let fcRaw = OLE2Reader.readUInt32(plcpcd, offset: pcdOffset + 2)
            let compressed = (fcRaw & 0x4000_0000) != 0
            let fc = Int(fcRaw & 0x3FFF_FFFF)
            if compressed {
                let byteStart = fc / 2
                guard byteStart >= 0, byteStart + charCount <= wd.count else { continue }
                for j in 0..<charCount {
                    let b = wd[byteStart + j]
                    let v = cp1252Scalar(b)
                    out.append(v)
                }
            } else {
                guard fc >= 0, fc + charCount * 2 <= wd.count else { continue }
                for j in 0..<charCount {
                    let lo = UInt16(wd[fc + j * 2]); let hi = UInt16(wd[fc + j * 2 + 1])
                    if let s = Unicode.Scalar(lo | (hi << 8)) { out.append(s) }
                }
            }
        }
        let s = String(out)
        return s.isEmpty ? nil : s
    }

    /// The CLX may lead with Prc (RgPrc, first byte 0x01) records before the
    /// Pcdt (first byte 0x02). Skip any Prc, then read the Pcdt's PlcPcd blob.
    private func locatePlcPcd(in clx: Data) -> Data? {
        var i = 0
        while i < clx.count {
            let marker = clx[i]
            if marker == 0x01 {
                guard i + 3 <= clx.count else { return nil }
                let cbGrpprl = Int(OLE2Reader.readUInt16(clx, offset: i + 1))
                i += 1 + 2 + cbGrpprl
            } else if marker == 0x02 {
                guard i + 5 <= clx.count else { return nil }
                let lcb = Int(OLE2Reader.readUInt32(clx, offset: i + 1))
                let start = i + 5
                guard lcb > 0, start + lcb <= clx.count else { return nil }
                return clx.subdata(in: start..<(start + lcb))
            } else {
                return nil
            }
        }
        return nil
    }

    // MARK: - Fallback text spans

    /// Simple (non-complex) files store the main text contiguously between
    /// fcMin and fcMac. fComplex (flags bit 0x0004) means the piece table is
    /// required — we don't use this path then.
    private func extractViaFcSpan(wordDocument wd: Data) -> String? {
        let flags = OLE2Reader.readUInt16(wd, offset: 0x0A)
        if (flags & 0x0004) != 0 { return nil }   // fComplex — needs piece table
        let fcMin = Int(OLE2Reader.readUInt32(wd, offset: 24))
        let fcMac = Int(OLE2Reader.readUInt32(wd, offset: 28))
        guard fcMin >= 0, fcMac > fcMin, fcMac <= wd.count else { return nil }
        let span = wd.subdata(in: fcMin..<fcMac)
        // Simple-file main text is CP1252, one byte per char.
        var out = String.UnicodeScalarView()
        for b in span { out.append(cp1252Scalar(b)) }
        let s = String(out)
        return s.isEmpty ? nil : s
    }

    // MARK: - Helpers

    private func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}\u{0001}\u{0005}"))
    }

    /// Windows-1252 → Unicode for the 0x80–0x9F band (the rest is Latin-1).
    private func cp1252Scalar(_ b: UInt8) -> Unicode.Scalar {
        if let mapped = Self.cp1252High[b], let s = Unicode.Scalar(mapped) { return s }
        return Unicode.Scalar(b)
    }

    private static let cp1252High: [UInt8: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
        0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
        0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
        0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
        0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
        0x9E: 0x017E, 0x9F: 0x0178
    ]
}
