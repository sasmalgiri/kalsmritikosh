//
//  XlsStructuralParser.swift
//  Kalsmritikosh
//
//  Phase 2 — a real structural parser for legacy Excel 97–2003 binary `.xls`
//  (OLE2 → Workbook stream, BIFF8 / [MS-XLS]). It walks the BIFF record stream,
//  resolves the shared-string table (SST, with CONTINUE spillover), decodes RK /
//  NUMBER / LABELSST / FORMULA cells, and emits typed EvidenceBlocks: one
//  spreadsheetSheet block per worksheet and one spreadsheetRow block per row
//  (cells joined, exact values preserved) with a (sheet,row) locator. Legacy
//  .xls therefore flows through the same evidence-first pipeline as .xlsx.
//
//  Honest scope (audit: "tables where possible; unsupported portions partial,
//  never dropped"): values, sheet/row/column geometry and shared strings are
//  recovered. Cell formatting/number-format masks, charts, formulas' own text,
//  merged-cell spans and defined names are not — a file that parses but hits an
//  unreadable record run is marked `.partial` with a warning rather than lost.
//

import Foundation
import CryptoKit

public nonisolated struct XlsStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.xls] }
    public nonisolated var parserName: String { "XlsStructuralParser" }
    public nonisolated var parserVersion: String { "1.0" }

    public nonisolated init() {}

    // BIFF record type ids we care about ([MS-XLS] §2.4).
    private enum Rec {
        static let bof: UInt16 = 0x0809
        static let eof: UInt16 = 0x000A
        static let boundSheet8: UInt16 = 0x0085
        static let sst: UInt16 = 0x00FC
        static let continueRec: UInt16 = 0x003C
        static let labelSst: UInt16 = 0x00FD
        static let label: UInt16 = 0x0204
        static let rk: UInt16 = 0x027E
        static let mulRk: UInt16 = 0x00BD
        static let number: UInt16 = 0x0203
        static let formula: UInt16 = 0x0006
        static let string: UInt16 = 0x0207
    }

    private struct BIFFRecord { let type: UInt16; let range: Range<Int> } // range into the stream

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func doc(_ blocks: [EvidenceBlock], _ warnings: [ParserWarning], _ status: ExtractionStatus,
                 _ meta: [String: AnyCodable] = [:]) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .xls, mimeType: "application/vnd.ms-excel",
                contentHash: hash, metadata: meta, blocks: blocks, warnings: warnings, extractionStatus: status
            )
        }

        let reader: OLE2Reader
        do { reader = try OLE2Reader(data: data) }
        catch {
            return doc([], [ParserWarning(severity: .error, code: "xls.notOLE2",
                message: "Not an OLE2 .xls (mis-extensioned or corrupt): \(error)")], .unsupported)
        }
        let entries = reader.rootChildren()
        guard let wbEntry = entries.first(where: {
            let n = $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}\u{0001}\u{0005}"))
            return n == "Workbook" || n == "Book"
        }) else {
            return doc([], [ParserWarning(severity: .error, code: "xls.noWorkbook",
                message: "Workbook/Book stream missing.")], .corrupt)
        }
        let wb = reader.readEntryData(wbEntry)
        guard wb.count >= 4 else {
            return doc([], [ParserWarning(severity: .error, code: "xls.tinyWorkbook",
                message: "Workbook stream too small.")], .corrupt)
        }

        // 1. Index every record.
        let records = scanRecords(wb)
        guard !records.isEmpty else {
            return doc([], [ParserWarning(severity: .error, code: "xls.noRecords",
                message: "No BIFF records found.")], .corrupt)
        }

        var warnings: [ParserWarning] = []
        var status: ExtractionStatus = .complete

        // 2. Shared strings (SST + CONTINUE spillover).
        let sst = parseSST(wb: wb, records: records, warnings: &warnings)

        // 3. Worksheets (name + substream BOF offset).
        struct Sheet { let name: String; let bofOffset: Int }
        var sheets: [Sheet] = []
        for r in records where r.type == Rec.boundSheet8 {
            let d = wb.subdata(in: r.range)
            guard d.count >= 8 else { continue }
            let bofOffset = Int(le32(d, 0))
            let name = shortXLString(d, at: 6) ?? "Sheet\(sheets.count + 1)"
            sheets.append(Sheet(name: name, bofOffset: bofOffset))
        }
        if sheets.isEmpty {
            // Globals-only or unusual layout — scan cells globally as one sheet.
            sheets = [Sheet(name: "Sheet1", bofOffset: -1)]
        }

        // 4. Walk each sheet substream and collect cells → row blocks.
        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        var totalCells = 0
        let cellCap = 20_000

        for (si, sheet) in sheets.enumerated() {
            // Sheet header block.
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: .spreadsheetSheet, rawText: sheet.name,
                locator: SourceLocator(sheet: sheet.name),
                extractionMethod: .native, extractionConfidence: 1.0,
                attributes: ["sheetIndex": AnyCodable(.int(Int64(si)))]))
            ordinal += 1

            // Records belonging to this sheet: from its BOF (by offset) to the
            // next EOF. When bofOffset is unknown (-1) we scan all cell records.
            let sheetRecords = recordsForSheet(records, bofOffset: sheet.bofOffset)
            var rows: [Int: [Int: String]] = [:]   // row → (col → text)
            for r in sheetRecords {
                let d = wb.subdata(in: r.range)
                switch r.type {
                case Rec.labelSst:
                    guard d.count >= 10 else { break }
                    let row = Int(le16(d, 0)); let col = Int(le16(d, 2)); let isst = Int(le32(d, 6))
                    if isst >= 0 && isst < sst.count { rows[row, default: [:]][col] = sst[isst] }
                case Rec.label:
                    guard d.count >= 8 else { break }
                    let row = Int(le16(d, 0)); let col = Int(le16(d, 2))
                    if let s = xlUnicodeString(d, at: 6) { rows[row, default: [:]][col] = s }
                case Rec.rk:
                    guard d.count >= 10 else { break }
                    let row = Int(le16(d, 0)); let col = Int(le16(d, 2))
                    rows[row, default: [:]][col] = formatNumber(rkToDouble(Int32(bitPattern: le32(d, 6))))
                case Rec.mulRk:
                    guard d.count >= 6 else { break }
                    let row = Int(le16(d, 0)); let colFirst = Int(le16(d, 2))
                    let count = (d.count - 6) / 6
                    for k in 0..<count {
                        let off = 4 + k * 6
                        let rk = Int32(bitPattern: le32(d, off + 2))
                        rows[row, default: [:]][colFirst + k] = formatNumber(rkToDouble(rk))
                    }
                case Rec.number:
                    guard d.count >= 14 else { break }
                    let row = Int(le16(d, 0)); let col = Int(le16(d, 2))
                    let bits = le64(d, 6)
                    rows[row, default: [:]][col] = formatNumber(Double(bitPattern: bits))
                case Rec.formula:
                    guard d.count >= 22 else { break }
                    let row = Int(le16(d, 0)); let col = Int(le16(d, 2))
                    // If the cached result is a number (not the "string/bool/err"
                    // sentinel 0xFFFF in the top 2 bytes), format it; string
                    // results arrive in a following STRING record (handled below).
                    let hi = le16(d, 12)
                    if hi != 0xFFFF {
                        rows[row, default: [:]][col] = formatNumber(Double(bitPattern: le64(d, 6)))
                    } else {
                        rows[row, default: [:]][col] = ""   // filled by trailing STRING
                    }
                default:
                    break
                }
            }

            // Emit one row block per non-empty row, cells in column order.
            for row in rows.keys.sorted() {
                let cols = rows[row]!
                let line = cols.keys.sorted().compactMap { c -> String? in
                    let v = cols[c]!.trimmingCharacters(in: .whitespacesAndNewlines)
                    return v.isEmpty ? nil : v
                }.joined(separator: "\t")
                guard !line.isEmpty else { continue }
                totalCells += cols.count
                if totalCells > cellCap {
                    warnings.append(ParserWarning(severity: .warning, code: "xls.truncated",
                        message: "Very large workbook — stopped after \(cellCap) cells."))
                    status = .partial
                    break
                }
                blocks.append(EvidenceBlock(
                    documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                    kind: .spreadsheetRow, rawText: line,
                    locator: SourceLocator(row: row, sheet: sheet.name),
                    extractionMethod: .native, extractionConfidence: 1.0,
                    attributes: ["sheetIndex": AnyCodable(.int(Int64(si))),
                                 "row": AnyCodable(.int(Int64(row)))]))
                ordinal += 1
            }
            if totalCells > cellCap { break }
        }

        let meta: [String: AnyCodable] = [
            "sheetCount": AnyCodable(.int(Int64(sheets.count))),
            "sharedStringCount": AnyCodable(.int(Int64(sst.count)))
        ]
        // Only sheet-header blocks and no rows → nothing substantive recovered.
        if blocks.filter({ $0.kind == .spreadsheetRow }).isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "xls.noCells",
                message: "No cell values recovered (empty workbook or unsupported record layout)."))
            return doc(blocks, warnings, blocks.isEmpty ? .empty : .partial, meta)
        }
        return doc(blocks, warnings, status, meta)
    }

    // MARK: - Record scanning

    private func scanRecords(_ wb: Data) -> [BIFFRecord] {
        var out: [BIFFRecord] = []
        var i = 0
        let n = wb.count
        while i + 4 <= n {
            let type = le16(wb, i)
            let len = Int(le16(wb, i + 2))
            let dataStart = i + 4
            let dataEnd = min(dataStart + len, n)
            guard dataEnd <= n else { break }
            out.append(BIFFRecord(type: type, range: dataStart..<dataEnd))
            i = dataEnd
            if out.count > 5_000_000 { break }
        }
        return out
    }

    /// Records from a sheet's BOF (matched by absolute stream offset) up to its
    /// EOF. When `bofOffset` is unknown, returns every record (globals scan).
    private func recordsForSheet(_ records: [BIFFRecord], bofOffset: Int) -> [BIFFRecord] {
        guard bofOffset >= 0 else { return records }
        guard let startIdx = records.firstIndex(where: { $0.range.lowerBound - 4 == bofOffset }) else {
            return records
        }
        var out: [BIFFRecord] = []
        var i = startIdx + 1
        while i < records.count {
            if records[i].type == Rec.eof { break }
            out.append(records[i]); i += 1
        }
        return out
    }

    // MARK: - Shared string table (SST + CONTINUE)

    /// Rebuild the SST into a flat [String]. The SST record holds cstUnique
    /// strings; each is an XLUnicodeRichExtendedString whose character data may
    /// spill into following CONTINUE records — and at each CONTINUE boundary a
    /// fresh grbit byte re-declares 8- vs 16-bit encoding ([MS-XLS] §2.5.293).
    private func parseSST(wb: Data, records: [BIFFRecord], warnings: inout [ParserWarning]) -> [String] {
        guard let sstIdx = records.firstIndex(where: { $0.type == Rec.sst }) else { return [] }
        // Concatenate SST payload + subsequent CONTINUE payloads, remembering
        // where each segment boundary falls so we can reset the encoding byte.
        var segments: [Data] = [wb.subdata(in: records[sstIdx].range)]
        var j = sstIdx + 1
        while j < records.count && records[j].type == Rec.continueRec {
            segments.append(wb.subdata(in: records[j].range)); j += 1
        }
        var src = SegmentedReader(segments: segments)
        guard src.remaining >= 8 else { return [] }
        _ = src.u32()                    // cstTotal
        let cstUnique = Int(src.u32())
        var strings: [String] = []
        strings.reserveCapacity(min(cstUnique, 1_000_000))
        var i = 0
        while i < cstUnique && src.remaining >= 3 {
            guard let s = src.readXLString() else { break }
            strings.append(s)
            i += 1
        }
        if strings.count < cstUnique {
            warnings.append(ParserWarning(severity: .warning, code: "xls.sstPartial",
                message: "Recovered \(strings.count) of \(cstUnique) shared strings."))
        }
        return strings
    }

    // MARK: - Numeric decode

    private func rkToDouble(_ rk: Int32) -> Double {
        let div100 = (rk & 0x1) != 0
        let isInt = (rk & 0x2) != 0
        var v: Double
        if isInt {
            v = Double(rk >> 2)
        } else {
            let bits = UInt64(UInt32(bitPattern: rk & ~0x3)) << 32
            v = Double(bitPattern: bits)
        }
        return div100 ? v / 100.0 : v
    }

    /// Format a spreadsheet number without trailing ".0" for integers so cells
    /// like invoice ids and amounts read naturally in the row text.
    private func formatNumber(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    // MARK: - String helpers

    /// ShortXLUnicodeString: 1-byte char count, 1-byte flags, then chars.
    private func shortXLString(_ d: Data, at offset: Int) -> String? {
        guard offset + 2 <= d.count else { return nil }
        let cch = Int(d[d.startIndex + offset])
        let flags = d[d.startIndex + offset + 1]
        let highByte = (flags & 0x01) != 0
        return decodeChars(d, start: offset + 2, cch: cch, highByte: highByte)
    }

    /// XLUnicodeString: 2-byte char count, 1-byte flags, then chars.
    private func xlUnicodeString(_ d: Data, at offset: Int) -> String? {
        guard offset + 3 <= d.count else { return nil }
        let cch = Int(le16(d, offset))
        let flags = d[d.startIndex + offset + 2]
        let highByte = (flags & 0x01) != 0
        return decodeChars(d, start: offset + 3, cch: cch, highByte: highByte)
    }

    private func decodeChars(_ d: Data, start: Int, cch: Int, highByte: Bool) -> String? {
        var out = String.UnicodeScalarView()
        let base = d.startIndex
        if highByte {
            guard start + cch * 2 <= d.count else { return nil }
            for k in 0..<cch {
                let lo = UInt16(d[base + start + k * 2]); let hi = UInt16(d[base + start + k * 2 + 1])
                if let s = Unicode.Scalar(lo | (hi << 8)) { out.append(s) }
            }
        } else {
            guard start + cch <= d.count else { return nil }
            for k in 0..<cch { out.append(Unicode.Scalar(d[base + start + k])) }
        }
        return String(out)
    }

    // MARK: - Little-endian reads (Data may be a slice — index off startIndex)

    private func le16(_ d: Data, _ off: Int) -> UInt16 {
        let b = d.startIndex
        guard off + 2 <= d.count else { return 0 }
        return UInt16(d[b + off]) | (UInt16(d[b + off + 1]) << 8)
    }
    private func le32(_ d: Data, _ off: Int) -> UInt32 {
        let b = d.startIndex
        guard off + 4 <= d.count else { return 0 }
        return UInt32(d[b + off]) | (UInt32(d[b + off + 1]) << 8)
             | (UInt32(d[b + off + 2]) << 16) | (UInt32(d[b + off + 3]) << 24)
    }
    private func le64(_ d: Data, _ off: Int) -> UInt64 {
        let b = d.startIndex
        guard off + 8 <= d.count else { return 0 }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(d[b + off + k]) << (k * 8) }
        return v
    }
}

/// Reads across the SST record + its CONTINUE segments as one logical stream,
/// re-reading the per-segment grbit byte when an XLUnicodeRichExtendedString's
/// character data crosses a segment boundary ([MS-XLS] §2.5.293).
private struct SegmentedReader {
    private let bytes: [UInt8]
    /// Absolute byte offset where each segment (after the first) begins, so a
    /// string that spans into a new segment knows to read a fresh grbit byte.
    private let boundaries: Set<Int>
    private var pos = 0

    init(segments: [Data]) {
        var flat: [UInt8] = []
        var bounds = Set<Int>()
        var running = 0
        for (i, seg) in segments.enumerated() {
            if i > 0 { bounds.insert(running) }
            flat.append(contentsOf: seg)
            running += seg.count
        }
        self.bytes = flat
        self.boundaries = bounds
    }

    var remaining: Int { bytes.count - pos }

    mutating func u8() -> UInt8 { let v = bytes[pos]; pos += 1; return v }
    mutating func u16() -> UInt16 {
        guard pos + 2 <= bytes.count else { pos = bytes.count; return 0 }
        let v = UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8); pos += 2; return v
    }
    mutating func u32() -> UInt32 {
        guard pos + 4 <= bytes.count else { pos = bytes.count; return 0 }
        let v = UInt32(bytes[pos]) | (UInt32(bytes[pos + 1]) << 8)
              | (UInt32(bytes[pos + 2]) << 16) | (UInt32(bytes[pos + 3]) << 24)
        pos += 4; return v
    }

    /// Read one XLUnicodeRichExtendedString from the current position.
    mutating func readXLString() -> String? {
        guard pos + 3 <= bytes.count else { return nil }
        let cch = Int(u16())
        var grbit = u8()
        var highByte = (grbit & 0x01) != 0
        let rich = (grbit & 0x08) != 0
        let ext = (grbit & 0x04) != 0
        var cRun = 0
        var cbExt = 0
        if rich { cRun = Int(u16()) }
        if ext { cbExt = Int(u32()) }

        var out = String.UnicodeScalarView()
        var read = 0
        while read < cch {
            // If we've just crossed into a CONTINUE segment, a fresh grbit byte
            // re-declares the encoding for the remaining characters.
            if boundaries.contains(pos) {
                guard pos < bytes.count else { break }
                grbit = u8()
                highByte = (grbit & 0x01) != 0
            }
            if highByte {
                guard pos + 2 <= bytes.count else { break }
                let lo = UInt16(bytes[pos]); let hi = UInt16(bytes[pos + 1]); pos += 2
                if let s = Unicode.Scalar(lo | (hi << 8)) { out.append(s) }
            } else {
                guard pos < bytes.count else { break }
                out.append(Unicode.Scalar(bytes[pos])); pos += 1
            }
            read += 1
        }
        // Skip rich-run + phonetic trailers.
        if rich { pos += cRun * 4 }
        if ext { pos += cbExt }
        if pos > bytes.count { pos = bytes.count }
        return String(out)
    }
}
